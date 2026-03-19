import 'package:flutter/material.dart';
import '../models/anomaly_item.dart';

const _navy = Color(0xFF1B3A6B);
const _navyLight = Color(0xFF2A5298);
const _amber = Color(0xFFD97706);
const _red = Color(0xFFE53E3E);
const _orange = Color(0xFFDD6B20);
const _bg = Color(0xFFF7F9FC);

// ── Lookup tables ─────────────────────────────────────────────────────────────

const _metricDisplayNames = {
  'HR_INSTANT': 'Heart Rate',
  'HRV_SDNN': 'Heart Rate Variability',
  'HRV_RMSSD': 'Heart Rate Variability',
  'SPO2_INSTANT': 'Blood Oxygen',
  'STEPS_DELTA': 'Step Count',
  'RHR_DAILY': 'Resting Heart Rate',
  'RESP_RATE': 'Respiratory Rate',
  'ENERGY_DELTA': 'Active Energy',
  'VO2_MAX': 'VO\u2082 Max',
  'DISTANCE_DELTA': 'Distance',
  'FLOORS_CLIMBED': 'Floors Climbed',
  'EXERCISE_TIME': 'Exercise Time',
  'ENERGY_BASAL': 'Basal Energy',
  'SLEEP_STAGE': 'Sleep',
};

const _anomalyExplanations = {
  'HR_INSTANT':
      'Your heart rate was significantly above or below your personal baseline. '
      'This can occur during exercise, stress, illness, or high caffeine intake. '
      'Occasional spikes are normal, but persistent patterns may warrant attention.',
  'HRV_SDNN':
      'Your heart rate variability dropped below your personal baseline. '
      'Low HRV can indicate fatigue, stress, illness, or insufficient recovery. '
      'HRV naturally varies day to day, so a single reading is not cause for alarm.',
  'HRV_RMSSD':
      'Your heart rate variability was outside your personal baseline range. '
      'HRV reflects how well your nervous system is adapting to daily demands. '
      'Trends over multiple days are more meaningful than a single reading.',
  'SPO2_INSTANT':
      'Your blood oxygen level was outside your normal range. '
      'Low SpO2 can suggest breathing difficulty, poor sensor contact, or cold fingers. '
      'Repositioning your device and re-measuring may resolve a single low reading.',
  'STEPS_DELTA':
      'Your step count was significantly different from your typical daily pattern. '
      'This may reflect an unusually active or sedentary day, travel, or illness. '
      'TikCare compares this against your personal rolling average.',
  'RHR_DAILY':
      'Your resting heart rate deviated from your personal baseline. '
      'A temporarily elevated resting HR can indicate stress, dehydration, or the '
      'early stages of illness. A lower-than-usual reading may follow intense training.',
  'RESP_RATE':
      'Your respiratory rate was outside your normal range. '
      'Changes in breathing rate can be associated with respiratory illness, sleep quality, '
      'or changes in physical fitness. Consult a doctor if it persists.',
  'ENERGY_DELTA':
      'Your active energy output was significantly different from your baseline. '
      'This may reflect a very active or very sedentary day, or changes in your activity.',
  'VO2_MAX':
      'Your estimated VO\u2082 Max changed from your personal baseline. '
      'VO\u2082 Max reflects cardiovascular fitness and changes slowly over weeks to months.',
};

const _anomalyGuidance = {
  'HR_INSTANT_mild':
      'Monitor over the next few hours. Avoid stimulants like caffeine. Stay hydrated.',
  'HR_INSTANT_moderate':
      'Rest and stay hydrated. Avoid strenuous activity. If it persists for several hours, consult a doctor.',
  'HR_INSTANT_severe':
      'Seek medical attention if you feel unwell, dizzy, or have chest discomfort. Contact your doctor promptly.',
  'HRV_SDNN_mild':
      'Prioritize rest and sleep tonight. Reduce stress where possible.',
  'HRV_SDNN_moderate':
      'Take a recovery day — light activity only. Ensure 7-9 hours of sleep. Monitor tomorrow.',
  'HRV_SDNN_severe':
      'Focus on full rest. If accompanied by symptoms like illness or chest tightness, see a doctor.',
  'HRV_RMSSD_mild': 'Prioritize rest and sleep tonight. Reduce stress where possible.',
  'HRV_RMSSD_moderate':
      'Take a recovery day — light activity only. Ensure 7-9 hours of sleep.',
  'HRV_RMSSD_severe':
      'Focus on full rest. If accompanied by illness or chest tightness, see a doctor.',
  'SPO2_INSTANT_mild':
      'Re-measure with your device properly positioned. Ensure your fingers are warm.',
  'SPO2_INSTANT_moderate':
      'Re-measure several times. If readings remain low, reduce physical exertion and consult a doctor.',
  'SPO2_INSTANT_severe':
      'Seek medical attention, especially if accompanied by shortness of breath or dizziness.',
  'STEPS_DELTA_mild': 'No action required — a single unusual day is normal.',
  'STEPS_DELTA_moderate': 'Check in on your activity levels. If sedentary due to illness, rest as needed.',
  'STEPS_DELTA_severe': 'Significant deviation — verify data is accurate and monitor your wellbeing.',
  'RHR_DAILY_mild':
      'Ensure adequate hydration and sleep. Check in tomorrow.',
  'RHR_DAILY_moderate':
      'Rest well tonight. If elevated for 2+ days, consider consulting a doctor.',
  'RHR_DAILY_severe':
      'Persistently elevated resting HR warrants a doctor visit, especially with symptoms.',
  'RESP_RATE_mild':
      'No immediate action needed. Monitor over the next day.',
  'RESP_RATE_moderate':
      'If you have other symptoms (cough, fever), see a doctor. Otherwise monitor closely.',
  'RESP_RATE_severe':
      'Seek medical attention, especially if breathing feels labored or you feel unwell.',
  'ENERGY_DELTA_mild': 'Normal variation — no action needed.',
  'ENERGY_DELTA_moderate': 'Assess whether this reflects illness or intentional rest.',
  'ENERGY_DELTA_severe': 'Significant deviation — confirm you are feeling well.',
  'VO2_MAX_mild': 'Normal variation. VO\u2082 Max changes slowly over weeks.',
  'VO2_MAX_moderate': 'Monitor trend over the next few weeks.',
  'VO2_MAX_severe': 'Consult a doctor if a large drop accompanies other symptoms.',
};

// ── Screen ────────────────────────────────────────────────────────────────────

class AnomalyDetailScreen extends StatelessWidget {
  final AnomalyItem anomaly;
  const AnomalyDetailScreen({super.key, required this.anomaly});

  Color get _severityColor => switch (anomaly.severity) {
        'severe' => _red,
        'moderate' => _orange,
        _ => _amber,
      };

  String get _displayName =>
      _metricDisplayNames[anomaly.metricType] ?? anomaly.metricLabel;

  String get _explanation =>
      _anomalyExplanations[anomaly.metricType] ??
      'An anomaly was detected for this metric based on your personal baseline.';

  String get _guidance {
    final key = '${anomaly.metricType}_${anomaly.severity}';
    return _anomalyGuidance[key] ??
        'Monitor this metric over the next 24 hours. If you feel unwell, consult your doctor.';
  }

  @override
  Widget build(BuildContext context) {
    final color = _severityColor;
    final dt = anomaly.eventTimestamp;
    final dateStr =
        '${dt.month}/${dt.day}/${dt.year} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

    return Scaffold(
      backgroundColor: _bg,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 100,
            pinned: true,
            backgroundColor: _navy,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [_navy, _navyLight],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(56, 16, 16, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _displayName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Anomaly detail',
                          style: const TextStyle(color: Colors.white60, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── Header card ────────────────────────────────────────────
                  _Card(
                    child: Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.1),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            _metricIcon(anomaly.metricType),
                            size: 24,
                            color: color,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _displayName,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: _navy,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                dateStr,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ),
                        _SeverityBadge(severity: anomaly.severity, color: color),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // ── Value card ─────────────────────────────────────────────
                  _Card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _SectionLabel(label: 'YOUR READING'),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: _ValueTile(
                                label: 'Measured',
                                value: anomaly.value.toStringAsFixed(1),
                                unit: anomaly.metricUnit,
                                color: color,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _ValueTile(
                                label: 'z-score',
                                value: anomaly.zScore.toStringAsFixed(2),
                                unit: '\u03c3',
                                color: Colors.grey.shade600,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _ValueTile(
                                label: 'Confidence',
                                value:
                                    (anomaly.confidence * 100).toStringAsFixed(0),
                                unit: '%',
                                color: _navy,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // ── Severity gauge ─────────────────────────────────────────
                  _Card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _SectionLabel(label: 'SEVERITY'),
                        const SizedBox(height: 12),
                        _SeverityGauge(severity: anomaly.severity),
                        const SizedBox(height: 8),
                        Text(
                          _severityDescription(anomaly.severity, anomaly.zScore),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.black54,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // ── Explanation ────────────────────────────────────────────
                  _Card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _SectionLabel(label: 'WHAT THIS MEANS'),
                        const SizedBox(height: 12),
                        if (anomaly.explanation.isNotEmpty) ...[
                          Text(
                            anomaly.explanation,
                            style: const TextStyle(
                              fontSize: 13,
                              color: _navy,
                              fontWeight: FontWeight.w500,
                              height: 1.5,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Divider(height: 1),
                          const SizedBox(height: 8),
                        ],
                        Text(
                          _explanation,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Colors.black54,
                            height: 1.55,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // ── Guidance ───────────────────────────────────────────────
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: color.withValues(alpha: 0.2)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.tips_and_updates_outlined,
                              size: 15,
                              color: color,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'RECOMMENDED ACTION',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: color,
                                letterSpacing: 0.6,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _guidance,
                          style: TextStyle(
                            fontSize: 13,
                            color: color,
                            height: 1.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // ── Disclaimer ────────────────────────────────────────────
                  const Text(
                    'This information is for awareness only and is not medical advice. '
                    'Always consult a qualified healthcare professional for medical concerns.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.grey,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _severityDescription(String severity, double z) {
    return switch (severity) {
      'severe' => 'Severe (|z| \u2265 6.5\u03c3) — this reading is far outside your personal '
          'baseline and warrants close attention.',
      'moderate' => 'Moderate (4.5 \u2264 |z| < 6.5\u03c3) — this reading is notably outside '
          'your typical range.',
      _ => 'Mild (3.0 \u2264 |z| < 4.5\u03c3) — this reading is slightly outside your '
          'personal baseline. Monitor over the next few hours.',
    };
  }

  IconData _metricIcon(String metricType) {
    return switch (metricType) {
      'HR_INSTANT' || 'RHR_DAILY' => Icons.favorite,
      'HRV_SDNN' || 'HRV_RMSSD' => Icons.monitor_heart,
      'SPO2_INSTANT' => Icons.water_drop,
      'STEPS_DELTA' => Icons.directions_walk,
      'ENERGY_DELTA' || 'ENERGY_BASAL' => Icons.local_fire_department,
      'RESP_RATE' => Icons.air,
      'VO2_MAX' => Icons.bolt,
      _ => Icons.show_chart,
    };
  }
}

// ── Severity Gauge ────────────────────────────────────────────────────────────

class _SeverityGauge extends StatelessWidget {
  final String severity;
  const _SeverityGauge({required this.severity});

  @override
  Widget build(BuildContext context) {
    // Marker position: mild=0.2, moderate=0.55, severe=0.88
    final markerPos = switch (severity) {
      'severe' => 0.88,
      'moderate' => 0.55,
      _ => 0.2,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            // Gradient bar
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Container(
                height: 12,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Color(0xFF38A169),
                      Color(0xFFD97706),
                      Color(0xFFE53E3E),
                    ],
                  ),
                ),
              ),
            ),
            // Marker
            Positioned(
              left: null,
              child: FractionallySizedBox(
                widthFactor: markerPos,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Container(
                    width: 4,
                    height: 20,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(2),
                      boxShadow: const [
                        BoxShadow(color: Colors.black26, blurRadius: 4),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: const [
            Text('Normal', style: TextStyle(fontSize: 9, color: Colors.grey)),
            Text('Mild', style: TextStyle(fontSize: 9, color: Colors.grey)),
            Text('Moderate', style: TextStyle(fontSize: 9, color: Colors.grey)),
            Text('Severe', style: TextStyle(fontSize: 9, color: Colors.grey)),
          ],
        ),
      ],
    );
  }
}

// ── Severity Badge ─────────────────────────────────────────────────────────────

class _SeverityBadge extends StatelessWidget {
  final String severity;
  final Color color;
  const _SeverityBadge({required this.severity, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Text(
        severity[0].toUpperCase() + severity.substring(1),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

// ── Value Tile ────────────────────────────────────────────────────────────────

class _ValueTile extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final Color color;
  const _ValueTile({
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F4FF),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
          const SizedBox(height: 4),
          RichText(
            text: TextSpan(
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: color,
              ),
              children: [
                TextSpan(text: value),
                TextSpan(
                  text: ' $unit',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w400),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Shared card/label widgets ─────────────────────────────────────────────────

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: Colors.grey,
        letterSpacing: 0.8,
      ),
    );
  }
}
