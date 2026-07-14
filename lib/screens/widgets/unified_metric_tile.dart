// Round-18: a single tile per metric showing both
//   * the latest HealthKit value (with sample age)  AND
//   * the comparison to the member's 90-day personal baseline
//     (delta% + status pill: Normal / Above usual / Below usual)
//
// Replaces two screens worth of duplicate per-metric tiles that
// pre-round-18 lived side-by-side on Today: ``_HealthTodayGrid``
// (HK current values) and ``SignalsPanel`` (baseline comparison).
// Operators reported the duplication felt cluttered; merging into
// one tile per metric collapses the cognitive load to "here's the
// number, here's how it compares" without scrolling between two
// sections.
//
// Contract:
//   * ``currentValue == null`` AND ``baselineMedian == null`` →
//     renders a "No data" subtle row (caller decides whether to
//     skip the tile entirely).
//   * ``currentValue != null && baselineMedian == null`` → shows
//     the value with "No baseline yet" line below.
//   * Both present → full value + delta + status pill.

import 'package:flutter/material.dart';

import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../utils/metric_display.dart';
import '../../utils/time_utils.dart';

class UnifiedMetricTile extends StatelessWidget {
  /// Canonical metric type (e.g. 'HR_INSTANT', 'STEPS_DELTA').  Drives
  /// label, unit, and number formatting via MetricDisplay.
  final String metricType;

  /// Human-readable display name shown in the tile header.  When null,
  /// falls back to ``MetricDisplay.meta(metricType).label``.  Override
  /// when the canonical label is too jargony for the tile context
  /// (e.g. "Heart Rate" instead of "HR (instant)").
  final String? labelOverride;

  /// Latest reading value.  May come from HK directly (preferred for
  /// freshness) or from ``DailyReport.metrics[..].mean`` (fallback when
  /// HK didn't surface this metric on this device).
  final double? currentValue;

  /// When the latest reading was taken, drives the "2h ago" label.
  /// Null hides the age line.
  final DateTime? sampleAt;

  /// Member's personal 90-day baseline median for this metric+state,
  /// from ``HealthService.fetchBaselines``.  Null → no comparison
  /// shown.
  final double? baselineMedian;

  /// Tile icon. ``MetricMeta`` doesn't carry an icon field, so callers
  /// pass one explicitly; null falls back to a generic line-chart glyph.
  final IconData? iconOverride;

  /// Optional per-tile color tint for the icon.  Defaults to kNavy.
  final Color iconColor;

  const UnifiedMetricTile({
    super.key,
    required this.metricType,
    this.labelOverride,
    this.currentValue,
    this.sampleAt,
    this.baselineMedian,
    this.iconOverride,
    this.iconColor = kNavy,
  });

  // Status threshold — within ±10% of personal usual reads as "Normal".
  // Same value the deleted SignalsPanel used; loosely matches the
  // proportional MAD floors used in anomaly detection (HR 15%, HRV 8%,
  // RHR 10%) — close enough for member-facing context.
  static const double _normalThresholdPct = 10.0;

  @override
  Widget build(BuildContext context) {
    final meta = MetricDisplay.meta(metricType);
    final label = labelOverride ?? meta.label;
    final icon = iconOverride ?? Icons.show_chart;

    final valueText = currentValue != null
        ? MetricDisplay.formatWithUnit(metricType, currentValue!)
        : '—';
    final ageText = sampleAt != null ? relativeTime(sampleAt!) : null;

    final baselineText = baselineMedian != null
        ? 'Your usual: ${MetricDisplay.formatWithUnit(metricType, baselineMedian!)}'
        : 'No baseline yet';

    final (deltaText, statusText, statusBg, statusFg) =
        _resolveStatus(currentValue, baselineMedian);

    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top row: icon + name + current value
          Row(
            children: [
              Icon(icon, size: 18, color: iconColor),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(label, style: AppText.tileTitle),
              ),
              Text(valueText, style: AppText.tileValue),
            ],
          ),

          // Sample age (right-aligned beneath the value).
          if (ageText != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Padding(
              padding: const EdgeInsets.only(left: 26),  // align under label
              child: Row(
                children: [
                  const Expanded(child: SizedBox.shrink()),
                  Text(ageText,
                      style: AppText.caption.copyWith(
                          color: Colors.grey.shade500)),
                ],
              ),
            ),
          ],

          // Baseline comparison row.
          const SizedBox(height: AppSpacing.sm),
          Padding(
            padding: const EdgeInsets.only(left: 26),
            child: Row(
              children: [
                Expanded(
                  child: Text(baselineText,
                      style: AppText.caption.copyWith(
                          color: Colors.grey.shade600)),
                ),
                if (deltaText.isNotEmpty) ...[
                  Text(deltaText,
                      style: AppText.caption.copyWith(
                          color: statusFg, fontWeight: FontWeight.w600)),
                  const SizedBox(width: AppSpacing.sm),
                ],
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: statusBg,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(statusText,
                      style: AppText.label.copyWith(
                          color: statusFg, fontSize: 11)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Returns (deltaText, statusText, statusBg, statusFg).
  ///
  /// Uses the same band scheme as the deleted SignalsPanel: ±10% =
  /// Normal, > +10% = Above usual (warm amber), < -10% = Below usual
  /// (cool blue), missing = neutral grey.
  (String, String, Color, Color) _resolveStatus(
    double? todayVal,
    double? baselineMedian,
  ) {
    if (todayVal == null) {
      return ('', 'No data today', const Color(0xFFF1F5F9),
          const Color(0xFF94A3B8));
    }
    if (baselineMedian == null || baselineMedian == 0) {
      return ('', 'New', const Color(0xFFE0F2FE), const Color(0xFF075985));
    }
    final deltaPct = ((todayVal - baselineMedian) / baselineMedian.abs()) * 100;
    final deltaTxt = '${deltaPct >= 0 ? '+' : ''}${deltaPct.toStringAsFixed(1)}%';
    if (deltaPct.abs() < _normalThresholdPct) {
      return (deltaTxt, 'Normal', const Color(0xFFDCFCE7),
          const Color(0xFF166534));
    }
    if (deltaPct > 0) {
      return (deltaTxt, 'Above usual', const Color(0xFFFEF3C7),
          const Color(0xFF854D0E));
    }
    return (deltaTxt, 'Below usual', const Color(0xFFDBEAFE),
        const Color(0xFF1E40AF));
  }
}
