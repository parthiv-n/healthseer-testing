/// Local HealthKit summary for today — shown immediately without network.
class HealthSnapshot {
  final double? avgHr;        // bpm  (mean of today's HR_INSTANT, primary source)
  final int? steps;           // count (HKStatisticsQuery cumulativeSum — source-deduplicated)
  final double? sleepHours;   // hours (DEEP + REM + LIGHT stages, or SLEEP_ASLEEP fallback)
  final double? hrv;          // ms   (latest HRV_SDNN reading today)
  final double? spo2;         // %    (latest BLOOD_OXYGEN reading today)
  final double? rhr;          // bpm  (today's RESTING_HEART_RATE — Apple writes one/day)
  final int? exerciseMin;     // min  (sum of EXERCISE_TIME intervals today)
  final double? respRate;     // breaths/min (latest RESPIRATORY_RATE, Watch S6+ only)
  final double? bpSystolic;   // mmHg (latest BP_SYSTOLIC — requires 3rd-party BP cuff app)
  final double? bpDiastolic;  // mmHg (latest BP_DIASTOLIC — requires 3rd-party BP cuff app)
  final bool? afibDetected;   // true/false (ATRIAL_FIBRILLATION_BURDEN > 0, iOS 16+ / Watch)
  final DateTime fetchedAt;

  /// The app or device that contributed the most HR readings today,
  /// e.g. "Apple Watch", "Garmin Connect", "iPhone".
  final String? primarySource;

  const HealthSnapshot({
    this.avgHr,
    this.steps,
    this.sleepHours,
    this.hrv,
    this.spo2,
    this.rhr,
    this.exerciseMin,
    this.respRate,
    this.bpSystolic,
    this.bpDiastolic,
    this.afibDetected,
    required this.fetchedAt,
    this.primarySource,
  });

  bool get hasData =>
      avgHr != null || steps != null || sleepHours != null || hrv != null ||
      spo2 != null || rhr != null || exerciseMin != null || respRate != null ||
      bpSystolic != null || bpDiastolic != null || afibDetected != null;
}
