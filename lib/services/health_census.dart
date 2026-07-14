/// HealthKit / Health Connect census engine.
///
/// A "census" walks the same read → plugin-dedup → drop-rule pipeline the sync
/// path uses, but instead of uploading it tallies, per HealthDataType, how many
/// samples were read, survived the plugin's dedup, and would actually be
/// uploaded — plus why any were dropped. It answers "why didn't metric X reach
/// the portal?" entirely on-device (see lib/models/census_report.dart).
///
/// The counting core [buildCensus] is a pure function over plain
/// [CensusSample] intervals so it is directly unit-testable without a live
/// Health() plugin (see test/census_logic_test.dart). The [HealthCensus]
/// orchestrator wires it to the real plugin + native bridges and persists the
/// last run to SharedPreferences.
library;

import 'dart:convert';
import 'dart:io';

import 'package:health/health.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/census_report.dart';
import 'health_mapping.dart';
import 'health_service.dart';
import 'sleep_apnea_channel.dart';
import 'vo2max_channel.dart';

/// Number of days per read chunk. The full window (default 180 days) is walked
/// in slices this wide so a single getHealthDataFromTypes call never has to
/// materialise months of high-frequency HR samples at once — each chunk's
/// points are folded into count/min/max accumulators and then discarded.
const int censusChunkDays = 30;

/// SharedPreferences key holding the JSON of the most recent census run.
const String kLastCensusPrefsKey = 'dev_last_census_v1';

/// A single observed sample reduced to just what the census needs: its
/// HealthDataType name and its [from, to) interval. Detached from
/// package:health's HealthDataPoint so [buildCensus] stays pure and testable.
class CensusSample {
  final String typeName;
  final DateTime from;
  final DateTime to;

  const CensusSample({
    required this.typeName,
    required this.from,
    required this.to,
  });
}

/// PURE census core. For every [requested] type, produce one
/// [CensusMetricRow] describing what happened to that type's samples:
///
///   * rawCount          — samples the platform returned ([rawByType]).
///   * afterPluginDedup  — samples surviving the plugin dedup ([dedupedByType]).
///   * uploadable        — samples that would actually be uploaded:
///       - 0 when the type has a type-level [uploadDropReason] (awake filter,
///         in-bed envelope, no backend mapping) — dropReason is set.
///       - for SLEEP_ASLEEP, deduped samples that do NOT overlap any granular
///         stage (SLEEP_DEEP/REM/LIGHT) sample are counted; overlapping ones
///         are excluded (they would double-count sleep time on the backend).
///       - otherwise the deduped count.
///   * mappedMetric      — canonical backend metric_type via [healthTypeToLp].
///   * earliest/latest   — min `from` / max `to` across the raw samples.
///
/// Zero-count requested types are still emitted (rawCount == 0) so a reader
/// can tell "read nothing" apart from "not requested".
CensusReport buildCensus({
  required List<HealthDataType> requested,
  required Map<HealthDataType, List<CensusSample>> rawByType,
  required Map<HealthDataType, List<CensusSample>> dedupedByType,
  required bool isIos,
  required DateTime windowStart,
  required DateTime windowEnd,
}) {
  // Gather every granular sleep-stage sample once; SLEEP_ASLEEP rows test
  // their overlap against this pool.
  final granularSamples = <CensusSample>[];
  for (final t in granularSleepStages) {
    final s = dedupedByType[t];
    if (s != null) granularSamples.addAll(s);
  }

  final rows = <CensusMetricRow>[];
  for (final type in requested) {
    final raw = rawByType[type] ?? const [];
    final deduped = dedupedByType[type] ?? const [];
    final dropReason = uploadDropReason(type, isIos: isIos);

    int uploadable;
    if (dropReason != null) {
      uploadable = 0;
    } else if (type == HealthDataType.SLEEP_ASLEEP) {
      // Exclude deduped ASLEEP samples that overlap ANY granular stage.
      uploadable = deduped.where((a) {
        for (final g in granularSamples) {
          if (sleepIntervalsOverlap(a.from, a.to, g.from, g.to)) return false;
        }
        return true;
      }).length;
    } else {
      uploadable = deduped.length;
    }

    DateTime? earliest;
    DateTime? latest;
    for (final s in raw) {
      if (earliest == null || s.from.isBefore(earliest)) earliest = s.from;
      if (latest == null || s.to.isAfter(latest)) latest = s.to;
    }

    rows.add(CensusMetricRow(
      hkType: type.name,
      mappedMetric: healthTypeToLp(type, isIos: isIos),
      rawCount: raw.length,
      afterPluginDedup: deduped.length,
      uploadable: uploadable,
      dropReason: dropReason?.name,
      earliest: earliest,
      latest: latest,
    ));
  }

  return CensusReport(
    windowStart: windowStart,
    windowEnd: windowEnd,
    rows: rows,
  );
}

/// Mutable per-type accumulator used to fold each 30-day chunk's census row
/// into a single window-wide row without retaining any samples.
class _RowAccumulator {
  final String hkType;
  final String? mappedMetric;
  int rawCount = 0;
  int afterPluginDedup = 0;
  int uploadable = 0;
  String? dropReason;
  DateTime? earliest;
  DateTime? latest;

  _RowAccumulator({required this.hkType, required this.mappedMetric});

  void fold(CensusMetricRow row) {
    rawCount += row.rawCount;
    afterPluginDedup += row.afterPluginDedup;
    uploadable += row.uploadable;
    dropReason ??= row.dropReason;
    if (row.earliest != null &&
        (earliest == null || row.earliest!.isBefore(earliest!))) {
      earliest = row.earliest;
    }
    if (row.latest != null &&
        (latest == null || row.latest!.isAfter(latest!))) {
      latest = row.latest;
    }
  }

  CensusMetricRow build() => CensusMetricRow(
        hkType: hkType,
        mappedMetric: mappedMetric,
        rawCount: rawCount,
        afterPluginDedup: afterPluginDedup,
        uploadable: uploadable,
        dropReason: dropReason,
        earliest: earliest,
        latest: latest,
      );
}

/// Orchestrates a full on-device census against the live Health() plugin and
/// the VO2_MAX / SLEEP_APNEA_EVENT native bridges, and persists the result.
class HealthCensus {
  /// Runs a census over [start, end) (default: the last
  /// HealthService.kHistoricalSyncDays days). Walks the window in
  /// [censusChunkDays]-day chunks, reading + plugin-deduping each chunk, then
  /// folds counts into per-type accumulators and discards the samples.
  ///
  /// After the chunk loop it appends VO2_MAX and SLEEP_APNEA_EVENT rows read
  /// over the whole window via the native bridges; a bridge failure appends a
  /// zeroed row with dropReason 'bridge unavailable' rather than failing the
  /// whole census.
  ///
  /// [onProgress] fires once per chunk, e.g. "Chunk 3/6: 12,401 samples".
  /// The completed report is saved to SharedPreferences under
  /// [kLastCensusPrefsKey].
  static Future<CensusReport> runCensus({
    DateTime? start,
    DateTime? end,
    void Function(String)? onProgress,
  }) async {
    final windowEnd = end ?? DateTime.now();
    final windowStart =
        start ?? windowEnd.subtract(Duration(days: HealthService.kHistoricalSyncDays));

    final isIos = Platform.isIOS;
    final coreTypes =
        isIos ? platformSyncTypesIos : platformSyncTypesAndroid;
    final allTypes = <HealthDataType>[...coreTypes, ...optionalSyncTypes];

    await HealthService.ensureHealthConfigured();

    // One accumulator per requested type, in a stable order.
    final accumulators = <HealthDataType, _RowAccumulator>{
      for (final t in allTypes)
        t: _RowAccumulator(
          hkType: t.name,
          mappedMetric: healthTypeToLp(t, isIos: isIos),
        ),
    };

    final totalChunks =
        (windowEnd.difference(windowStart).inDays / censusChunkDays).ceil();
    var chunkStart = windowStart;
    var chunkIdx = 0;

    while (chunkStart.isBefore(windowEnd)) {
      chunkIdx++;
      final rawChunkEnd = chunkStart.add(const Duration(days: censusChunkDays));
      final chunkEnd = rawChunkEnd.isBefore(windowEnd) ? rawChunkEnd : windowEnd;

      List<HealthDataPoint> rawPoints;
      try {
        rawPoints = await Health().getHealthDataFromTypes(
          types: allTypes,
          startTime: chunkStart,
          endTime: chunkEnd,
        );
      } catch (_) {
        // A single chunk's read failure must not abort the whole census —
        // treat it as an empty chunk and keep walking the window.
        rawPoints = const [];
      }

      final deduped = Health().removeDuplicates(rawPoints);

      final rawByType = _groupByType(rawPoints);
      final dedupedByType = _groupByType(deduped);

      final chunkReport = buildCensus(
        requested: allTypes,
        rawByType: rawByType,
        dedupedByType: dedupedByType,
        isIos: isIos,
        windowStart: chunkStart,
        windowEnd: chunkEnd,
      );

      for (final row in chunkReport.rows) {
        // Row order matches `allTypes` order, but look up by name to be safe.
        for (final entry in accumulators.entries) {
          if (entry.key.name == row.hkType) {
            entry.value.fold(row);
            break;
          }
        }
      }

      onProgress?.call(
          'Chunk $chunkIdx/$totalChunks: ${_thousands(rawPoints.length)} samples');

      // Explicitly drop references so the chunk's points can be GC'd before
      // the next (potentially large) read.
      chunkStart = chunkEnd;
    }

    final rows = <CensusMetricRow>[
      for (final t in allTypes) accumulators[t]!.build(),
    ];

    // ── Native-bridge metrics (VO2_MAX, SLEEP_APNEA_EVENT) ────────────────
    rows.add(await _bridgeRow(
      hkType: 'VO2_MAX',
      read: () => Vo2MaxChannel.readVo2Max(windowStart, windowEnd),
    ));
    rows.add(await _bridgeRow(
      hkType: 'SLEEP_APNEA_EVENT',
      read: () => SleepApneaChannel.readApneaEvents(windowStart, windowEnd),
    ));

    final report = CensusReport(
      windowStart: windowStart,
      windowEnd: windowEnd,
      rows: rows,
    );

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kLastCensusPrefsKey, jsonEncode(report.toJson()));
    } catch (_) {
      // Persisting the census is best-effort; never fail the run over it.
    }

    return report;
  }

  /// Loads the most recent persisted census, or null if none / unparseable.
  static Future<CensusReport?> loadLastCensus() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kLastCensusPrefsKey);
      if (raw == null || raw.isEmpty) return null;
      return CensusReport.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Reads a native-bridge metric and builds a single-row census entry. On any
  /// bridge failure, returns a zeroed row tagged 'bridge unavailable' so the
  /// census as a whole still succeeds.
  static Future<CensusMetricRow> _bridgeRow({
    required String hkType,
    required Future<List<Map<String, dynamic>>> Function() read,
  }) async {
    try {
      final events = await read();
      DateTime? earliest;
      DateTime? latest;
      for (final e in events) {
        final f = DateTime.tryParse(e['start_time'] as String? ?? '');
        final t = DateTime.tryParse(e['end_time'] as String? ?? '');
        if (f != null && (earliest == null || f.isBefore(earliest))) {
          earliest = f;
        }
        if (t != null && (latest == null || t.isAfter(latest))) latest = t;
      }
      return CensusMetricRow(
        hkType: hkType,
        mappedMetric: hkType, // native metrics already use canonical names
        rawCount: events.length,
        afterPluginDedup: events.length,
        uploadable: events.length,
        earliest: earliest,
        latest: latest,
      );
    } catch (_) {
      return CensusMetricRow(
        hkType: hkType,
        mappedMetric: hkType,
        rawCount: 0,
        afterPluginDedup: 0,
        uploadable: 0,
        dropReason: 'bridge unavailable',
      );
    }
  }

  static Map<HealthDataType, List<CensusSample>> _groupByType(
      List<HealthDataPoint> points) {
    final out = <HealthDataType, List<CensusSample>>{};
    for (final p in points) {
      (out[p.type] ??= <CensusSample>[]).add(CensusSample(
        typeName: p.type.name,
        from: p.dateFrom,
        to: p.dateTo,
      ));
    }
    return out;
  }

  /// Formats an int with thousands separators (e.g. 12401 -> "12,401").
  static String _thousands(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}
