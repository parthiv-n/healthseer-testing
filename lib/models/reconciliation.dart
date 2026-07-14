/// Typed parse of the backend reconciliation endpoint
/// (`GET /api/v1/data/reconciliation?days=N`).
///
/// The reconciliation report answers "of everything this member's device
/// uploaded in the last N days, how much did the pipeline actually accept,
/// dedupe, or reject — and per canonical metric?". Pairing it with an
/// on-device [CensusReport] (see lib/services/census_compare.dart) lets a
/// diagnostics screen pinpoint whether a missing metric was never read from
/// HealthKit, dropped in-Flutter before upload, or rejected server-side.
///
/// Pure Dart — no Flutter / package:health dependency, so it stays cheaply
/// testable (see test/reconciliation_model_test.dart). Every parser is
/// tolerant of missing / null fields: numbers default to 0, maps to empty,
/// strings to '' so a partial backend response never throws.
library;

/// Per-metric reconciliation counts for one canonical `metric_type`.
class ReconciliationMetric {
  /// Raw events uploaded from the device for this metric in the window
  /// (counted over the `raw_window`, e.g. `created_at`).
  final int rawUploaded;

  /// Total canonical events the pipeline materialised for this metric,
  /// across every `normalization_status`.
  final int canonicalTotal;

  /// Breakdown of [canonicalTotal] by `normalization_status`. Keys mirror the
  /// backend enum (`valid`, `valid_low_quality`, `valid_dedup_survivor`,
  /// `invalid_physiological`, `invalid_duplicate`, `invalid_context_conflict`).
  /// Missing keys simply do not appear — read defensively.
  final Map<String, int> byStatus;

  /// Canonical events that count as usable for scoring (valid family).
  final int usable;

  /// Timestamp of the most recent event for this metric, or null when the
  /// metric produced no events in the window.
  final DateTime? latestEventTime;

  const ReconciliationMetric({
    required this.rawUploaded,
    required this.canonicalTotal,
    required this.byStatus,
    required this.usable,
    this.latestEventTime,
  });

  factory ReconciliationMetric.fromJson(Map<String, dynamic> j) {
    final rawStatus = j['by_status'];
    final byStatus = <String, int>{};
    if (rawStatus is Map) {
      rawStatus.forEach((k, v) {
        byStatus['$k'] = (v as num?)?.toInt() ?? 0;
      });
    }
    final rawLatest = j['latest_event_time'];
    return ReconciliationMetric(
      rawUploaded: (j['raw_uploaded'] as num?)?.toInt() ?? 0,
      canonicalTotal: (j['canonical_total'] as num?)?.toInt() ?? 0,
      byStatus: byStatus,
      usable: (j['usable'] as num?)?.toInt() ?? 0,
      latestEventTime: rawLatest is String && rawLatest.isNotEmpty
          ? DateTime.tryParse(rawLatest)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'raw_uploaded': rawUploaded,
        'canonical_total': canonicalTotal,
        'by_status': byStatus,
        'usable': usable,
        'latest_event_time': latestEventTime?.toIso8601String(),
      };
}

/// The full reconciliation response for one member over a rolling window.
class ReconciliationResponse {
  final String userId;
  final int windowDays;

  /// When the backend generated this snapshot.
  final DateTime? generatedAt;

  /// Which raw timestamp column the window was measured against
  /// (e.g. `created_at`).
  final String rawWindow;

  /// The sync-log id this report was scoped to, or null for an all-history
  /// reconciliation.
  final int? syncLogId;

  /// Canonical `metric_type` → its per-metric counts.
  final Map<String, ReconciliationMetric> metrics;

  const ReconciliationResponse({
    required this.userId,
    required this.windowDays,
    this.generatedAt,
    required this.rawWindow,
    this.syncLogId,
    required this.metrics,
  });

  factory ReconciliationResponse.fromJson(Map<String, dynamic> j) {
    final rawMetrics = j['metrics'];
    final metrics = <String, ReconciliationMetric>{};
    if (rawMetrics is Map) {
      rawMetrics.forEach((k, v) {
        if (v is Map) {
          metrics['$k'] =
              ReconciliationMetric.fromJson(Map<String, dynamic>.from(v));
        }
      });
    }
    final rawGenerated = j['generated_at'];
    return ReconciliationResponse(
      userId: j['user_id'] as String? ?? '',
      windowDays: (j['window_days'] as num?)?.toInt() ?? 0,
      generatedAt: rawGenerated is String && rawGenerated.isNotEmpty
          ? DateTime.tryParse(rawGenerated)
          : null,
      rawWindow: j['raw_window'] as String? ?? '',
      syncLogId: (j['sync_log_id'] as num?)?.toInt(),
      metrics: metrics,
    );
  }

  Map<String, dynamic> toJson() => {
        'user_id': userId,
        'window_days': windowDays,
        'generated_at': generatedAt?.toIso8601String(),
        'raw_window': rawWindow,
        'sync_log_id': syncLogId,
        'metrics': metrics.map((k, v) => MapEntry(k, v.toJson())),
      };
}
