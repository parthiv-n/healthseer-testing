/// Pure comparison logic: reconcile an on-device [CensusReport] (what the app
/// read from HealthKit / Health Connect and *would* upload) against the
/// backend [ReconciliationResponse] (what the server actually accepted).
///
/// The output is one [CompareRow] per canonical `metric_type` seen on either
/// side, each classified [ok] / [warn] / [fail] so a diagnostics screen can
/// surface exactly where a metric's counts diverge — a metric the app uploads
/// but the server never received (missing on server), or one the server holds
/// that never came through live sync (server-only, e.g. an Apple Health XML
/// import).
///
/// Pure Dart — no Flutter / IO dependency, so it is directly unit-testable
/// (see test/census_compare_test.dart).
library;

import '../models/census_report.dart';
import '../models/reconciliation.dart';

/// Severity of the divergence between the on-device census and the server.
enum CompareStatus { ok, warn, fail }

/// Metrics whose live-sync path uses a longer server-side lookback than the
/// census/reconciliation window, so a raw count delta is expected and benign.
/// (VO2_MAX and SLEEP_APNEA_EVENT ride the native bridges with a 90-day
/// lookback — see health_service.dart.)
const Set<String> _lookback90Metrics = {
  'VO2_MAX',
  'SLEEP_APNEA_EVENT',
};

/// One reconciled row: a single canonical metric compared across the device
/// census and the server reconciliation report.
class CompareRow {
  final String metric;

  /// Uploadable count aggregated from the census (sum over census rows that
  /// map to this metric).
  final int hkUploadable;

  /// Raw events the server recorded as uploaded for this metric.
  final int serverRawUploaded;

  /// Server events usable for scoring.
  final int serverUsable;

  /// `serverRawUploaded - hkUploadable`. Positive => server holds more than
  /// the device would upload (extra history / XML import); negative => the
  /// device would upload more than the server received.
  final int delta;

  /// `delta / hkUploadable * 100`, or null when [hkUploadable] is 0
  /// (division undefined — a server-only metric).
  final double? deltaPct;

  final CompareStatus status;

  /// Human-readable explanation of the status, or '' when counts match.
  final String note;

  const CompareRow({
    required this.metric,
    required this.hkUploadable,
    required this.serverRawUploaded,
    required this.serverUsable,
    required this.delta,
    required this.deltaPct,
    required this.status,
    required this.note,
  });
}

/// Compare a device [census] against a server [server] reconciliation report.
///
/// Census uploadable counts are aggregated by their `mappedMetric`
/// (null-mapped rows are skipped — they never reach the backend). The result
/// covers the union of metric keys present on either side.
///
/// Status rules:
///   * present on only one side  -> [CompareStatus.fail]
///       - device-only  -> note 'missing on server'
///       - server-only  -> note 'server-only (e.g. XML import)'
///   * `delta == 0`               -> [CompareStatus.ok]
///   * `|deltaPct| < 2.0`         -> [CompareStatus.warn]
///   * `|deltaPct| >= 2.0`        -> [CompareStatus.fail]
///   * `hkUploadable == 0 && serverRawUploaded == 0` -> [CompareStatus.ok]
///
/// [_lookback90Metrics] rows additionally get 'sync lookback 90d' appended to
/// their note (the raw delta is expected for those bridge-sourced metrics).
List<CompareRow> compareCensusToServer(
  CensusReport census,
  ReconciliationResponse server,
) {
  // Aggregate census uploadable by mapped metric, skipping null-mapped rows.
  final hkByMetric = <String, int>{};
  for (final row in census.rows) {
    final metric = row.mappedMetric;
    if (metric == null) continue;
    hkByMetric[metric] = (hkByMetric[metric] ?? 0) + row.uploadable;
  }

  final metricKeys = <String>{...hkByMetric.keys, ...server.metrics.keys};
  // Stable, deterministic ordering for display / TSV.
  final sortedKeys = metricKeys.toList()..sort();

  final rows = <CompareRow>[];
  for (final metric in sortedKeys) {
    final hasHk = hkByMetric.containsKey(metric);
    final hasServer = server.metrics.containsKey(metric);
    final hkUploadable = hkByMetric[metric] ?? 0;
    final serverMetric = server.metrics[metric];
    final serverRawUploaded = serverMetric?.rawUploaded ?? 0;
    final serverUsable = serverMetric?.usable ?? 0;

    final delta = serverRawUploaded - hkUploadable;
    final double? deltaPct =
        hkUploadable == 0 ? null : delta / hkUploadable * 100.0;

    CompareStatus status;
    String note;

    if (hasHk && !hasServer) {
      status = CompareStatus.fail;
      note = 'missing on server';
    } else if (!hasHk && hasServer) {
      status = CompareStatus.fail;
      note = 'server-only (e.g. XML import)';
    } else if (delta == 0) {
      // Covers the 0-vs-0 case as well.
      status = CompareStatus.ok;
      note = '';
    } else if (deltaPct != null && deltaPct.abs() < 2.0) {
      status = CompareStatus.warn;
      note = 'minor drift';
    } else {
      status = CompareStatus.fail;
      note = 'count mismatch';
    }

    if (_lookback90Metrics.contains(metric)) {
      note = note.isEmpty ? 'sync lookback 90d' : '$note; sync lookback 90d';
    }

    rows.add(CompareRow(
      metric: metric,
      hkUploadable: hkUploadable,
      serverRawUploaded: serverRawUploaded,
      serverUsable: serverUsable,
      delta: delta,
      deltaPct: deltaPct,
      status: status,
      note: note,
    ));
  }

  return rows;
}

/// Tab-separated comparison table that pastes cleanly into a spreadsheet.
/// Header order is pinned — do not reorder without checking downstream
/// templates.
String compareTsv(List<CompareRow> rows) {
  final buffer = StringBuffer()
    ..writeln('Metric\tHK Uploadable\tServer Accepted\tServer Usable\t'
        'Delta\tDelta %\tStatus\tNote');
  for (final r in rows) {
    buffer.writeln([
      r.metric,
      r.hkUploadable.toString(),
      r.serverRawUploaded.toString(),
      r.serverUsable.toString(),
      r.delta.toString(),
      r.deltaPct == null ? '' : r.deltaPct!.toStringAsFixed(1),
      r.status.name,
      r.note,
    ].join('\t'));
  }
  return buffer.toString();
}
