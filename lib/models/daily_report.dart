/// Data models for the daily health report from GET /reports/daily/{user_id}

/// HRV Unified Score — cross-device, cross-method index (0–100).
/// Bridges HRV_SDNN (Apple Watch) and HRV_RMSSD (Samsung/Garmin/Fitbit)
/// into a single score comparable regardless of which device the user wears.
class HrvUnifiedScore {
  final double score;
  final String label;
  final double confidence;
  final String methodUsed;
  final String trendDirection;
  final String explanation;

  HrvUnifiedScore({
    required this.score,
    required this.label,
    required this.confidence,
    required this.methodUsed,
    required this.trendDirection,
    required this.explanation,
  });

  factory HrvUnifiedScore.fromJson(Map<String, dynamic> j) => HrvUnifiedScore(
        score: (j['score'] as num?)?.toDouble() ?? 0.0,
        label: j['label'] as String? ?? 'unknown',
        confidence: (j['confidence'] as num?)?.toDouble() ?? 0.0,
        methodUsed: j['method_used'] as String? ?? 'none',
        trendDirection: j['trend_direction'] as String? ?? 'stable',
        explanation: j['explanation'] as String? ?? '',
      );
}

class MetricSummary {
  final String metricType;
  final int count;
  final double mean;
  final double min;
  final double max;
  final int anomalyCount;

  MetricSummary({
    required this.metricType,
    required this.count,
    required this.mean,
    required this.min,
    required this.max,
    required this.anomalyCount,
  });

  factory MetricSummary.fromJson(Map<String, dynamic> j) => MetricSummary(
        metricType: j['metric_type'] as String? ?? '',
        count: (j['count'] as num?)?.toInt() ?? 0,
        mean: (j['mean'] as num?)?.toDouble() ?? 0.0,
        min: (j['min'] as num?)?.toDouble() ?? 0.0,
        max: (j['max'] as num?)?.toDouble() ?? 0.0,
        anomalyCount: (j['anomaly_count'] as num?)?.toInt() ?? 0,
      );
}

class DimensionScore {
  final double score;
  final String label;
  final double confidence;
  final List<String> drivers;
  final List<String> metricsUsed;

  DimensionScore({
    required this.score,
    required this.label,
    required this.confidence,
    required this.drivers,
    this.metricsUsed = const [],
  });

  factory DimensionScore.fromJson(Map<String, dynamic> j) => DimensionScore(
        score: (j['score'] as num?)?.toDouble() ?? 0.0,
        label: j['label'] as String? ?? 'unknown',
        confidence: (j['confidence'] as num?)?.toDouble() ?? 0.0,
        drivers: (j['drivers'] as List<dynamic>?)?.whereType<String>().toList() ?? [],
        metricsUsed: (j['metrics_used'] as List<dynamic>?)?.whereType<String>().toList() ?? [],
      );
}

class HealthScores {
  final double? hrvTrendScore;
  final double? activityWellnessScore;
  final double? volumeScore;
  final double? consistencyScore;
  final double? intensityScore;
  final double? recoveryScore;
  // HRV Unified Score — cross-device index (added v2.7)
  final HrvUnifiedScore? hrvUnified;

  HealthScores({
    this.hrvTrendScore,
    this.activityWellnessScore,
    this.volumeScore,
    this.consistencyScore,
    this.intensityScore,
    this.recoveryScore,
    this.hrvUnified,
  });

  factory HealthScores.fromJson(Map<String, dynamic> j) {
    final dims = j['activity_dimensions'] as Map<String, dynamic>?;
    // hrv_score is the legacy trend score; hrv_unified is the new cross-device score
    final hrvScoreMap = j['hrv_score'] as Map<String, dynamic>?;
    final hrvUnifiedMap = j['hrv_unified'] as Map<String, dynamic>?;
    final activityMap = j['activity_score'] as Map<String, dynamic>?;
    return HealthScores(
      hrvTrendScore: (hrvScoreMap?['score'] as num?)?.toDouble()
          ?? (j['hrv_trend_score'] as num?)?.toDouble(),
      activityWellnessScore: (activityMap?['score'] as num?)?.toDouble()
          ?? (j['activity_wellness_score'] as num?)?.toDouble(),
      volumeScore: (dims?['volume'] as num?)?.toDouble(),
      consistencyScore: (dims?['consistency'] as num?)?.toDouble(),
      intensityScore: (dims?['intensity'] as num?)?.toDouble(),
      recoveryScore: (dims?['recovery_time'] as num?)?.toDouble(),
      hrvUnified: hrvUnifiedMap != null
          ? HrvUnifiedScore.fromJson(hrvUnifiedMap)
          : null,
    );
  }
}

class DailyReport {
  final String reportDate;
  final double hri;
  final String hriLabel;
  final double coverageScore;
  final int anomalyCount;
  final String anomalySeverityMax;
  final double avgQualityScore;
  final int totalEvents;
  final double reportConfidence;
  final String reportConfidenceLabel;
  final double hriTrend7d;
  final String hriTrendDir;
  final List<MetricSummary> metrics;
  final Map<String, DimensionScore> dimensions;
  final double? compositeScore;
  final String? compositeLabel;
  final HealthScores? healthScores;
  // Baseline maturity fields (v2.6)
  final String baselineMaturity;   // "cold_start" | "developing" | "established"
  final double avgConfidence;      // 0.0 – 1.0
  final int daysWithData;
  final String? estimatedEstablishedDate; // ISO date or null
  final DateTime fetchedAt;

  DailyReport({
    required this.reportDate,
    required this.hri,
    required this.hriLabel,
    required this.coverageScore,
    required this.anomalyCount,
    required this.anomalySeverityMax,
    required this.avgQualityScore,
    required this.totalEvents,
    required this.reportConfidence,
    required this.reportConfidenceLabel,
    required this.hriTrend7d,
    required this.hriTrendDir,
    required this.metrics,
    required this.dimensions,
    this.compositeScore,
    this.compositeLabel,
    this.healthScores,
    this.baselineMaturity = 'cold_start',
    this.avgConfidence = 0.0,
    this.daysWithData = 0,
    this.estimatedEstablishedDate,
    required this.fetchedAt,
  });

  factory DailyReport.fromJson(Map<String, dynamic> j) {
    final dimsJson = j['dimensions'] as Map<String, dynamic>? ?? {};
    final dimKeys = ['cardiovascular', 'activity', 'sleep', 'recovery'];
    final dims = <String, DimensionScore>{};
    for (final k in dimKeys) {
      if (dimsJson.containsKey(k) && dimsJson[k] is Map) {
        dims[k] = DimensionScore.fromJson(dimsJson[k] as Map<String, dynamic>);
      }
    }
    final compositeScore = (dimsJson['composite'] as num?)?.toDouble();
    final compositeLabel = dimsJson['composite_label'] as String?;

    final metricsJson = j['metrics'] as List<dynamic>? ?? [];

    return DailyReport(
      reportDate: j['report_date'] as String? ?? '',
      hri: (j['hri'] as num?)?.toDouble() ?? 0.0,
      hriLabel: j['hri_label'] as String? ?? 'low',
      coverageScore: (j['coverage_score'] as num?)?.toDouble() ?? 0.0,
      anomalyCount: (j['anomaly_count'] as num?)?.toInt() ?? 0,
      anomalySeverityMax: j['anomaly_severity_max'] as String? ?? 'none',
      avgQualityScore: (j['avg_quality_score'] as num?)?.toDouble() ?? 0.0,
      totalEvents: (j['total_events'] as num?)?.toInt() ?? 0,
      reportConfidence: (j['report_confidence'] as num?)?.toDouble() ?? 0.0,
      reportConfidenceLabel: j['report_confidence_label'] as String? ?? 'low',
      hriTrend7d: (j['hri_trend_7d'] as num?)?.toDouble() ?? 0.0,
      hriTrendDir: j['hri_trend_dir'] as String? ?? 'stable',
      metrics: metricsJson.map((e) => MetricSummary.fromJson(e as Map<String, dynamic>)).toList(),
      dimensions: dims,
      compositeScore: compositeScore,
      compositeLabel: compositeLabel,
      healthScores: j['health_scores'] != null
          ? HealthScores.fromJson(j['health_scores'] as Map<String, dynamic>)
          : null,
      baselineMaturity: j['baseline_maturity'] as String? ?? 'cold_start',
      avgConfidence: (j['avg_confidence'] as num?)?.toDouble() ?? 0.0,
      daysWithData: (j['days_with_data'] as num?)?.toInt() ?? 0,
      estimatedEstablishedDate: j['estimated_established_date'] as String?,
      fetchedAt: DateTime.now(),
    );
  }
}

/// Local HealthKit daily metric aggregate — used for per-metric trend charts.
class DailyMetricPoint {
  final DateTime date;
  final double? avgHr;
  final double? hrv;
  final int? steps;
  final double? sleepHours;
  final double? rhr;
  final double? spo2;
  final int? exerciseMin;
  final double? respRate;
  final bool? afibDetected;

  const DailyMetricPoint({
    required this.date,
    this.avgHr,
    this.hrv,
    this.steps,
    this.sleepHours,
    this.rhr,
    this.spo2,
    this.exerciseMin,
    this.respRate,
    this.afibDetected,
  });

  bool get hasAnyData =>
      avgHr != null || hrv != null || steps != null || sleepHours != null ||
      rhr != null || spo2 != null || exerciseMin != null || respRate != null ||
      afibDetected != null;
}
