/// Data model for a detected health anomaly from GET /anomalies
class AnomalyItem {
  final String id;
  final String metricType;
  final double value;
  final DateTime eventTimestamp;
  final double zScore;
  final String severity;
  final double confidence;
  final String explanation;
  final DateTime detectedAt;

  AnomalyItem({
    required this.id,
    required this.metricType,
    required this.value,
    required this.eventTimestamp,
    required this.zScore,
    required this.severity,
    required this.confidence,
    required this.explanation,
    required this.detectedAt,
  });

  factory AnomalyItem.fromJson(Map<String, dynamic> j) => AnomalyItem(
        id: j['id']?.toString() ?? '',
        metricType: j['metric_type'] as String? ?? '',
        value: (j['value'] as num?)?.toDouble() ?? 0.0,
        eventTimestamp: j['event_timestamp'] != null
            ? DateTime.tryParse(j['event_timestamp'] as String) ?? DateTime.now()
            : DateTime.now(),
        zScore: (j['z_score'] as num?)?.toDouble() ?? 0.0,
        severity: j['severity'] as String? ?? 'mild',
        confidence: (j['confidence'] as num?)?.toDouble() ?? 0.0,
        explanation: j['explanation'] as String? ?? '',
        detectedAt: j['detected_at'] != null
            ? DateTime.tryParse(j['detected_at'] as String) ?? DateTime.now()
            : DateTime.now(),
      );

  String get metricLabel => switch (metricType) {
        'HR_INSTANT' => 'Heart Rate',
        'HRV_SDNN' => 'HRV (SDNN)',
        'HRV_RMSSD' => 'HRV (RMSSD)',
        'SPO2_INSTANT' => 'Blood Oxygen',
        'RHR_DAILY' => 'Resting HR',
        'STEPS_DELTA' => 'Steps',
        'ENERGY_DELTA' => 'Active Energy',
        'RESP_RATE' => 'Respiratory Rate',
        'VO2_MAX' => 'VO₂ Max',
        _ => metricType,
      };

  String get metricUnit => switch (metricType) {
        'HR_INSTANT' || 'RHR_DAILY' => 'bpm',
        'HRV_SDNN' || 'HRV_RMSSD' => 'ms',
        'SPO2_INSTANT' => '%',
        'STEPS_DELTA' => 'steps',
        'ENERGY_DELTA' => 'kcal',
        'RESP_RATE' => 'br/min',
        'VO2_MAX' => 'mL/kg/min',
        _ => '',
      };
}
