// TDD (Fix C): SyncTotals + foldBatchResponse accumulate per-batch server
// responses across a multi-batch sync so that `events_accepted` reflects the
// sum of every batch's accepted count — not just the LAST batch's body.
//
// The pre-fix defect: _doSyncDirect returned
//   data: { ...?lastBody, 'events_received': totalSent }
// so `events_accepted` came from only the final batch's response while
// `events_received` was the all-batch total. Any sync > 2000 events (i.e.
// more than one batch) therefore had accepted < received and _runWithTelemetry
// misclassified it as `partial`.
//
// These are pure-Dart tests against lib/services/sync_accounting.dart — no
// Flutter bindings, no http, no Keychain.

import 'package:flutter_test/flutter_test.dart';
import 'package:vitametric_app/services/sync_accounting.dart';

void main() {
  group('SyncTotals initial state', () {
    test('a zero-value start state accumulates nothing', () {
      const start = SyncTotals();
      expect(start.sent, 0);
      expect(start.accepted, 0);
      expect(start.skipped, 0);
      expect(start.skippedMetricTypes, isEmpty);
    });
  });

  group('foldBatchResponse — happy path accumulation', () {
    test('three batches with full server bodies sum sent/accepted/skipped', () {
      var totals = const SyncTotals();
      totals = foldBatchResponse(totals, 2000, {
        'events_accepted': 2000,
        'events_skipped': 0,
      });
      totals = foldBatchResponse(totals, 2000, {
        'events_accepted': 1998,
        'events_skipped': 2,
        'skipped_metric_types': ['HR_INSTANT'],
      });
      totals = foldBatchResponse(totals, 500, {
        'events_accepted': 500,
        'events_skipped': 0,
      });

      expect(totals.sent, 4500);
      expect(totals.accepted, 4498);
      expect(totals.skipped, 2);
      expect(totals.skippedMetricTypes, {'HR_INSTANT'});
    });

    test('accepted < sent iff a server body actually reported skips', () {
      // No body ever reports a skip → accepted == sent, so telemetry stays
      // `success` even across many batches.
      var clean = const SyncTotals();
      clean = foldBatchResponse(clean, 2000, {'events_accepted': 2000});
      clean = foldBatchResponse(clean, 2000, {'events_accepted': 2000});
      clean = foldBatchResponse(clean, 2000, {'events_accepted': 2000});
      expect(clean.accepted, clean.sent);
      expect(clean.accepted < clean.sent, isFalse);

      // A single body reporting a skip is what makes accepted < sent.
      var skipped = const SyncTotals();
      skipped = foldBatchResponse(skipped, 2000, {'events_accepted': 2000});
      skipped = foldBatchResponse(skipped, 2000, {'events_accepted': 1990});
      expect(skipped.accepted < skipped.sent, isTrue);
      expect(skipped.sent - skipped.accepted, 10);
    });
  });

  group('foldBatchResponse — fallbacks', () {
    test('null body assumes the whole batch was accepted', () {
      var totals = const SyncTotals();
      totals = foldBatchResponse(totals, 2000, null);
      totals = foldBatchResponse(totals, 750, null);
      expect(totals.sent, 2750);
      expect(totals.accepted, 2750);
      expect(totals.skipped, 0);
      expect(totals.skippedMetricTypes, isEmpty);
    });

    test('missing events_accepted key falls back to batch length', () {
      var totals = const SyncTotals();
      // Body present (e.g. only sync_log_id) but no accounting keys.
      totals = foldBatchResponse(totals, 2000, {'sync_log_id': 42});
      expect(totals.sent, 2000);
      expect(totals.accepted, 2000);
      expect(totals.skipped, 0);
    });

    test('missing events_skipped key defaults to zero', () {
      var totals = const SyncTotals();
      totals = foldBatchResponse(totals, 100, {'events_accepted': 100});
      expect(totals.skipped, 0);
    });

    test('mixed bodies — some full, some null, some partial keys', () {
      var totals = const SyncTotals();
      totals = foldBatchResponse(totals, 2000, {'events_accepted': 2000});
      totals = foldBatchResponse(totals, 2000, null);
      totals = foldBatchResponse(totals, 1000, {'sync_log_id': 7});
      expect(totals.sent, 5000);
      expect(totals.accepted, 5000);
      expect(totals.skipped, 0);
    });
  });

  group('foldBatchResponse — skipped_metric_types union', () {
    test('unions across batches and dedupes', () {
      var totals = const SyncTotals();
      totals = foldBatchResponse(totals, 2000, {
        'events_accepted': 1999,
        'events_skipped': 1,
        'skipped_metric_types': ['HR_INSTANT', 'STEPS'],
      });
      totals = foldBatchResponse(totals, 2000, {
        'events_accepted': 1998,
        'events_skipped': 2,
        'skipped_metric_types': ['STEPS', 'VO2_MAX'],
      });
      expect(
        totals.skippedMetricTypes,
        {'HR_INSTANT', 'STEPS', 'VO2_MAX'},
      );
    });

    test('tolerates absent skipped_metric_types', () {
      var totals = const SyncTotals();
      totals = foldBatchResponse(totals, 10, {'events_accepted': 9, 'events_skipped': 1});
      expect(totals.skippedMetricTypes, isEmpty);
    });

    test('tolerates a wrong-typed skipped_metric_types (not a list)', () {
      var totals = const SyncTotals();
      totals = foldBatchResponse(totals, 10, {
        'events_accepted': 9,
        'events_skipped': 1,
        'skipped_metric_types': 'HR_INSTANT', // server sent a String, not List
      });
      // Must not throw; unknown shape contributes nothing.
      expect(totals.skippedMetricTypes, isEmpty);
    });

    test('tolerates list entries that are not strings', () {
      var totals = const SyncTotals();
      totals = foldBatchResponse(totals, 10, {
        'events_accepted': 8,
        'events_skipped': 2,
        'skipped_metric_types': ['HR_INSTANT', 123, null],
      });
      expect(totals.skippedMetricTypes, {'HR_INSTANT'});
    });
  });
}
