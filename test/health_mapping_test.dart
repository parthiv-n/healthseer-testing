// Tests for lib/services/health_mapping.dart — the pure mapping helpers
// extracted from HealthService (Phase 1.1). These are plain-value tests: no
// mocked Health() plugin required, since the module under test never
// instantiates one.

import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:vitametric_app/services/health_mapping.dart';

void main() {
  group('platform sync type coverage', () {
    test('every platform sync type maps or has a drop reason', () {
      final allTypes = [...platformSyncTypesIos, ...optionalSyncTypes];
      for (final t in allTypes) {
        final mapped = healthTypeToLp(t, isIos: true);
        final dropReason = uploadDropReason(t, isIos: true);
        expect(
          mapped != null || dropReason != null,
          isTrue,
          reason: '$t has neither a backend mapping nor a documented drop '
              'reason — it would silently vanish between HealthKit and the '
              'upload payload.',
        );
      }
    });

    test('every Android platform sync type maps or has a drop reason', () {
      final allTypes = [...platformSyncTypesAndroid, ...optionalSyncTypes];
      for (final t in allTypes) {
        final mapped = healthTypeToLp(t, isIos: false);
        final dropReason = uploadDropReason(t, isIos: false);
        expect(mapped != null || dropReason != null, isTrue,
            reason: '$t has neither a mapping nor a drop reason on Android');
      }
    });
  });

  group('mapped metrics are server-known', () {
    // Test-local mirror of the backend registry. Mirrors
    // app/core/normalization/pipeline.py MetricType._ALL — keep in sync if
    // the backend registry changes.
    const knownServerMetrics = {
      'HR_INSTANT',
      'HRV_SDNN',
      'HRV_RMSSD',
      'STEPS_DELTA',
      'SPO2_INSTANT',
      'RHR_DAILY',
      'EXERCISE_TIME',
      'SLEEP_STAGE',
      'SLEEP_DEEP',
      'SLEEP_REM',
      'SLEEP_LIGHT',
      'RESP_RATE',
      'BP_SYSTOLIC',
      'BP_DIASTOLIC',
      'AFIB_FLAG',
      'WORKOUT_SESSION',
      'VO2_MAX',
      'SLEEP_APNEA_EVENT',
    };

    test('all mapped types resolve to a known server metric', () {
      final allTypes = [
        ...platformSyncTypesIos,
        ...platformSyncTypesAndroid,
        ...optionalSyncTypes,
      ];
      final mappedMetrics = allTypes
          .map((t) => healthTypeToLp(t, isIos: true))
          .whereType<String>()
          .toSet();
      expect(mappedMetrics, isNotEmpty);
      for (final m in mappedMetrics) {
        expect(knownServerMetrics.contains(m), isTrue,
            reason: '"$m" is not in the backend registry mirror — either '
                'the mapping is wrong or the mirror above is stale.');
      }
    });
  });

  group('expected unit per mapped metric', () {
    // Literal pin of unitForType's output — read off health_mapping.dart's
    // unit map so a drifted unit string fails loudly here instead of
    // silently mis-tagging payloads sent to the backend.
    const expectedUnits = <HealthDataType, String>{
      HealthDataType.HEART_RATE: 'bpm',
      HealthDataType.HEART_RATE_VARIABILITY_SDNN: 'ms',
      HealthDataType.HEART_RATE_VARIABILITY_RMSSD: 'ms',
      HealthDataType.STEPS: 'count',
      HealthDataType.BLOOD_OXYGEN: '%',
      HealthDataType.RESTING_HEART_RATE: 'bpm',
      HealthDataType.EXERCISE_TIME: 'min',
      HealthDataType.RESPIRATORY_RATE: 'breaths/min',
      HealthDataType.BLOOD_PRESSURE_SYSTOLIC: 'mmHg',
      HealthDataType.BLOOD_PRESSURE_DIASTOLIC: 'mmHg',
      HealthDataType.ATRIAL_FIBRILLATION_BURDEN: '%',
      HealthDataType.WORKOUT: 'min',
      HealthDataType.SLEEP_IN_BED: 'min',
      HealthDataType.SLEEP_ASLEEP: 'min',
      HealthDataType.SLEEP_DEEP: 'min',
      HealthDataType.SLEEP_REM: 'min',
      HealthDataType.SLEEP_LIGHT: 'min',
      HealthDataType.SLEEP_AWAKE: 'min',
      HealthDataType.SLEEP_AWAKE_IN_BED: 'min',
      HealthDataType.SLEEP_SESSION: 'min',
    };

    test('unitForType matches the pinned unit for every mapped type', () {
      for (final entry in expectedUnits.entries) {
        expect(unitForType(entry.key), entry.value,
            reason: '${entry.key} unit drifted from the pinned value');
      }
    });

    test('never returns "unknown" for a type with a backend mapping', () {
      final allTypes = [
        ...platformSyncTypesIos,
        ...platformSyncTypesAndroid,
        ...optionalSyncTypes,
      ];
      for (final t in allTypes) {
        if (healthTypeToLp(t, isIos: true) != null) {
          expect(unitForType(t), isNot('unknown'),
              reason: '$t has a mapping but no unit — the payload would '
                  'ship "unknown" as the unit string.');
        }
      }
    });
  });

  group('sleep mapping rules', () {
    test('SLEEP_IN_BED is a whole-night envelope, dropped before upload', () {
      expect(
        uploadDropReason(HealthDataType.SLEEP_IN_BED, isIos: true),
        UploadDropReason.inBedEnvelope,
      );
    });

    test('SLEEP_AWAKE and SLEEP_AWAKE_IN_BED are filtered out', () {
      expect(
        uploadDropReason(HealthDataType.SLEEP_AWAKE, isIos: true),
        UploadDropReason.awakeFiltered,
      );
      expect(
        uploadDropReason(HealthDataType.SLEEP_AWAKE_IN_BED, isIos: true),
        UploadDropReason.awakeFiltered,
      );
    });

    test('granular DEEP/REM/LIGHT stages map to their own metric_type', () {
      expect(healthTypeToLp(HealthDataType.SLEEP_DEEP, isIos: true),
          'SLEEP_DEEP');
      expect(
          healthTypeToLp(HealthDataType.SLEEP_REM, isIos: true), 'SLEEP_REM');
      expect(healthTypeToLp(HealthDataType.SLEEP_LIGHT, isIos: true),
          'SLEEP_LIGHT');
    });

    test('SLEEP_ASLEEP maps to the aggregate SLEEP_STAGE', () {
      expect(healthTypeToLp(HealthDataType.SLEEP_ASLEEP, isIos: true),
          'SLEEP_STAGE');
    });

    test('SLEEP_SESSION (Android) also maps to the aggregate SLEEP_STAGE',
        () {
      expect(healthTypeToLp(HealthDataType.SLEEP_SESSION, isIos: false),
          'SLEEP_STAGE');
    });
  });

  group('overlap predicate', () {
    final t0 = DateTime(2026, 1, 1, 22, 0);
    final t1 = DateTime(2026, 1, 1, 23, 0);
    final t2 = DateTime(2026, 1, 2, 0, 0);
    final t3 = DateTime(2026, 1, 2, 1, 0);

    test('touching endpoints do not count as overlap', () {
      // a: [t0, t1), b: [t1, t2) — a ends exactly when b starts.
      expect(sleepIntervalsOverlap(t0, t1, t1, t2), isFalse);
    });

    test('containment overlaps (either direction)', () {
      // a: [t0, t3) fully contains b: [t1, t2)
      expect(sleepIntervalsOverlap(t0, t3, t1, t2), isTrue);
      expect(sleepIntervalsOverlap(t1, t2, t0, t3), isTrue);
    });

    test('disjoint intervals do not overlap', () {
      expect(sleepIntervalsOverlap(t0, t1, t2, t3), isFalse);
    });

    test('partial overlap is detected', () {
      expect(sleepIntervalsOverlap(t0, t2, t1, t3), isTrue);
    });

    test('an interval overlaps itself', () {
      expect(sleepIntervalsOverlap(t0, t2, t0, t2), isTrue);
    });
  });

  group('granularSleepStages', () {
    test('contains exactly DEEP/REM/LIGHT', () {
      expect(
        granularSleepStages,
        {
          HealthDataType.SLEEP_DEEP,
          HealthDataType.SLEEP_REM,
          HealthDataType.SLEEP_LIGHT,
        },
      );
    });
  });
}
