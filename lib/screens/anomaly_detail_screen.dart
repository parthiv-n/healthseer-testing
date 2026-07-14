import 'package:flutter/material.dart';
import '../models/anomaly_item.dart';
import '../utils/metric_display.dart';
import '../theme/colors.dart';

// ── Lookup tables ─────────────────────────────────────────────────────────────

// _metricDisplayNames was a local map duplicating MetricDisplay.label(); it
// kept four removed v3.0 metrics (ENERGY_DELTA, DISTANCE_DELTA,
// FLOORS_CLIMBED, ENERGY_BASAL) and was missing AFIB_FLAG, BP_*, and
// SLEEP_APNEA_EVENT. Now delegates to the single source of truth so adding a
// metric type only requires editing lib/utils/metric_display.dart.

// Explanation copy uses the neutral phrase "your typical range" instead of
// "your typical range" so it's accurate for both source types: when the
// anomaly was scored against the user's own \u226514-day baseline AND when it
// was scored against the cold-start population reference. The detail screen
// renders an explicit source banner that distinguishes the two cases \u2014
// see _BaselineSourceBanner below.
const _anomalyExplanations = {
  'HR_INSTANT':
      'Your heart rate was significantly above or below your typical range. '
      'This can occur during exercise, stress, illness, or high caffeine intake. '
      'Occasional spikes are normal, but persistent patterns may warrant attention.',
  'HRV_SDNN':
      'Your heart rate variability dropped below your typical range. '
      'Low HRV can indicate fatigue, stress, illness, or insufficient recovery. '
      'HRV naturally varies day to day, so a single reading is not cause for alarm.',
  'HRV_RMSSD':
      'Your heart rate variability was outside your typical range. '
      'HRV reflects how well your nervous system is adapting to daily demands. '
      'Trends over multiple days are more meaningful than a single reading.',
  'SPO2_INSTANT':
      'Your blood oxygen level was outside your normal range. '
      'Low SpO2 can suggest breathing difficulty, poor sensor contact, or cold fingers. '
      'Repositioning your device and re-measuring may resolve a single low reading.',
  'STEPS_DELTA':
      'Your step count was significantly different from your typical daily pattern. '
      'This may reflect an unusually active or sedentary day, travel, or illness.',
  'RHR_DAILY':
      'Your resting heart rate deviated from your typical range. '
      'A temporarily elevated resting HR can indicate stress, dehydration, or the '
      'early stages of illness. A lower-than-usual reading may follow intense training.',
  'RESP_RATE':
      'Your respiratory rate was outside your normal range. '
      'Changes in breathing rate can be associated with respiratory illness, sleep quality, '
      'or changes in physical fitness. Consult a doctor if it persists.',
  'VO2_MAX':
      'Your estimated VO\u2082 Max changed from your typical level. '
      'VO\u2082 Max reflects cardiovascular fitness and changes slowly over weeks to months.',
  'EXERCISE_TIME':
      'Your recorded exercise duration was significantly different from your typical range. '
      'A notable drop may reflect illness, fatigue, or schedule changes. '
      'An unusually high reading may indicate an intense training day or data from a new activity type.',
  'SLEEP_STAGE':
      'Your sleep duration or quality was significantly different from your typical range. '
      'Sleep anomalies can reflect disrupted rest, illness, travel across time zones, or irregular bedtimes.',
  'AFIB_FLAG':
      'Atrial fibrillation was detected by your Apple Watch. AFib is associated '
      'with about a 5\u00d7 increase in stroke risk and warrants follow-up with a clinician '
      'even if you feel well. A single notification is not a diagnosis \u2014 your doctor '
      'will likely want to review the underlying ECG.',
  'BP_SYSTOLIC':
      'Your systolic (top) blood pressure was outside your typical range. '
      'Sustained values above 130 mmHg are linked to increased cardiovascular risk; '
      'a single high reading can also follow exercise, stress, or caffeine.',
  'BP_DIASTOLIC':
      'Your diastolic (bottom) blood pressure was outside your typical range. '
      'A persistently elevated diastolic reading is one of the strongest signals for '
      'starting blood-pressure conversations with a clinician.',
  'SLEEP_APNEA_EVENT':
      'Your watch flagged unusual breathing disturbances during sleep. Sleep apnea '
      'is a common but under-diagnosed condition that affects daytime energy and '
      'long-term cardiovascular health. A clinician can confirm via a take-home study.',
};

const _anomalyGuidance = {
  'HR_INSTANT_mild':
      'Take it easy and stay hydrated. Often passes by tomorrow.',
  'HR_INSTANT_moderate':
      'Rest and stay hydrated. Take it slower today; if it lingers a few days, mention it at your next visit.',
  'HR_INSTANT_severe':
      'Take a moment to rest. If you feel unwell or off, a quick chat with your doctor at your next visit can put your mind at ease.',
  'HRV_SDNN_mild':
      'Prioritize rest and sleep tonight. Reduce stress where possible.',
  'HRV_SDNN_moderate':
      'Take a recovery day — light activity only. Ensure 7-9 hours of sleep. Monitor tomorrow.',
  'HRV_SDNN_severe':
      'Make rest the priority today. If you feel unwell more broadly, worth flagging at your next visit.',
  'HRV_RMSSD_mild': 'Prioritize rest and sleep tonight. Reduce stress where possible.',
  'HRV_RMSSD_moderate':
      'Take a recovery day — light activity only. Ensure 7-9 hours of sleep.',
  'HRV_RMSSD_severe':
      'Make rest the priority today. If you feel unwell more broadly, worth flagging at your next visit.',
  'SPO2_INSTANT_mild':
      'Re-measure with your device properly positioned. Ensure your fingers are warm.',
  'SPO2_INSTANT_moderate':
      'Retake a few times. If readings stay low, take it slower today and mention it at your next visit.',
  'SPO2_INSTANT_severe':
      'If you feel short of breath and aren’t at altitude, worth bringing up at your next check-in.',
  'STEPS_DELTA_mild': 'No action required — a single unusual day is normal.',
  'STEPS_DELTA_moderate': 'Check in on your activity levels. If sedentary due to illness, rest as needed.',
  'STEPS_DELTA_severe': 'Significant deviation — verify data is accurate and monitor your wellbeing.',
  'RHR_DAILY_mild':
      'Ensure adequate hydration and sleep. Check in tomorrow.',
  'RHR_DAILY_moderate':
      'Rest well tonight. If it stays elevated for a few days, mention it at your next visit.',
  'RHR_DAILY_severe':
      'A few days at this level are worth flagging at your next check-in, especially if you have been feeling off.',
  'RESP_RATE_mild':
      'No immediate action needed. Monitor over the next day.',
  'RESP_RATE_moderate':
      'If you have a cough or feel unwell, mention it at your next visit. Otherwise just keep an eye on it.',
  'RESP_RATE_severe':
      'If your breathing feels off or you are unwell more broadly, worth bringing up at your next check-in.',
  'ENERGY_DELTA_mild': 'Normal variation — no action needed.',
  'ENERGY_DELTA_moderate': 'Assess whether this reflects illness or intentional rest.',
  'ENERGY_DELTA_severe': 'Significant deviation — confirm you are feeling well.',
  'VO2_MAX_mild': 'Normal variation. VO\u2082 Max changes slowly over weeks.',
  'VO2_MAX_moderate': 'Monitor trend over the next few weeks.',
  'VO2_MAX_severe': 'A larger drop is worth mentioning at your next check-in if you have also been feeling off.',
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
  'ENERGY_BASAL_severe': 'If a pattern persists, worth flagging at your next check-in.',
  'SLEEP_STAGE_mild': 'An occasional off night is normal. Aim for consistent sleep times.',
  'SLEEP_STAGE_moderate': 'Try to prioritize 7–9 hours of sleep. Avoid screens before bed and keep a regular schedule.',
  'SLEEP_STAGE_severe': 'A few rough nights in a row are worth raising with a doctor at your next check-in.',
};

// ── Screen ────────────────────────────────────────────────────────────────────

class AnomalyDetailScreen extends StatelessWidget {
  final AnomalyItem anomaly;
  const AnomalyDetailScreen({super.key, required this.anomaly});

  Color get _severityColor => anomaly.severityColor;

  String get _displayName {
    final fromUtility = MetricDisplay.label(anomaly.metricType);
    if (fromUtility.isNotEmpty) return fromUtility;
    return anomaly.metricLabel;
  }

  String get _explanation =>
      _anomalyExplanations[anomaly.metricType] ??
      'An anomaly was detected for this metric based on your typical range.';

  String get _guidance {
    final key = '${anomaly.metricType}_${anomaly.severity}';
    return _anomalyGuidance[key] ??
        'Keep an eye on this over the next day or two. If you feel off more broadly, worth flagging at your next check-in.';
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
                  // The phrasing changes with baseline source: "personal" rows
                  // can honestly say "vs YOUR baseline"; "community" rows must
                  // say "vs population reference" until the user crosses the
                  // 14-day threshold. Conflating the two is the same labelling
                  // bug that made the portal "Your Usual" column misleading.
                  _StatisticalContextCard(anomaly: anomaly),

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
      'severe' => 'Severe — this reading is $zAbs\u03c3 $direction your typical range. '
          'Unusual for you, but review the context below before taking action.',
      'moderate' => 'Moderate — this reading is $zAbs\u03c3 $direction your typical range. '
          'Worth monitoring over the next 24 hours.',
      _ => 'Mild — this reading is $zAbs\u03c3 $direction your typical range. '
          'A small deviation — likely normal variation.',
    };
  }

}

// ── Statistical Context Card ─────────────────────────────────────────────────
//
// Renders different copy depending on whether this anomaly was scored against
// the user's PERSONAL baseline (≥14 days of their own data), a COMMUNITY
// reference (ACC/AHA / WHO / NHANES — for cold-start), or no baseline at all
// (a hard-coded clinical safe-range gate, e.g. SpO2 < 90).
class _StatisticalContextCard extends StatelessWidget {
  final AnomalyItem anomaly;
  const _StatisticalContextCard({required this.anomaly});

  @override
  Widget build(BuildContext context) {
    final zAbs = anomaly.zScore.abs().toStringAsFixed(1);
    final dir = anomaly.zScore > 0 ? 'above' : 'below';
    final source = anomaly.baselineSource;

    // Lead sentence + footnote vary by source.
    final String leadCopy;
    final String footnoteCopy;
    if (source == 'personal') {
      final n = anomaly.baselineSampleCount ?? 0;
      leadCopy = 'This reading is ${zAbs}σ $dir YOUR personal baseline '
          '(built from $n of your own samples) — not a population average '
          'or clinical threshold.';
      footnoteCopy = 'Severity reflects statistical deviation:\n'
          '  ${AnomalyThresholds.rangeText()}\n\n'
          'A "Severe" reading means this value is very unusual for YOU specifically. '
          'It does not necessarily indicate a medical emergency.';
    } else if (source == 'community') {
      leadCopy = 'This reading is ${zAbs}σ $dir a population reference '
          '(ACC/AHA / WHO / NHANES) used while we build your personal '
          'baseline — you have ${anomaly.baselineSampleCount ?? 0} samples '
          'so far, ≥14 days needed for a personal comparison.';
      footnoteCopy = 'Severity reflects statistical deviation against the '
          'reference population — once you have ≥14 days of data, severity '
          'will recalibrate against YOUR own typical range. '
          'A "Severe" reading here means this value is unusual for the '
          'reference cohort and worth monitoring.';
    } else {
      // No baseline — hard-coded clinical gate (e.g. SpO2 < 90, AFib detected).
      leadCopy = 'This reading triggered a clinical safe-range alert — '
          'it crossed a fixed medical threshold rather than a statistical baseline.';
      footnoteCopy = 'Severity reflects how far the reading is outside the '
          'safe-range gate, which is set from medical guidelines and does '
          'not depend on personal history. Consult a clinician if you feel '
          'unwell.';
    }

    return Container(
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
            // Source chip — at-a-glance honesty about which comparator was used.
            const SizedBox(width: 6),
            _SourceChip(source: source),
          ]),
          const SizedBox(height: 8),
          Text(
            leadCopy,
            style: TextStyle(fontSize: 12, color: Colors.blue.shade800, height: 1.5),
          ),
          const SizedBox(height: 6),
          Text(
            footnoteCopy,
            style: TextStyle(fontSize: 11, color: Colors.blue.shade600, height: 1.5),
          ),
        ],
      ),
    );
  }
}

class _SourceChip extends StatelessWidget {
  final String? source;
  const _SourceChip({required this.source});

  @override
  Widget build(BuildContext context) {
    final (label, fg, bg) = switch (source) {
      'personal'  => ('PERSONAL',     const Color(0xFF1E40AF), const Color(0xFFDBEAFE)),
      'community' => ('REFERENCE',    const Color(0xFF92400E), const Color(0xFFFEF3C7)),
      _           => ('CLINICAL GATE',const Color(0xFF991B1B), const Color(0xFFFEE2E2)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w800,
          color: fg,
          letterSpacing: 0.4,
        ),
      ),
    );
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
