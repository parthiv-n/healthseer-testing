/// Data models for a Census Report — a diagnostic snapshot comparing what
/// HealthKit / Health Connect reports for a given window against what the
/// app maps, dedupes, and actually uploads. Intended for an in-app
/// diagnostics screen (later phase) that answers "why didn't metric X show
/// up on the portal?" without needing device console access.
///
/// Pure Dart — no Flutter or package:health dependency, so it stays cheaply
/// testable (see test/census_report_test.dart).
library;

/// One row of the census: a single HealthKit/Health Connect type observed
/// during the window, and what happened to it on the way to the backend.
class CensusMetricRow {
  /// The raw HealthDataType name as returned by the `health` plugin (e.g.
  /// "SLEEP_ASLEEP"). Stored as a String, not the enum, so this model has no
  /// dependency on package:health.
  final String hkType;

  /// The backend canonical metric_type this hkType maps to, or null if
  /// there is no mapping (see lib/services/health_mapping.dart's
  /// healthTypeToLp).
  final String? mappedMetric;

  /// Count of raw HealthDataPoint samples returned by the platform query.
  final int rawCount;

  /// Count remaining after the `health` plugin's own built-in dedup.
  final int afterPluginDedup;

  /// Count actually included in the upload payload after all app-side
  /// filtering (awake-filter, in-bed envelope drop, overlap dedup, etc.).
  final int uploadable;

  /// Why samples of this type were dropped before upload, if applicable.
  /// Mirrors lib/services/health_mapping.dart's UploadDropReason.name, or
  /// null when nothing of this type was dropped.
  final String? dropReason;

  /// Earliest / latest sample timestamp observed in the window, if any.
  final DateTime? earliest;
  final DateTime? latest;

  const CensusMetricRow({
    required this.hkType,
    this.mappedMetric,
    required this.rawCount,
    required this.afterPluginDedup,
    required this.uploadable,
    this.dropReason,
    this.earliest,
    this.latest,
  });

  Map<String, dynamic> toJson() => {
        'hk_type': hkType,
        'mapped_metric': mappedMetric,
        'raw_count': rawCount,
        'after_plugin_dedup': afterPluginDedup,
        'uploadable': uploadable,
        'drop_reason': dropReason,
        'earliest': earliest?.toIso8601String(),
        'latest': latest?.toIso8601String(),
      };

  factory CensusMetricRow.fromJson(Map<String, dynamic> j) => CensusMetricRow(
        hkType: j['hk_type'] as String? ?? '',
        mappedMetric: j['mapped_metric'] as String?,
        rawCount: (j['raw_count'] as num?)?.toInt() ?? 0,
        afterPluginDedup: (j['after_plugin_dedup'] as num?)?.toInt() ?? 0,
        uploadable: (j['uploadable'] as num?)?.toInt() ?? 0,
        dropReason: j['drop_reason'] as String?,
        earliest: j['earliest'] != null
            ? DateTime.parse(j['earliest'] as String)
            : null,
        latest:
            j['latest'] != null ? DateTime.parse(j['latest'] as String) : null,
      );
}

/// A full census over a time window: one row per HealthKit/Health Connect
/// type observed, plus the window bounds so reports from different runs can
/// be compared.
class CensusReport {
  final DateTime windowStart;
  final DateTime windowEnd;
  final List<CensusMetricRow> rows;

  const CensusReport({
    required this.windowStart,
    required this.windowEnd,
    required this.rows,
  });

  /// Pinned TSV column order — do not reorder without checking downstream
  /// spreadsheet templates.
  static const List<String> tsvHeaderColumns = [
    'Metric',
    'Apple Raw Count',
    'After Dedup',
    'Uploadable',
    'Mapped Type',
    'Drop Reason',
  ];

  /// Human-readable report, e.g. for pasting into a support ticket.
  String toDisplayText() {
    final buffer = StringBuffer()
      ..writeln('Census Report')
      ..writeln(
          'Window: ${windowStart.toIso8601String()} — ${windowEnd.toIso8601String()}')
      ..writeln('Types observed: ${rows.length}')
      ..writeln('');
    for (final r in rows) {
      buffer
        ..writeln(r.hkType)
        ..writeln('  mapped: ${r.mappedMetric ?? "(none)"}')
        ..writeln(
            '  raw: ${r.rawCount}  after dedup: ${r.afterPluginDedup}  uploadable: ${r.uploadable}')
        ..writeln('  drop reason: ${r.dropReason ?? "(uploaded)"}');
      if (r.earliest != null || r.latest != null) {
        buffer.writeln(
            '  range: ${r.earliest?.toIso8601String() ?? "?"} — ${r.latest?.toIso8601String() ?? "?"}');
      }
      buffer.writeln('');
    }
    return buffer.toString();
  }

  /// Tab-separated report that pastes cleanly into a spreadsheet. Header
  /// exactly matches [tsvHeaderColumns] joined by tabs.
  String toTsv() {
    final buffer = StringBuffer()..writeln(tsvHeaderColumns.join('\t'));
    for (final r in rows) {
      buffer.writeln([
        r.hkType,
        r.rawCount.toString(),
        r.afterPluginDedup.toString(),
        r.uploadable.toString(),
        r.mappedMetric ?? '',
        r.dropReason ?? '',
      ].join('\t'));
    }
    return buffer.toString();
  }

  Map<String, dynamic> toJson() => {
        'window_start': windowStart.toIso8601String(),
        'window_end': windowEnd.toIso8601String(),
        'rows': rows.map((r) => r.toJson()).toList(),
      };

  factory CensusReport.fromJson(Map<String, dynamic> j) => CensusReport(
        windowStart: DateTime.parse(j['window_start'] as String),
        windowEnd: DateTime.parse(j['window_end'] as String),
        rows: (j['rows'] as List<dynamic>? ?? [])
            .map((e) => CensusMetricRow.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
