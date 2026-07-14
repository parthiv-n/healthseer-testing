import 'package:flutter_test/flutter_test.dart';
import 'package:vitametric_app/models/census_report.dart';
import 'package:vitametric_app/models/reconciliation.dart';
import 'package:vitametric_app/services/census_compare.dart';

// ── Fixture helpers ─────────────────────────────────────────────────────────

CensusMetricRow _row(String hkType, String? metric, int uploadable) =>
    CensusMetricRow(
      hkType: hkType,
      mappedMetric: metric,
      rawCount: uploadable,
      afterPluginDedup: uploadable,
      uploadable: uploadable,
    );

CensusReport _census(List<CensusMetricRow> rows) => CensusReport(
      windowStart: DateTime.utc(2026, 1, 1),
      windowEnd: DateTime.utc(2026, 7, 1),
      rows: rows,
    );

ReconciliationMetric _metric(int rawUploaded, {int usable = 0}) =>
    ReconciliationMetric(
      rawUploaded: rawUploaded,
      canonicalTotal: rawUploaded,
      byStatus: const {},
      usable: usable,
    );

ReconciliationResponse _server(Map<String, ReconciliationMetric> metrics) =>
    ReconciliationResponse(
      userId: 'u',
      windowDays: 180,
      rawWindow: 'created_at',
      metrics: metrics,
    );

CompareRow _find(List<CompareRow> rows, String metric) =>
    rows.firstWhere((r) => r.metric == metric);

void main() {
  group('compareCensusToServer', () {
    test('exact match -> ok', () {
      final rows = compareCensusToServer(
        _census([_row('HEART_RATE', 'HR_INSTANT', 1000)]),
        _server({'HR_INSTANT': _metric(1000, usable: 990)}),
      );
      final r = _find(rows, 'HR_INSTANT');
      expect(r.status, CompareStatus.ok);
      expect(r.delta, 0);
      expect(r.deltaPct, 0.0);
      expect(r.serverUsable, 990);
      expect(r.note, '');
    });

    test('small delta (<2%) -> warn', () {
      // 1000 hk vs 1010 server => +1.0%
      final rows = compareCensusToServer(
        _census([_row('HEART_RATE', 'HR_INSTANT', 1000)]),
        _server({'HR_INSTANT': _metric(1010)}),
      );
      final r = _find(rows, 'HR_INSTANT');
      expect(r.status, CompareStatus.warn);
      expect(r.delta, 10);
      expect(r.deltaPct, closeTo(1.0, 0.0001));
    });

    test('delta >= 2% -> fail', () {
      // 1000 hk vs 1030 server => +3.0%
      final rows = compareCensusToServer(
        _census([_row('HEART_RATE', 'HR_INSTANT', 1000)]),
        _server({'HR_INSTANT': _metric(1030)}),
      );
      final r = _find(rows, 'HR_INSTANT');
      expect(r.status, CompareStatus.fail);
      expect(r.deltaPct, closeTo(3.0, 0.0001));
    });

    test('exactly 2% -> fail (boundary)', () {
      final rows = compareCensusToServer(
        _census([_row('HEART_RATE', 'HR_INSTANT', 1000)]),
        _server({'HR_INSTANT': _metric(1020)}),
      );
      expect(_find(rows, 'HR_INSTANT').status, CompareStatus.fail);
    });

    test('hk-only -> fail + "missing on server"', () {
      final rows = compareCensusToServer(
        _census([_row('STEPS', 'STEPS_DELTA', 500)]),
        _server({}),
      );
      final r = _find(rows, 'STEPS_DELTA');
      expect(r.status, CompareStatus.fail);
      expect(r.note, 'missing on server');
      expect(r.serverRawUploaded, 0);
    });

    test('server-only -> fail + "server-only (e.g. XML import)"', () {
      final rows = compareCensusToServer(
        _census([]),
        _server({'BP_SYSTOLIC': _metric(40)}),
      );
      final r = _find(rows, 'BP_SYSTOLIC');
      expect(r.status, CompareStatus.fail);
      expect(r.note, 'server-only (e.g. XML import)');
      expect(r.hkUploadable, 0);
      expect(r.deltaPct, isNull); // hkUploadable == 0
    });

    test('0 vs 0 -> ok', () {
      final rows = compareCensusToServer(
        _census([_row('STEPS', 'STEPS_DELTA', 0)]),
        _server({'STEPS_DELTA': _metric(0)}),
      );
      final r = _find(rows, 'STEPS_DELTA');
      expect(r.status, CompareStatus.ok);
      expect(r.delta, 0);
      expect(r.deltaPct, isNull); // hkUploadable == 0 -> undefined
    });

    test('deltaPct is null when hkUploadable == 0 but present on both sides',
        () {
      final rows = compareCensusToServer(
        _census([_row('STEPS', 'STEPS_DELTA', 0)]),
        _server({'STEPS_DELTA': _metric(5)}),
      );
      final r = _find(rows, 'STEPS_DELTA');
      expect(r.deltaPct, isNull);
      // Present on both sides, delta != 0, deltaPct null -> falls to fail.
      expect(r.status, CompareStatus.fail);
    });

    test('null-mapped census rows are skipped in aggregation', () {
      final rows = compareCensusToServer(
        _census([
          _row('SLEEP_AWAKE', null, 3), // no mapping -> ignored
          _row('HEART_RATE', 'HR_INSTANT', 100),
        ]),
        _server({'HR_INSTANT': _metric(100)}),
      );
      expect(rows.any((r) => r.metric == 'null'), isFalse);
      expect(rows, hasLength(1));
      expect(_find(rows, 'HR_INSTANT').status, CompareStatus.ok);
    });

    test('census uploadable is summed across rows mapping to same metric', () {
      final rows = compareCensusToServer(
        _census([
          _row('SLEEP_DEEP', 'SLEEP_DEEP', 10),
          _row('SLEEP_DEEP', 'SLEEP_DEEP', 5), // same metric again
        ]),
        _server({'SLEEP_DEEP': _metric(15)}),
      );
      final r = _find(rows, 'SLEEP_DEEP');
      expect(r.hkUploadable, 15);
      expect(r.status, CompareStatus.ok);
    });

    test('VO2_MAX gets the "sync lookback 90d" note appended', () {
      final rows = compareCensusToServer(
        _census([_row('VO2_MAX', 'VO2_MAX', 5)]),
        _server({'VO2_MAX': _metric(8)}),
      );
      final r = _find(rows, 'VO2_MAX');
      expect(r.note, contains('sync lookback 90d'));
    });

    test('SLEEP_APNEA_EVENT note carries lookback plus any drift note', () {
      // hk 5 vs server 50 -> big delta -> fail note, plus lookback suffix.
      final rows = compareCensusToServer(
        _census([_row('SLEEP_APNEA_EVENT', 'SLEEP_APNEA_EVENT', 5)]),
        _server({'SLEEP_APNEA_EVENT': _metric(50)}),
      );
      final r = _find(rows, 'SLEEP_APNEA_EVENT');
      expect(r.note, contains('sync lookback 90d'));
      expect(r.status, CompareStatus.fail);
    });
  });

  group('compareTsv', () {
    test('header shape is exact', () {
      final tsv = compareTsv([]);
      final header = tsv.trim();
      expect(
        header,
        'Metric\tHK Uploadable\tServer Accepted\tServer Usable\t'
        'Delta\tDelta %\tStatus\tNote',
      );
    });

    test('a data row renders all columns with 1-dp delta%', () {
      final rows = compareCensusToServer(
        _census([_row('HEART_RATE', 'HR_INSTANT', 1000)]),
        _server({'HR_INSTANT': _metric(1010, usable: 1000)}),
      );
      final line = compareTsv(rows).split('\n')[1];
      final cols = line.split('\t');
      expect(cols[0], 'HR_INSTANT');
      expect(cols[1], '1000'); // HK uploadable
      expect(cols[2], '1010'); // server accepted
      expect(cols[3], '1000'); // server usable
      expect(cols[4], '10'); // delta
      expect(cols[5], '1.0'); // delta %
      expect(cols[6], 'warn'); // status
    });

    test('null delta% renders as empty cell', () {
      final rows = compareCensusToServer(
        _census([]),
        _server({'BP_SYSTOLIC': _metric(40)}),
      );
      final line = compareTsv(rows).split('\n')[1];
      final cols = line.split('\t');
      expect(cols[5], ''); // delta % empty when hkUploadable == 0
    });
  });
}
