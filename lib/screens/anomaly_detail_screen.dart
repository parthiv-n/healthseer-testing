import 'package:flutter/material.dart';
import '../models/anomaly_item.dart';
import '../theme/colors.dart';

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
  'DISTANCE_DELTA':
      'Your total distance traveled was significantly different from your typical day. '
      'This may reflect an unusually active or sedentary day, travel, illness, or a change in routine. '
      'TikCare compares this against your personal rolling average.',
  'FLOORS_CLIMBED':
      'The number of floors you climbed was significantly different from your typical pattern. '
      'This may reflect a change in environment, routine, or physical capability. '
      'A single unusual day is generally not a concern.',
  'EXERCISE_TIME':
      'Your recorded exercise duration was significantly different from your baseline. '
      'A notable drop may reflect illness, fatigue, or schedule changes. '
      'An unusually high reading may indicate an intense training day or data from a new activity type.',
  'ENERGY_BASAL':
      'Your basal metabolic energy output shifted from your baseline. '
      'Basal energy reflects the calories your body burns at rest, which can vary with sleep quality, '
      'body temperature, and overall health status.',
  'SLEEP_STAGE':
      'Your sleep duration or quality was significantly different from your personal baseline. '
      'Sleep anomalies can reflect disrupted rest, illness, travel across time zones, or irregular bedtimes.',
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
  'DISTANCE_DELTA_mild': 'Normal variation — a single unusual day requires no action.',
  'DISTANCE_DELTA_moderate': 'Check whether you are feeling well. If sedentary due to illness, rest as needed.',
  'DISTANCE_DELTA_severe': 'Significant deviation from your routine — confirm you are feeling well and that data is accurate.',
  'FLOORS_CLIMBED_mild': 'Normal variation — no action needed.',
  'FLOORS_CLIMBED_moderate': 'No action needed for a single day. Monitor if the pattern continues.',
  'FLOORS_CLIMBED_severe': 'Unusual activity change — verify data accuracy and check in on your wellbeing.',
  'EXERCISE_TIME_mild': 'Normal variation — no action needed.',
  'EXERCISE_TIME_moderate': 'If this reflects reduced activity due to illness or fatigue, rest and recover.',
  'EXERCISE_TIME_severe': 'A large change in exercise time — check you are feeling well and that all activity was recorded correctly.',
  'ENERGY_BASAL_mild': 'Normal day-to-day variation — no action needed.',
  'ENERGY_BASAL_moderate': 'Ensure you are well-rested and healthy. Unusual basal energy can accompany illness.',
  'ENERGY_BASAL_severe': 'Persistent changes in basal energy may warrant a check-in with your doctor.',
  'SLEEP_STAGE_mild': 'An occasional off night is normal. Aim for consistent sleep times.',
  'SLEEP_STAGE_moderate': 'Try to prioritize 7–9 hours of sleep. Avoid screens before bed and keep a regular schedule.',
  'SLEEP_STAGE_severe': 'Severely disrupted sleep can affect your overall health. If this persists, consult a doctor.',
};

// ── Screen ────────────────────────────────────────────────────────────────────

class AnomalyDetailScreen extends StatelessWidget {
  final AnomalyItem anomaly;
  const AnomalyDetailScreen({super.key, required this.anomaly});

  Color get _severityColor => anomaly.severityColor;

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
        '${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')}/${dt.year} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

    return Scaffold(
      backgroundColor: kBg,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 100,
            pinned: true,
            backgroundColor: kNavy,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [kNavy, kNavyLight],
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
                            anomaly.metricIcon,
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
                                  color: kNavy,
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
                        _SeverityBadge(label: anomaly.severityDisplay, color: color),
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
                                label: 'Direction',
                                value: anomaly.zScore > 0 ? '↑ High' : anomaly.zScore < 0 ? '↓ Low' : '⚠ Unusual',
                                unit: '',
                                color: anomaly.zScore > 0 ? kRed : anomaly.zScore < 0 ? const Color(0xFF2563EB) : Colors.grey,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _ValueTile(
                                label: 'Confidence',
                                value:
                                    (anomaly.confidence * 100).toStringAsFixed(0),
                                unit: '%',
                                color: kNavy,
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

                  const SizedBox(height: 8),

                  // ── Statistical context — prevents user panic ───────────────
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.blue.shade100),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Icon(Icons.bar_chart_outlined, size: 14, color: Colors.blue.shade700),
                          const SizedBox(width: 6),
                          Text(
                            'STATISTICAL CONTEXT',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Colors.blue.shade700,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ]),
                        const SizedBox(height: 8),
                        Text(
                          'This reading is ${anomaly.zScore.abs().toStringAsFixed(1)}σ (standard deviations) ${anomaly.zScore > 0 ? "above" : "below"} YOUR personal baseline — not a population average or clinical threshold.',
                          style: TextStyle(fontSize: 12, color: Colors.blue.shade800, height: 1.5),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Severity reflects statistical deviation:\n'
                          '  Mild: 3.0–4.5σ   Moderate: 4.5–6.5σ   Severe: ≥ 6.5σ\n\n'
                          'A "Severe" reading means this value is very unusual for YOU specifically. It does not necessarily indicate a medical emergency.',
                          style: TextStyle(fontSize: 11, color: Colors.blue.shade600, height: 1.5),
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
                              color: kNavy,
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
    final direction = z > 0 ? 'above' : z < 0 ? 'below' : 'outside';
    final zAbs = z.abs().toStringAsFixed(1);
    return switch (severity) {
      'severe' => 'Severe — this reading is $zAbs\u03c3 $direction your personal baseline. '
          'Unusual for you, but review the context below before taking action.',
      'moderate' => 'Moderate — this reading is $zAbs\u03c3 $direction your typical range. '
          'Worth monitoring over the next 24 hours.',
      _ => 'Mild — this reading is $zAbs\u03c3 $direction your personal baseline. '
          'A small deviation — likely normal variation.',
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
        LayoutBuilder(
          builder: (context, constraints) {
            final left = (markerPos * constraints.maxWidth - 2).clamp(0.0, constraints.maxWidth - 4);
            return Stack(
              clipBehavior: Clip.none,
              children: [
                // Gradient bar
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    height: 12,
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [kGreen, kAmber, kRed],
                      ),
                    ),
                  ),
                ),
                // Marker
                Positioned(
                  left: left,
                  top: -4,
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
              ],
            );
          },
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
  final String label;
  final Color color;
  const _SeverityBadge({required this.label, required this.color});

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
        label,
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
