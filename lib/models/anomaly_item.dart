import 'dart:ui';
import '../theme/colors.dart';

class Icons {
  static const IconData favorite = IconData(0xe87d, fontFamily: 'MaterialIcons');
  static const IconData monitor_heart = IconData(0xf0fc, fontFamily: 'MaterialIcons');
  static const IconData water_drop = IconData(0xe73e, fontFamily: 'MaterialIcons');
  static const IconData directions_walk = IconData(0xe531, fontFamily: 'MaterialIcons');
  static const IconData air = IconData(0xe50a, fontFamily: 'MaterialIcons');
  static const IconData bolt = IconData(0xe0e7, fontFamily: 'MaterialIcons');
  static const IconData speed = IconData(0xe52d, fontFamily: 'MaterialIcons');
  static const IconData bedtime = IconData(0xe1bd, fontFamily: 'MaterialIcons');
  static const IconData warning_amber = IconData(0xe002, fontFamily: 'MaterialIcons');
  static const IconData fitness_center = IconData(0xeb43, fontFamily: 'MaterialIcons');
  static const IconData show_chart = IconData(0xe24f, fontFamily: 'MaterialIcons');
}

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
  // "personal" — anomaly was scored against this user's own baseline
  // (≥14 days of recordings); "community" — scored against the ACC/AHA /
  // WHO / NHANES population reference because the user hasn't crossed the
  // threshold yet; null — fired by a hard-coded clinical safe-range gate
  // (e.g. SpO2 < 90% regardless of baseline). Drives the explanation copy
  // so we never claim "your personal baseline" when it was actually a
  // population reference.
  final String? baselineSource;
  final int? baselineSampleCount;

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
    this.baselineSource,
    this.baselineSampleCount,
  });

  factory AnomalyItem.fromJson(Map<String, dynamic> j) => AnomalyItem(
        id: j['id']?.toString() ?? '',
        metricType: j['metric_type'] as String? ?? '',
        value: (j['value'] as num?)?.toDouble() ?? 0.0,
        // Use epoch as fallback so bad/missing timestamps never appear in the
        // "Today" filter (epoch is 1970 — always in the past).
        eventTimestamp: j['event_timestamp'] != null
            ? (DateTime.tryParse(j['event_timestamp'] as String) ?? DateTime.utc(1970)).toLocal()
            : DateTime.utc(1970).toLocal(),
        zScore: (j['z_score'] as num?)?.toDouble() ?? 0.0,
        severity: j['severity'] as String? ?? 'mild',
        confidence: (j['confidence'] as num?)?.toDouble() ?? 0.0,
        explanation: j['explanation'] as String? ?? '',
        detectedAt: j['detected_at'] != null
            ? (DateTime.tryParse(j['detected_at'] as String) ?? DateTime.utc(1970)).toLocal()
            : DateTime.utc(1970).toLocal(),
        baselineSource: j['baseline_source'] as String?,
        baselineSampleCount: (j['baseline_sample_count'] as num?)?.toInt(),
      );

  /// True when the anomaly was scored against this user's own data
  /// (≥14 days). False when the comparator is a population reference or
  /// a hard-coded clinical gate. UI copy should distinguish.
  bool get isPersonalBaseline => baselineSource == 'personal';

  // v3.0 metric labels — 14 supported types
  String get metricLabel => switch (metricType) {
        'HR_INSTANT' => 'Heart Rate',
        'HRV_SDNN' => 'HRV (SDNN)',
        'HRV_RMSSD' => 'HRV (RMSSD)',
        'SPO2_INSTANT' => 'Blood Oxygen',
        'RHR_DAILY' => 'Resting HR',
        'STEPS_DELTA' => 'Steps',
        'RESP_RATE' => 'Respiratory Rate',
        'VO2_MAX' => 'VO₂ Max',
        'BP_SYSTOLIC' => 'BP (Systolic)',
        'BP_DIASTOLIC' => 'BP (Diastolic)',
        'SLEEP_APNEA_EVENT' => 'Sleep Apnea',
        'AFIB_FLAG' => 'AFib Detection',
        'EXERCISE_TIME' => 'Exercise Time',
        'SLEEP_STAGE' => 'Sleep',
        _ => metricType,
      };

  String get metricUnit => switch (metricType) {
        'HR_INSTANT' || 'RHR_DAILY' => 'bpm',
        'HRV_SDNN' || 'HRV_RMSSD' => 'ms',
        'SPO2_INSTANT' => '%',
        'STEPS_DELTA' => 'steps',
        'RESP_RATE' => 'br/min',
        'VO2_MAX' => 'mL/kg/min',
        'BP_SYSTOLIC' || 'BP_DIASTOLIC' => 'mmHg',
        'SLEEP_APNEA_EVENT' => 'events',
        'AFIB_FLAG' => '',
        'EXERCISE_TIME' || 'SLEEP_STAGE' => 'min',
        _ => '',
      };

  Color get severityColor => switch (severity) {
        'severe' => kRed,
        'moderate' => kOrange,
        _ => kAmber,
      };

  String get severityDisplay =>
      severity.isEmpty ? 'Unknown' : severity[0].toUpperCase() + severity.substring(1);

  IconData get metricIcon => switch (metricType) {
        'HR_INSTANT' || 'RHR_DAILY' => Icons.favorite,
        'HRV_SDNN' || 'HRV_RMSSD' => Icons.monitor_heart,
        'SPO2_INSTANT' => Icons.water_drop,
        'STEPS_DELTA' => Icons.directions_walk,
        'RESP_RATE' => Icons.air,
        'VO2_MAX' => Icons.bolt,
        'BP_SYSTOLIC' || 'BP_DIASTOLIC' => Icons.speed,
        'SLEEP_APNEA_EVENT' => Icons.bedtime,
        'AFIB_FLAG' => Icons.warning_amber,
        'EXERCISE_TIME' => Icons.fitness_center,
        'SLEEP_STAGE' => Icons.bedtime,
        _ => Icons.show_chart,
      };
}
