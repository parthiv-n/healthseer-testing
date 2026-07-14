/// metric_display.dart — Single source of truth for metric display in the Flutter app.
///
/// Mirrors:
///   - frontend/shared/metric_display.js   (web portal + dashboard)
///   - app/core/anomaly/detector.py        (anomaly thresholds)
///   - app/core/reporting/daily.py         (HRI bands)
///
/// When you change a metric's display, update all four. The audit checklist is in CLAUDE.md.

import 'package:flutter/material.dart';

class MetricMeta {
  /// Human-readable name shown in tile labels, charts, and tooltips.
  final String label;

  /// Unit the user reads on screen — e.g. '%', 'bpm', 'ms'.
  final String displayUnit;

  /// Unit on the BACKEND wire / DB. May differ from `displayUnit` when the
  /// canonical storage form is more compact than the human-friendly form
  /// (e.g. SpO2 is stored as a 0–1 fraction; users read it as a percentage).
  /// `MetricDisplay.formatWithUnit` and `formatValue` apply `scale` to
  /// translate from stored-form to display-form. **Callers must always pass
  /// the backend-stored value**; if your in-memory copy is already scaled
  /// (e.g. the Flutter HealthSnapshot pre-multiplies SpO2 ×100), divide it
  /// back to fraction before calling formatWithUnit, OR build the display
  /// string directly without going through this utility.
  final String storedUnit;

  /// `display = stored * scale`. 1.0 for round-trip metrics (HR, HRV, etc.);
  /// 100 for SpO2 (fraction → %).
  final double scale;

  final int decimals;
  final String tip;

  const MetricMeta({
    required this.label,
    required this.displayUnit,
    required this.storedUnit,
    this.scale = 1.0,
    this.decimals = 1,
    this.tip = '',
  });
}

/// Single source of truth for the 14 Vitametric metric types.
///
/// `scale` converts stored backend value -> display value.
/// SpO2 is stored as fraction (0.97); displayed as 97.0%. scale = 100.
/// All others currently round-trip 1:1.
const Map<String, MetricMeta> _kMetricMeta = {
  'HR_INSTANT': MetricMeta(
    label: 'Heart Rate',
    displayUnit: 'bpm',
    storedUnit: 'bpm',
    decimals: 1,
    tip: 'Instantaneous heart rate. Measured continuously during wear.',
  ),
  'RHR_DAILY': MetricMeta(
    label: 'Resting Heart Rate',
    displayUnit: 'bpm',
    storedUnit: 'bpm',
    decimals: 1,
    tip: 'Daily resting heart rate. Lower is generally healthier for adults.',
  ),
  'HRV_SDNN': MetricMeta(
    label: 'HRV (SDNN)',
    displayUnit: 'ms',
    storedUnit: 'ms',
    decimals: 1,
    tip: 'Heart rate variability. Higher values indicate better autonomic flexibility.',
  ),
  'HRV_RMSSD': MetricMeta(
    label: 'HRV (RMSSD)',
    displayUnit: 'ms',
    storedUnit: 'ms',
    decimals: 1,
    tip: 'Heart rate variability. Sensitive marker of parasympathetic recovery.',
  ),
  'SPO2_INSTANT': MetricMeta(
    label: 'Blood Oxygen (SpO₂)',
    displayUnit: '%',
    storedUnit: 'fraction',
    scale: 100.0,
    decimals: 1,
    tip: 'Blood oxygen saturation. Normal: 95–100%.',
  ),
  'RESP_RATE': MetricMeta(
    label: 'Respiratory Rate',
    displayUnit: 'breaths/min',
    storedUnit: 'breaths/min',
    decimals: 1,
    tip: 'Breathing rate. Normal adult range: 12–20 breaths per minute at rest.',
  ),
  'VO2_MAX': MetricMeta(
    label: 'VO₂ Max',
    displayUnit: 'mL/kg/min',
    storedUnit: 'mL/kg/min',
    decimals: 1,
    tip: 'Cardiorespiratory fitness estimate. Higher values indicate better aerobic fitness.',
  ),
  'BP_SYSTOLIC': MetricMeta(
    label: 'Blood Pressure (Sys)',
    displayUnit: 'mmHg',
    storedUnit: 'mmHg',
    decimals: 0,
    tip: 'Systolic blood pressure. Normal: <120 mmHg.',
  ),
  'BP_DIASTOLIC': MetricMeta(
    label: 'Blood Pressure (Dia)',
    displayUnit: 'mmHg',
    storedUnit: 'mmHg',
    decimals: 0,
    tip: 'Diastolic blood pressure. Normal: <80 mmHg.',
  ),
  'SLEEP_APNEA_EVENT': MetricMeta(
    label: 'Sleep Apnea Events',
    displayUnit: 'events',
    storedUnit: 'events',
    decimals: 0,
    tip: 'Breathing disturbances. AHI ≥5 = mild, ≥15 = moderate, ≥30 = severe.',
  ),
  'AFIB_FLAG': MetricMeta(
    label: 'AFib Detection',
    displayUnit: '',
    storedUnit: 'flag',
    decimals: 0,
    tip: 'Atrial fibrillation detected by Apple Watch. Associated with 5× stroke risk.',
  ),
  'STEPS_DELTA': MetricMeta(
    label: 'Steps',
    displayUnit: 'steps',
    storedUnit: 'steps',
    decimals: 0,
    tip: 'Step count per recording interval (typically 1–15 min).',
  ),
  'SLEEP_STAGE': MetricMeta(
    label: 'Sleep Stage',
    displayUnit: 'min',
    storedUnit: 'min',
    decimals: 0,
    tip: 'Duration spent in this sleep stage, in minutes.',
  ),
  // v4.4: granular per-stage types so the portal can render Deep / REM /
  // Light as separate tiles. Same display contract as SLEEP_STAGE.
  'SLEEP_DEEP': MetricMeta(
    label: 'Deep Sleep',
    displayUnit: 'min',
    storedUnit: 'min',
    decimals: 0,
    tip: 'Time in deep (slow-wave) sleep — most restorative stage.',
  ),
  'SLEEP_REM': MetricMeta(
    label: 'REM Sleep',
    displayUnit: 'min',
    storedUnit: 'min',
    decimals: 0,
    tip: 'Time in REM sleep — supports memory and emotional regulation.',
  ),
  'SLEEP_LIGHT': MetricMeta(
    label: 'Light Sleep',
    displayUnit: 'min',
    storedUnit: 'min',
    decimals: 0,
    tip: 'Time in light sleep — the dominant stage of a normal night.',
  ),
  'EXERCISE_TIME': MetricMeta(
    label: 'Exercise Time',
    displayUnit: 'min',
    storedUnit: 'min',
    decimals: 0,
    tip: 'Minutes of elevated-heart-rate activity.',
  ),
};

const MetricMeta _kFallback = MetricMeta(
  label: '',
  displayUnit: '',
  storedUnit: '',
);

class MetricDisplay {
  const MetricDisplay._();

  static MetricMeta meta(String metricType) {
    final m = _kMetricMeta[metricType];
    if (m != null) return m;
    return MetricMeta(
      label: metricType.replaceAll('_', ' '),
      displayUnit: '',
      storedUnit: '',
    );
  }

  static String label(String metricType) => meta(metricType).label;
  static String displayUnit(String metricType) => meta(metricType).displayUnit;
  static String storedUnit(String metricType) => meta(metricType).storedUnit;
  static String tip(String metricType) => meta(metricType).tip;
  static int decimals(String metricType) => meta(metricType).decimals;
  static double scale(String metricType) => meta(metricType).scale;
  static List<String> allMetrics() => _kMetricMeta.keys.toList();

  /// Convert a stored backend value to its display value (applies scale).
  static double? toDisplayValue(String metricType, num? storedValue) {
    if (storedValue == null) return null;
    return storedValue.toDouble() * scale(metricType);
  }

  /// Format AFIB_FLAG specially as "Detected" / "None".
  static String formatAfib(num? storedValue) {
    if (storedValue == null) return '—';
    return storedValue > 0 ? 'Detected' : 'None';
  }

  /// Format a stored value with its unit suffix.
  ///
  /// Examples:
  ///   formatWithUnit('SPO2_INSTANT', 0.97) -> "97.0%"
  ///   formatWithUnit('HR_INSTANT', 72.3)   -> "72.3 bpm"
  ///   formatWithUnit('AFIB_FLAG', 1)       -> "Detected"
  static String formatWithUnit(String metricType, num? storedValue) {
    if (storedValue == null) return '—';
    if (metricType == 'AFIB_FLAG') return formatAfib(storedValue);
    final m = meta(metricType);
    final v = storedValue.toDouble() * m.scale;
    if (v.isNaN || v.isInfinite) return '—';
    final num_ = v.toStringAsFixed(m.decimals);
    if (m.displayUnit == '%') return '$num_%';
    if (m.displayUnit.isEmpty) return num_;
    return '$num_ ${m.displayUnit}';
  }

  /// Format value only (no unit), useful when unit lives in a separate column.
  static String formatValue(String metricType, num? storedValue) {
    if (storedValue == null) return '—';
    if (metricType == 'AFIB_FLAG') return formatAfib(storedValue);
    final m = meta(metricType);
    final v = storedValue.toDouble() * m.scale;
    if (v.isNaN || v.isInfinite) return '—';
    return v.toStringAsFixed(m.decimals);
  }
}

/// Anomaly severity thresholds — must match `app/core/anomaly/detector.py`.
/// Recalibrated 2026 for daily-aggregate detection (was 3.0/4.5/6.5).
class AnomalyThresholds {
  const AnomalyThresholds._();

  static const double mildMin = 2.0;
  static const double moderateMin = 3.0;
  static const double severeMin = 4.5;

  static String classify(double? z) {
    if (z == null || z.isNaN || z.isInfinite) return 'unknown';
    final az = z.abs();
    if (az < mildMin) return 'normal';
    if (az < moderateMin) return 'mild';
    if (az < severeMin) return 'moderate';
    return 'severe';
  }

  static String rangeText() =>
      'Mild: 2.0–3.0σ · Moderate: 3.0–4.5σ · Severe: ≥4.5σ';
}

/// HRI bands — must match `app/core/reporting/daily.py:_abi_label`.
class HriBands {
  const HriBands._();

  static const double excellentMax = 20.0;
  static const double goodMax = 40.0;
  static const double moderateMax = 60.0;
  static const double elevatedMax = 80.0;

  static String label(double? hri) {
    if (hri == null) return 'unknown';
    if (hri < excellentMax) return 'excellent';
    if (hri < goodMax) return 'good';
    if (hri < moderateMax) return 'moderate';
    if (hri < elevatedMax) return 'elevated';
    return 'critical';
  }

  static Color color(double? hri, {Color? unknown}) {
    switch (label(hri)) {
      case 'excellent':
      case 'good':
        return const Color(0xFF22C55E);
      case 'moderate':
        return const Color(0xFFF59E0B);
      case 'elevated':
        return const Color(0xFFFB923C);
      case 'critical':
        return const Color(0xFFEF4444);
      default:
        return unknown ?? const Color(0xFF94A3B8);
    }
  }
}

/// ABI tier system (v4.4) — mirrors `app/core/reporting/daily.py:AbiTier`.
///
/// The backend always returns one of three tiers:
/// - `accumulating`  → < 14 days of personal baseline; ABI not yet displayed
/// - `base`          → ≥ 14 days; only HR + Steps + Sleep available
/// - `comprehensive` → ≥ 14 days; HRV / SpO₂ / VO₂ Max / etc. also available
///
/// Adequacy stage is independent of tier and reflects baseline maturity:
/// - `accumulating` (< 14 days), `early` (14–29 days), `stable` (≥ 30 days).
enum AbiTier { accumulating, base, comprehensive }

class AbiTierDisplay {
  const AbiTierDisplay._();

  static AbiTier parse(String? raw) => switch (raw) {
        'comprehensive' => AbiTier.comprehensive,
        'base' => AbiTier.base,
        _ => AbiTier.accumulating,
      };

  // Round-11: drop "ABI" from member-facing labels.  ABI as a 0-100
  // composite z-score is opaque to a non-clinical user (CLAUDE.md
  // v4.4 already documented that the SCORE itself was retired from
  // the home card hero in v4.6).  What remains useful is the TIER —
  // i.e. how rich a signal mix the user has connected — which drives
  // the upgrade hint and lets the operator group cohorts by data
  // depth.  Strings here are tier descriptions only; "ABI" the term
  // doesn't appear anywhere user-visible.
  static String label(AbiTier tier) => switch (tier) {
        AbiTier.comprehensive => 'Comprehensive tracking',
        AbiTier.base => 'Basic tracking',
        AbiTier.accumulating => 'Setting up',
      };

  /// Short user-facing explanation surfaced on the home card.
  static String explainer(AbiTier tier, {bool earlyStage = false}) {
    final earlySuffix = earlyStage ? ' · early stage' : '';
    return switch (tier) {
      AbiTier.comprehensive =>
        'Based on advanced signals (HRV, SpO₂, etc.)$earlySuffix',
      AbiTier.base =>
        'Connect a device with HRV/SpO₂ for comprehensive tracking$earlySuffix',
      AbiTier.accumulating => 'Insights activate after 14 days of data',
    };
  }

  static Color badgeBackground(AbiTier tier) => switch (tier) {
        AbiTier.comprehensive => const Color(0xFF3182CE),
        AbiTier.base => const Color(0xFF718096),
        AbiTier.accumulating => const Color(0xFFA0AEC0),
      };

  static Color badgeForeground(AbiTier _) => const Color(0xFFFFFFFF);
}
