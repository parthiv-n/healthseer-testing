// Regression tests for three self-contained sync fixes.
//
// Two of these are source-text assertions rather than behavioural tests.
// That matches the precedent set by `upgrade_hint_phrasing_test.dart`: the
// bugs are "a constant / guard sits far away from the code that must mirror
// it", and the upload legs they live in need a mocked http client + Keychain
// to exercise directly. A cheap source assertion catches the drift on the
// next CI run instead of on the next member's device.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vitametric_app/services/health_service.dart';

/// Slice the body of a named method so an assertion cannot drift into a
/// neighbouring function and still pass.
///
/// [signature] must be the full declaration, not the bare name — the bare
/// name matches the *call site* first, which slices the wrong region.
String _methodBody(String src, String signature) {
  final start = src.indexOf(signature);
  expect(
    start,
    greaterThan(-1),
    reason: '"$signature" not found — it was renamed or its declaration was '
        'reformatted. Update this test to track the new symbol and re-assert '
        'the guard.',
  );
  // Bound at the next top-level member so the slice cannot leak into a
  // sibling method that happens to contain the same status-code checks.
  final next = src.indexOf('\n  static ', start + signature.length);
  final end = next == -1 ? src.length : next;
  return src.substring(start, end);
}

void main() {
  // ── I8: HealthKit source names contain U+00A0 ────────────────────────────
  //
  // The real sourceName is "Poi Ki’s Apple Watch". The keyword brand map
  // is keyed on 'apple watch' with an ordinary space, so a raw
  // `.toLowerCase().contains('apple watch')` was always false and the Apple
  // Watch never resolved through the keyword fallback.
  group('normalizeSourceName (I8)', () {
    const realWatch = 'Poi Ki’s Apple Watch';

    test('folds the non-breaking space so the keyword map matches', () {
      final normalized = HealthService.normalizeSourceName(realWatch);
      expect(normalized.contains('apple watch'), isTrue,
          reason: 'U+00A0 must fold to an ASCII space before keyword matching');
    });

    test('raw lowercase does NOT match — proving the bug this guards', () {
      expect(realWatch.toLowerCase().contains('apple watch'), isFalse);
    });

    test('lowercases, collapses whitespace runs, and trims', () {
      expect(
        HealthService.normalizeSourceName('  Pokky’s   IPHONE\t\n '),
        'pokky’s iphone',
      );
    });

    test('leaves an ordinary source name untouched', () {
      expect(HealthService.normalizeSourceName('Connect'), 'connect');
    });
  });

  // ── N2: the first-sync window must not be a literal ──────────────────────
  //
  // Round-19 centralised the *historical* re-sync path on _historicalSyncDays
  // but left two `const Duration(days: 180)` literals in the first-sync /
  // malformed-anchor branches. Change the constant and the two baselines
  // silently diverge again — the exact 365-vs-180 drift class round-19 set
  // out to kill.
  group('first-sync window uses the constant (N2)', () {
    late String src;

    setUp(() {
      src = File('lib/services/health_service.dart').readAsStringSync();
    });

    test('no literal Duration(days: 180) anywhere', () {
      // Scoped to 180 specifically: other day-literals in this file are
      // unrelated windows (a 7-day brand probe, a 90-day VO2 lookback,
      // the 2-day anchor fallback) and must NOT be pinned to this constant.
      final offenders = RegExp(r'Duration\(days:\s*180\)')
          .allMatches(src)
          .map((m) => m.group(0)!)
          .toList();
      expect(
        offenders,
        isEmpty,
        reason: 'The first-sync baseline window must interpolate '
            '_historicalSyncDays, not hard-code 180. Change the constant and '
            'a literal here silently diverges — the 365-vs-180 drift class. '
            'Offenders: ${offenders.join(", ")}',
      );
    });

    test('the constant is still the single source of truth', () {
      expect(src.contains('static const _historicalSyncDays = 180'), isTrue);
      expect(src.contains('kHistoricalSyncDays => _historicalSyncDays'), isTrue);
    });
  });

  // ── N1: a 401 mid-backfill must fire sessionExpired ──────────────────────
  //
  // The incremental upload leg handles 401 explicitly. The chunked historical
  // leg did not: a 401 fell through to the generic non-2xx branch, returned
  // SyncErrorType.serverError, and never set sessionExpired — so no screen
  // routed to login and the re-sync retried forever against a dead token.
  group('backfill handles 401 (N1)', () {
    late String body;

    setUp(() {
      final src = File('lib/services/health_service.dart').readAsStringSync();
      body = _methodBody(
        src,
        'static Future<SyncResult> _runChunkedHistoricalSync({',
      );
    });

    test('checks for 401 before the generic non-2xx failure branch', () {
      final auth = body.indexOf('statusCode == 401');
      final generic = body.indexOf('statusCode != 200');
      expect(auth, greaterThan(-1),
          reason: 'the backfill upload leg must special-case 401');
      expect(
        auth,
        lessThan(generic),
        reason: 'the 401 check must precede the generic non-2xx branch, '
            'otherwise a 401 is reported as serverError',
      );
    });

    test('fires sessionExpired and returns authExpired', () {
      expect(body.contains('sessionExpired.value = true'), isTrue);
      expect(body.contains('SyncErrorType.authExpired'), isTrue);
    });
  });

  // ── Phase 1.2: health_mapping.dart delegation ────────────────────────────
  //
  // _healthTypeToLp / _unitForType / _isSleepType / _platformSyncTypes were
  // extracted into lib/services/health_mapping.dart as pure, directly
  // testable functions (see test/health_mapping_test.dart). This guards
  // against someone re-inlining the mapping table and silently losing that
  // test coverage.
  group('health_mapping.dart delegation', () {
    late String src;

    setUp(() {
      src = File('lib/services/health_service.dart').readAsStringSync();
    });

    test('imports health_mapping.dart', () {
      expect(
        src.contains("'health_mapping.dart'"),
        isTrue,
        reason: 'health_service.dart must import the extracted mapping '
            'module rather than re-inlining the mapping logic',
      );
    });

    test('_healthTypeToLp delegates instead of re-implementing the map', () {
      final body = _methodBody(src, 'static String? _healthTypeToLp(');
      expect(
        body.contains('healthTypeToLp('),
        isTrue,
        reason: '_healthTypeToLp must delegate to health_mapping.dart, not '
            'keep its own copy of the mapping table',
      );
    });
  });

  // ── Phase 2.3: census engine chunking + plugin dedup ─────────────────────
  //
  // runCensus walks the window in fixed 30-day slices and runs the plugin's
  // own removeDuplicates on each chunk before counting — mirroring the sync
  // path so the "uploadable" tally matches what a real sync would send. Both
  // are plugin-bound (can't be unit-tested without a live Health() engine),
  // so a source assertion guards against the chunk width silently changing or
  // the dedup pass being dropped.
  group('census engine chunking (Phase 2.3)', () {
    late String src;

    setUp(() {
      src = File('lib/services/health_census.dart').readAsStringSync();
    });

    test('declares a 30-day chunk constant', () {
      expect(
        src.contains('censusChunkDays = 30'),
        isTrue,
        reason: 'the census must walk the window in 30-day chunks to bound '
            'peak memory; the width is a named constant, not a literal',
      );
    });

    test('runs the plugin dedup on each chunk before counting', () {
      expect(
        src.contains('Health().removeDuplicates('),
        isTrue,
        reason: 'the census must dedup each chunk the same way the sync path '
            'does, or the uploadable tally overcounts',
      );
    });
  });

  // ── Fix C: events_accepted must be the cross-batch total ─────────────────
  //
  // Pre-fix, the return map took events_accepted from `...?lastBody` — the
  // LAST batch's server body — while events_received was the all-batch total.
  // Any sync > 2000 events (multiple batches) therefore had accepted <
  // received and _runWithTelemetry misclassified it as `partial`. The fix
  // folds every batch through foldBatchResponse into a SyncTotals and sources
  // events_accepted from totals.accepted, so `partial` fires only when the
  // server actually skipped events. Both upload legs are http+Keychain-bound,
  // so a source assertion guards the accounting wiring.
  group('cross-batch accounting (Fix C)', () {
    late String src;

    setUp(() {
      src = File('lib/services/health_service.dart').readAsStringSync();
    });

    test('folds each batch response through foldBatchResponse', () {
      expect(
        src.contains('foldBatchResponse('),
        isTrue,
        reason: 'each batch response must be folded into running totals so '
            'events_accepted sums across all batches, not just the last body',
      );
    });

    test('events_accepted is sourced from the folded totals', () {
      // The literal key must appear paired with totals.accepted — proving the
      // return map no longer takes events_accepted solely from the lastBody
      // spread.
      expect(
        src.contains("'events_accepted': totals.accepted"),
        isTrue,
        reason: 'events_accepted must come from the cross-batch SyncTotals, '
            'not from the last batch body spread (...?lastBody)',
      );
    });
  });

  // ── Phase 4: the Profile version label must not be a hard-coded literal ───
  //
  // The version footer was `Vitametric v1.0.0 (7)` — a literal that silently
  // lied after every version bump. Phase 4 derives it from BuildMetadata
  // (CFBundle values). A source assertion catches a re-inlined literal on the
  // next CI run instead of on a tester's device showing the wrong build.
  group('Profile version label is BuildMetadata-derived (Phase 4)', () {
    late String src;

    setUp(() {
      src = File('lib/screens/profile_screen.dart').readAsStringSync();
    });

    test('no hard-coded "v1.0.0 (7)" literal remains', () {
      expect(
        src.contains('v1.0.0 (7)'),
        isFalse,
        reason: 'the version footer must interpolate BuildMetadata.version / '
            '.build, not hard-code a literal that drifts from the real build',
      );
    });

    test('interpolates BuildMetadata for the version string', () {
      expect(
        src.contains('BuildMetadata.version') &&
            src.contains('BuildMetadata.build'),
        isTrue,
        reason: 'the footer must read the runtime CFBundle values',
      );
    });
  });
}
