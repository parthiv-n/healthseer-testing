// Round-19 prevention tests for copy strings that have historically
// drifted from the constants that drive them.
//
// Both bugs in this file came from one root cause: a magic number /
// magic phrase in the UI sat far away from the constant / function
// it was supposed to mirror, and a future edit changed one without
// the other. Source-text assertions (cheap, no widget tree) catch the
// drift on the next CI run instead of on the next member's screen.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('upgrade hint preserves ANY ONE semantics', () {
    final src = File('lib/screens/home_screen.dart').readAsStringSync();
    expect(
      src.contains('_baseUpgradeContent'),
      isTrue,
      reason: '_baseUpgradeContent renamed or removed — update this test '
          'to track the new symbol and re-assert the ANY-ONE phrasing.',
    );
    // Slice the body of _baseUpgradeContent so the ANY ONE assertion
    // can't drift into a different function (e.g. the comprehensive
    // detail copy) and still pass.
    final defStart = src.indexOf('_baseUpgradeContent()');
    expect(defStart, greaterThan(-1));
    // The function spans from its `(` definition to the closing `}` of
    // its body. _baseUpgradeContent returns a record so it ends with
    // `);\n  }`. Grab a generous window so we capture the whole body.
    final body = src.substring(defStart, defStart + 4000);
    expect(
      body.contains('ANY ONE'),
      isTrue,
      reason: 'The upgrade hint MUST state "ANY ONE" explicitly. '
          'Without this qualifier the metric list reads as a checklist '
          '("you need ALL of these"), which is the round-19 bug Cath '
          'reproduced. If you\'re editing the copy, keep the disjunctive '
          'wording or update this test with the new equivalent phrase.',
    );
  });

  // Round-19 (re-audit): "Re-sync uploads the last 365 days …" copy
  // had drifted past the `_historicalSyncDays = 180` constant in
  // health_service.dart in three separate screens (profile, trends,
  // home). Pin every copy path that mentions a re-sync window to
  // interpolate ``HealthService.kHistoricalSyncDays`` rather than a
  // literal number — otherwise a future window change (180 → 365 → x)
  // re-introduces the same drift Cath flagged.
  test('historical re-sync copy interpolates kHistoricalSyncDays, never a literal',
      () {
    // Every screen that surfaces a re-sync confirmation dialog or
    // hint. If you add a new copy path, append it here.
    final files = const [
      'lib/screens/profile_screen.dart',
      'lib/screens/home_screen.dart',
      'lib/screens/trends_screen.dart',
    ];
    final offenders = <String>[];
    // Match "X days" / "X-day" where X is a 2-3 digit number, BUT
    // exclude:
    //   * the constant declaration in health_service (not in this list)
    //   * the date-range *picker* cap on Trends (the ">365" guard
    //     in trends_screen.dart line ~222 is a viewing window cap, not
    //     a re-sync upload cap — different semantic).
    final dayPattern = RegExp(r"\b(\d{2,3})[ -]days?\b");
    for (final path in files) {
      final src = File(path).readAsStringSync();
      for (final match in dayPattern.allMatches(src)) {
        // Read 80 chars of context around the match to filter out
        // unrelated literals (date pickers, tooltips, etc.).
        final start = (match.start - 80).clamp(0, src.length);
        final end = (match.end + 80).clamp(0, src.length);
        final ctx = src.substring(start, end);
        // Only flag the re-sync copy paths we care about. Both the
        // member-facing dialog text and the gap-banner caption use
        // some form of "re-sync" / "re-upload" / "uploads the last".
        final isResyncCopy = ctx.contains('Re-sync') ||
            ctx.contains('re-sync') ||
            ctx.contains('re-upload') ||
            ctx.contains('Re-upload') ||
            ctx.contains('uploads the last');
        if (!isResyncCopy) continue;
        offenders.add('$path: "${match.group(0)}" near "${ctx.trim()}"');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'Re-sync copy should interpolate '
          'HealthService.kHistoricalSyncDays instead of hard-coding the '
          'window. Offending matches:\n  ${offenders.join("\n  ")}',
    );
  });
}
