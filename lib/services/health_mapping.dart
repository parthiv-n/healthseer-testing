// Pure, platform-agnostic mapping helpers extracted from HealthService
// (Phase 1.1 of the health_service.dart split — see CLAUDE.md "Flutter file
// split" item). Every function here is a deterministic mapping over
// HealthDataType / plain DateTime values, with zero dependency on a live
// Health() plugin instance, HTTP, or secure storage — which makes it
// directly unit-testable (see test/health_mapping_test.dart) without mocking
// HealthKit / Health Connect.
//
// health_service.dart's private helpers (_healthTypeToLp, _unitForType,
// _isSleepType, _platformSyncTypes, and the upload drop-rule conditionals in
// _convertToMobileSyncEvent) now delegate here. Behavior is unchanged —
// this is a pure extraction.
import 'package:health/health.dart';

// ── Sync type lists ──────────────────────────────────────────────────────

/// Core health types requested on iOS (HealthKit).
///
/// v3.0: removed ACTIVE_ENERGY_BURNED, DISTANCE_WALKING_RUNNING,
/// FLIGHTS_CLIMBED, BASAL_ENERGY_BURNED (low actuarial value, no backend
/// mapping).
///
/// SLEEP_AWAKE is intentionally NOT requested. The pipeline filters AWAKE
/// intervals out in _convertToMobileSyncEvent (they would inflate sleep
/// totals when uploaded as SLEEP_STAGE), so requesting them only widens
/// the iOS HealthKit permission dialog without producing usable data.
const List<HealthDataType> platformSyncTypesIos = [
  HealthDataType.HEART_RATE,
  HealthDataType.HEART_RATE_VARIABILITY_SDNN,
  HealthDataType.STEPS,
  HealthDataType.BLOOD_OXYGEN,
  HealthDataType.RESTING_HEART_RATE,
  HealthDataType.EXERCISE_TIME,
  // Sleep stages (v13+: granular DEEP/REM/LIGHT stages from Apple Watch)
  HealthDataType.SLEEP_IN_BED,
  HealthDataType.SLEEP_ASLEEP,
  HealthDataType.SLEEP_DEEP,
  HealthDataType.SLEEP_REM,
  HealthDataType.SLEEP_LIGHT,
];

/// Core health types requested on Android (Health Connect).
const List<HealthDataType> platformSyncTypesAndroid = [
  HealthDataType.HEART_RATE,
  HealthDataType.HEART_RATE_VARIABILITY_RMSSD,
  HealthDataType.STEPS,
  HealthDataType.BLOOD_OXYGEN,
  HealthDataType.RESTING_HEART_RATE,
  HealthDataType.EXERCISE_TIME,
  // Sleep stages (Health Connect)
  HealthDataType.SLEEP_SESSION,
  HealthDataType.SLEEP_DEEP,
  HealthDataType.SLEEP_REM,
  HealthDataType.SLEEP_LIGHT,
];

/// Optional types only available on newer hardware or specific accessories.
/// Fetched separately with null-safe handling — missing data is silently
/// ignored.
///
/// Blood pressure: needs a 3rd-party BP cuff app writing to HealthKit.
///
/// NOT available in health package v13.x:
///   - VO2MAX (HKQuantityTypeIdentifierVO2Max) — read via Vo2MaxChannel
///     (native bridge); not in health plugin v13.x.
///   - SLEEP_APNEA_EVENT (HKCategoryTypeIdentifierApneaEvents) — category
///     type, not wrapped; file export only (Apple Watch S9+, watchOS 10+).
// v3.0: removed WALKING_SPEED and APPLE_STAND_TIME (no backend mapping).
// v3.2: added ATRIAL_FIBRILLATION_BURDEN (iOS 16+, Apple Watch) → AFIB_FLAG.
const List<HealthDataType> optionalSyncTypes = [
  HealthDataType.RESPIRATORY_RATE,
  HealthDataType.BLOOD_PRESSURE_SYSTOLIC,
  HealthDataType.BLOOD_PRESSURE_DIASTOLIC,
  HealthDataType.ATRIAL_FIBRILLATION_BURDEN,
  // v5 Tier 3a: pull HKWorkoutType samples so the backend can flag
  // workout-window readings (post-exercise BP, recovery HR, etc.) and
  // build foundation for HR-recovery / weekly-active-minutes analytics.
  // The duration is mapped to a WORKOUT_SESSION canonical event.
  HealthDataType.WORKOUT,
];

// ── Sleep type classification ────────────────────────────────────────────

/// All HealthDataType values whose payload represents a time range rather
/// than a scalar reading — duration (minutes) is uploaded, not the raw
/// numeric value.
bool isSleepType(HealthDataType type) => const {
      HealthDataType.SLEEP_IN_BED,
      HealthDataType.SLEEP_ASLEEP,
      HealthDataType.SLEEP_DEEP,
      HealthDataType.SLEEP_REM,
      HealthDataType.SLEEP_LIGHT,
      HealthDataType.SLEEP_AWAKE,
      HealthDataType.SLEEP_AWAKE_IN_BED,
      HealthDataType.SLEEP_SESSION,
    }.contains(type);

/// Granular sleep stage types (DEEP/REM/LIGHT). When present in a batch,
/// the coarser SLEEP_ASLEEP rollup is redundant and would double-count the
/// time spent asleep on the backend.
const Set<HealthDataType> granularSleepStages = {
  HealthDataType.SLEEP_DEEP,
  HealthDataType.SLEEP_REM,
  HealthDataType.SLEEP_LIGHT,
};

/// Two closed-open intervals `[aFrom, aTo)` and `[bFrom, bTo)` overlap iff
/// each starts before the other ends. Touching endpoints (e.g. `aTo ==
/// bFrom`) do NOT count as overlap.
bool sleepIntervalsOverlap(
  DateTime aFrom,
  DateTime aTo,
  DateTime bFrom,
  DateTime bTo,
) {
  return aFrom.isBefore(bTo) && bFrom.isBefore(aTo);
}

// ── Canonical metric mapping ─────────────────────────────────────────────

/// Maps a HealthDataType to the backend's canonical `metric_type` string,
/// or null if there is no backend mapping for this type.
///
/// [isIos] is accepted for API symmetry with [uploadDropReason] and to leave
/// room for future platform-conditional mapping rules; the current map does
/// not need to branch on it because HRV_SDNN (iOS) and HRV_RMSSD (Android)
/// are already distinct HealthDataType enum values.
String? healthTypeToLp(HealthDataType type, {required bool isIos}) {
  // v4.4: emit granular metric_types for the named stages so the backend
  // (and the portal display) can break sleep down by stage instead of
  // collapsing everything to a single SLEEP_STAGE bucket. SLEEP_ASLEEP
  // and SLEEP_IN_BED stay on the legacy aggregate type because they
  // overlap the granular stages on newer Watches; the dedup pass in
  // health_service.dart's _dedupeOverlappingSleepAsleep drops the
  // overlapping SLEEP_ASLEEP rows.
  if (type == HealthDataType.SLEEP_DEEP) return 'SLEEP_DEEP';
  if (type == HealthDataType.SLEEP_REM) return 'SLEEP_REM';
  if (type == HealthDataType.SLEEP_LIGHT) return 'SLEEP_LIGHT';
  if (isSleepType(type)) return 'SLEEP_STAGE';

  const map = {
    // Core metrics
    HealthDataType.HEART_RATE: 'HR_INSTANT',
    HealthDataType.HEART_RATE_VARIABILITY_SDNN: 'HRV_SDNN', // iOS
    HealthDataType.HEART_RATE_VARIABILITY_RMSSD: 'HRV_RMSSD', // Android
    HealthDataType.STEPS: 'STEPS_DELTA',
    HealthDataType.BLOOD_OXYGEN: 'SPO2_INSTANT',
    HealthDataType.RESTING_HEART_RATE: 'RHR_DAILY',
    HealthDataType.EXERCISE_TIME: 'EXERCISE_TIME',
    // Optional (Apple Watch S6+ / v13 new types)
    HealthDataType.RESPIRATORY_RATE: 'RESP_RATE',
    HealthDataType.BLOOD_PRESSURE_SYSTOLIC: 'BP_SYSTOLIC',
    HealthDataType.BLOOD_PRESSURE_DIASTOLIC: 'BP_DIASTOLIC',
    // v3.2: AFib burden (iOS 16+, Apple Watch) → binary 0/1 flag
    HealthDataType.ATRIAL_FIBRILLATION_BURDEN: 'AFIB_FLAG',
    // v3.0 removed: ENERGY_DELTA, ENERGY_BASAL, DISTANCE_DELTA,
    // FLOORS_CLIMBED, STAND_TIME, WALKING_SPEED (low actuarial value)
    // v5 Tier 3a: workout session record. Backend interprets value
    // as duration minutes; algorithm_metadata carries the workout
    // type (running, cycling, …) and any distance/kcal numbers.
    HealthDataType.WORKOUT: 'WORKOUT_SESSION',
  };
  return map[type];
}

/// Maps a HealthDataType to the unit string sent to the backend for that
/// type's raw (pre in-Flutter-conversion) value.
///
/// NOTE: a couple of metric_types get a further override at upload time
/// (AFIB_FLAG -> 'flag', SPO2_INSTANT -> '%' on iOS) — see
/// health_service.dart's `_convertToMobileSyncEvent` for that payload-level
/// switch; this function only returns the type's "natural" unit.
String unitForType(HealthDataType type) {
  if (isSleepType(type)) return 'min';
  const map = {
    HealthDataType.HEART_RATE: 'bpm',
    HealthDataType.HEART_RATE_VARIABILITY_SDNN: 'ms',
    HealthDataType.HEART_RATE_VARIABILITY_RMSSD: 'ms',
    HealthDataType.STEPS: 'count',
    HealthDataType.BLOOD_OXYGEN: '%',
    HealthDataType.RESTING_HEART_RATE: 'bpm',
    HealthDataType.EXERCISE_TIME: 'min',
    // Optional
    HealthDataType.RESPIRATORY_RATE: 'breaths/min',
    HealthDataType.BLOOD_PRESSURE_SYSTOLIC: 'mmHg',
    HealthDataType.BLOOD_PRESSURE_DIASTOLIC: 'mmHg',
    HealthDataType.ATRIAL_FIBRILLATION_BURDEN: '%',
    HealthDataType.WORKOUT: 'min',
  };
  return map[type] ?? 'unknown';
}

// ── Upload drop rules ────────────────────────────────────────────────────

/// Why a HealthDataPoint of this type is never uploaded as a sync event,
/// even though it may be requested from HealthKit / Health Connect for
/// on-device display (e.g. the Today screen).
enum UploadDropReason {
  /// SLEEP_AWAKE / SLEEP_AWAKE_IN_BED — awake intervals during a sleep
  /// session are NOT sleep; uploading them as SLEEP_STAGE would inflate the
  /// user's nightly sleep duration and corrupt sleep-domain risk scoring.
  /// Apple Health's "Time Asleep" excludes these intervals; we match.
  awakeFiltered,

  /// SLEEP_IN_BED is a whole-night envelope, not sleep. Uploading it as
  /// SLEEP_STAGE handed the server one ~8-hour interval overlapping every
  /// SLEEP_ASLEEP segment of the night; the server's time-overlap dedup then
  /// kept the longest interval and flagged ALL the real segments
  /// invalid_duplicate, while the in-bed span inflated sleep totals and
  /// widened the SLEEP context window (voiding legitimate in-bed
  /// elevated-HR readings via the CM-2 rule).
  inBedEnvelope,

  /// No backend `metric_type` mapping exists for this HealthDataType
  /// ([healthTypeToLp] returns null).
  noMapping,
}

/// Encodes the drop rules inlined in health_service.dart's
/// `_convertToMobileSyncEvent`: which HealthDataType values are read from
/// the platform but never uploaded as sync events, and why. Returns null if
/// the type IS uploadable (subject to per-sample checks such as a
/// zero-or-negative computed duration, which this type-level function
/// cannot see).
UploadDropReason? uploadDropReason(HealthDataType type, {required bool isIos}) {
  if (type == HealthDataType.SLEEP_AWAKE ||
      type == HealthDataType.SLEEP_AWAKE_IN_BED) {
    return UploadDropReason.awakeFiltered;
  }
  if (type == HealthDataType.SLEEP_IN_BED) {
    return UploadDropReason.inBedEnvelope;
  }
  if (healthTypeToLp(type, isIos: isIos) == null) {
    return UploadDropReason.noMapping;
  }
  return null;
}
