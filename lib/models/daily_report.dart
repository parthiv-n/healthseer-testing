/// Data models for the daily health report from GET /reports/daily/{user_id}
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
        drivers: (j['drivers'] as List<dynamic>?)?.cast<String>() ?? [],
        metricsUsed: (j['metrics_used'] as List<dynamic>?)?.cast<String>() ?? [],
      );
}

class HealthScores {
  final double? hrvTrendScore;
  final double? activityWellnessScore;
  final double? volumeScore;
  final double? consistencyScore;
  final double? intensityScore;
  final double? recoveryScore;

  HealthScores({
    this.hrvTrendScore,
    this.activityWellnessScore,
    this.volumeScore,
    this.consistencyScore,
    this.intensityScore,
    this.recoveryScore,
  });

  factory HealthScores.fromJson(Map<String, dynamic> j) {
    final dims = j['activity_dimensions'] as Map<String, dynamic>?;
    return HealthScores(
      hrvTrendScore: (j['hrv_trend_score'] as num?)?.toDouble(),
      activityWellnessScore: (j['activity_wellness_score'] as num?)?.toDouble(),
      volumeScore: (dims?['volume'] as num?)?.toDouble(),
      consistencyScore: (dims?['consistency'] as num?)?.toDouble(),
      intensityScore: (dims?['intensity'] as num?)?.toDouble(),
      recoveryScore: (dims?['recovery_time'] as num?)?.toDouble(),
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
