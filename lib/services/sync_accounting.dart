/// Cross-batch sync accounting (Fix C).
///
/// A multi-batch sync POSTs events in 2000-event batches and gets one server
/// body per batch. Before this module the returned data map took
/// `events_accepted` from only the LAST batch's body while `events_received`
/// was the all-batch total — so any sync > 2000 events had
/// accepted < received and _runWithTelemetry misclassified it as `partial`.
///
/// [SyncTotals] folds every batch's response into running totals so that
/// `partial` fires exactly when the server actually skipped events, never
/// merely because the sync spanned multiple batches.
///
/// Pure Dart — no Flutter/http imports — so it is directly unit-testable.
library;

/// Immutable running totals across all batches of a single sync.
class SyncTotals {
  final int sent;
  final int accepted;
  final int skipped;
  final Set<String> skippedMetricTypes;

  const SyncTotals({
    this.sent = 0,
    this.accepted = 0,
    this.skipped = 0,
    this.skippedMetricTypes = const <String>{},
  });
}

/// Folds one batch's server response into [acc].
///
/// - `sent`     += [batchLen].
/// - `accepted` += `body['events_accepted']`, or [batchLen] when the body is
///   null or omits the key (a missing/absent body means "assume all accepted",
///   matching the pre-fix `?? eventsSent` fallback in _runWithTelemetry).
/// - `skipped`  += `body['events_skipped']`, or 0 when absent.
/// - `skippedMetricTypes` unions `body['skipped_metric_types']` when it is a
///   `List` of strings; any other shape (absent, wrong type, non-string
///   entries) contributes nothing and never throws.
SyncTotals foldBatchResponse(
  SyncTotals acc,
  int batchLen,
  Map<String, dynamic>? body,
) {
  final accepted = (body?['events_accepted'] as int?) ?? batchLen;
  final skipped = (body?['events_skipped'] as int?) ?? 0;

  final types = <String>{...acc.skippedMetricTypes};
  final rawTypes = body?['skipped_metric_types'];
  if (rawTypes is List) {
    for (final t in rawTypes) {
      if (t is String) types.add(t);
    }
  }

  return SyncTotals(
    sent: acc.sent + batchLen,
    accepted: acc.accepted + accepted,
    skipped: acc.skipped + skipped,
    skippedMetricTypes: types,
  );
}
