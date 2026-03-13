/// Local HealthKit summary for today — shown immediately without network.
class HealthSnapshot {
  final double? avgHr;       // bpm  (mean of today's HR_INSTANT readings)
  final int? steps;          // count (sum of today's STEPS_DELTA)
  final double? sleepHours;  // hours (last night's SLEEP_IN_BED)
  final double? hrv;         // ms   (latest HRV_SDNN reading today)
  final DateTime fetchedAt;

  const HealthSnapshot({
    this.avgHr,
    this.steps,
    this.sleepHours,
    this.hrv,
    required this.fetchedAt,
  });

  bool get hasData =>
      avgHr != null || steps != null || sleepHours != null || hrv != null;
}
