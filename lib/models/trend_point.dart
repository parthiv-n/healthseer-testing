/// A single data point in a trend chart (HRI or metric over time)
class TrendPoint {
  final DateTime date;
  final double hri;
  final String hriLabel;
  final double coverageScore;
  final int anomalyCount;
  final int totalEvents;

  TrendPoint({
    required this.date,
    required this.hri,
    required this.hriLabel,
    required this.coverageScore,
    required this.anomalyCount,
    required this.totalEvents,
  });

  factory TrendPoint.fromJson(Map<String, dynamic> j) => TrendPoint(
        date: j['date'] != null
            ? DateTime.tryParse(j['date'] as String) ?? DateTime.now()
            : DateTime.now(),
        hri: (j['hri'] as num?)?.toDouble() ?? 0.0,
        hriLabel: j['hri_label'] as String? ?? 'low',
        coverageScore: (j['coverage_score'] as num?)?.toDouble() ?? 0.0,
        anomalyCount: (j['anomaly_count'] as num?)?.toInt() ?? 0,
        totalEvents: (j['total_events'] as num?)?.toInt() ?? 0,
      );
}

class RangeReport {
  final String startDate;
  final String endDate;
  final int daysWithData;
  final double avgHri;
  final int totalAnomalies;
  final int totalEvents;
  final List<TrendPoint> dailyTrend;
  final DateTime fetchedAt;

  RangeReport({
    required this.startDate,
    required this.endDate,
    required this.daysWithData,
    required this.avgHri,
    required this.totalAnomalies,
    required this.totalEvents,
    required this.dailyTrend,
    required this.fetchedAt,
  });

  factory RangeReport.fromJson(Map<String, dynamic> j) {
    final trend = (j['daily_trend'] as List<dynamic>? ?? [])
        .map((e) => TrendPoint.fromJson(e as Map<String, dynamic>))
        .toList();
    return RangeReport(
      startDate: j['start_date'] as String? ?? '',
      endDate: j['end_date'] as String? ?? '',
      daysWithData: (j['days_with_data'] as num?)?.toInt() ?? 0,
      avgHri: (j['avg_hri'] as num?)?.toDouble() ?? 0.0,
      totalAnomalies: (j['total_anomalies'] as num?)?.toInt() ?? 0,
      totalEvents: (j['total_events'] as num?)?.toInt() ?? 0,
      dailyTrend: trend,
      fetchedAt: DateTime.now(),
    );
  }
}
