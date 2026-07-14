import 'package:flutter/material.dart';

import 'colors.dart';

/// App-wide typography scale — single source of truth.
///
/// Round-18: replaces ~150 hard-coded ``fontSize: N`` literals scattered
/// across home_screen / trends_screen / signals_panel / metric_tile /
/// alerts_screen / profile_screen.  The pre-round-18 UI used 9-22pt
/// fontSize values picked ad-hoc per surface, leaving member-facing
/// copy at or below Apple HIG's 12pt minimum on small captions and
/// inconsistent across tabs (HRV label was 14 in one place, 13 in
/// another).  Round-17 phase 2 patched it via a global +10% MediaQuery
/// scaler — that lifted everything but didn't fix the fragmentation.
///
/// Use these named styles directly:
///
///   Text('76 bpm', style: AppText.bodyBold),
///   Text('Your usual', style: AppText.caption.copyWith(color: kAmber)),
///
/// Sizes follow Apple HIG body=17 / footnote=13 / caption=12 with our
/// app's slightly tighter scale (15/12 instead of 17/13) because the
/// member-facing tiles pack 2-3 lines of metric info in a compact row.
class AppText {
  AppText._();

  // ── Captions / labels ─────────────────────────────────────────────────
  /// Smallest readable text — chart axis labels, sample-age labels.
  /// 12pt at +10% device scale ≈ 13.2pt rendered, comfortably above the
  /// 11pt floor Apple flags as "may be unreadable."
  static const TextStyle caption = TextStyle(
    fontSize: 12,
    height: 1.3,
    color: kTextSecondary,
  );

  /// Tier badges, status pills, secondary metadata.
  static const TextStyle label = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    color: kTextSecondary,
  );

  /// Body text — explanations, paragraph copy, secondary tile text.
  static const TextStyle body = TextStyle(
    fontSize: 14,
    height: 1.4,
    color: kTextPrimary,
  );

  /// Body emphasized — primary metric value, risk score number.
  static const TextStyle bodyBold = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w700,
    color: kTextPrimary,
  );

  /// Tile title / metric name (e.g. "Heart Rate", "Sleep").
  static const TextStyle tileTitle = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    color: kTextPrimary,
  );

  /// Tile primary value (e.g. "76 bpm", "7h 45m").
  static const TextStyle tileValue = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w700,
    color: kTextPrimary,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Section header inside a screen (e.g. "Today", "Insights").
  static const TextStyle sectionHeader = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w700,
    color: kTextPrimary,
    letterSpacing: -0.2,
  );

  /// Card / panel title (e.g. "Today's Signals", "Risk Insights").
  static const TextStyle cardTitle = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w700,
    color: kTextPrimary,
  );

  /// Screen-level title shown in app-bar style headers.
  static const TextStyle screenTitle = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    color: kTextPrimary,
    letterSpacing: -0.3,
  );

  /// Hero number — one-glance value, used sparingly.
  static const TextStyle hero = TextStyle(
    fontSize: 26,
    fontWeight: FontWeight.w800,
    color: kTextPrimary,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

/// Spacing scale.  Use these instead of ad-hoc ``SizedBox(height: 13)`` —
/// any deviation from the 4 / 8 / 12 / 16 / 20 / 24 grid is a smell.
class AppSpacing {
  AppSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
}
