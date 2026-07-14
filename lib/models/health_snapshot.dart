/// Local HealthKit summary for the home screen.
///
/// Two semantic groups:
/// 1. **Latest-reading metrics** — HR, HRV, RHR, SpO2, RespRate, BP, AFib.
///    We show the most recent sample with a `…SampleAt` timestamp regardless
///    of how old it is, mirroring Apple Health which displays
///    "yesterday 8:17 pm — 76 bpm" instead of hiding the value after 24h.
/// 2. **Today-aggregated metrics** — Steps, Exercise, Sleep. These reset at
///    local midnight to match Apple Fitness rings; no per-metric timestamp.
class HealthSnapshot {
  // ── Latest-reading metrics (value + when measured) ─────────────────────
  final double? latestHr;
  final DateTime? hrSampleAt;
  final double? hrv;
  final DateTime? hrvSampleAt;
  final double? rhr;
  final DateTime? rhrSampleAt;
  final double? spo2;
  final DateTime? spo2SampleAt;
  final double? respRate;
  final DateTime? respRateSampleAt;
  final double? bpSystolic;
  final double? bpDiastolic;
  final DateTime? bpSampleAt; // shared (cuff writes both at once)
  final bool? afibDetected;
  final DateTime? afibSampleAt;

  // ── Today-aggregated metrics (midnight reset) ──────────────────────────
  final int? steps;
  final int? exerciseMin;
  final double? sleepHours;
  final int? sleepDeepMin;
  final int? sleepRemMin;
  final int? sleepLightMin;

  final DateTime fetchedAt;

  /// The app/device that contributed the most HR readings in the last week,
  /// e.g. "Apple Watch", "Garmin Connect", "iPhone".
  final String? primarySource;

  /// True when no HR sample exists at all in the last 7 days. Used to drive
  /// the "iPhone-only" banner — a much more reliable signal than "no HR in
  /// the last 24h" (which mis-fires whenever a user takes the watch off
  /// overnight to charge).
  final bool noHrLast7Days;

  const HealthSnapshot({
    this.latestHr,
    this.hrSampleAt,
    this.hrv,
    this.hrvSampleAt,
    this.rhr,
    this.rhrSampleAt,
    this.spo2,
    this.spo2SampleAt,
    this.respRate,
    this.respRateSampleAt,
    this.bpSystolic,
    this.bpDiastolic,
    this.bpSampleAt,
    this.afibDetected,
    this.afibSampleAt,
    this.steps,
    this.exerciseMin,
    this.sleepHours,
    this.sleepDeepMin,
    this.sleepRemMin,
    this.sleepLightMin,
    required this.fetchedAt,
    this.primarySource,
    this.noHrLast7Days = false,
  });

  bool get hasData =>
      latestHr != null || steps != null || sleepHours != null || hrv != null ||
      spo2 != null || rhr != null || exerciseMin != null || respRate != null ||
      bpSystolic != null || bpDiastolic != null || afibDetected != null;
}
