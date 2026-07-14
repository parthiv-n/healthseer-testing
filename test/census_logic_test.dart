import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:vitametric_app/models/census_report.dart';
import 'package:vitametric_app/services/health_census.dart';

// ── Fixture helpers ─────────────────────────────────────────────────────────

final _base = DateTime.utc(2026, 4, 1, 0, 0);

CensusSample _sample(int fromMin, int toMin, {String typeName = 'x'}) =>
    CensusSample(
      typeName: typeName,
      from: _base.add(Duration(minutes: fromMin)),
      to: _base.add(Duration(minutes: toMin)),
    );

CensusReport _run({
  required List<HealthDataType> requested,
  required Map<HealthDataType, List<CensusSample>> raw,
  Map<HealthDataType, List<CensusSample>>? deduped,
  bool isIos = true,
}) =>
    buildCensus(
      requested: requested,
      rawByType: raw,
      dedupedByType: deduped ?? raw,
      isIos: isIos,
      windowStart: _base,
      windowEnd: _base.add(const Duration(days: 1)),
    );

CensusMetricRow _row(CensusReport r, HealthDataType t) =>
    r.rows.firstWhere((row) => row.hkType == t.name);

void main() {
  group('buildCensus counting', () {
    test('rawCount and afterPluginDedup reflect the two maps', () {
      final report = _run(
        requested: [HealthDataType.HEART_RATE],
        raw: {
          HealthDataType.HEART_RATE: [
            _sample(0, 0),
            _sample(1, 1),
            _sample(2, 2),
          ],
        },
        deduped: {
          HealthDataType.HEART_RATE: [_sample(0, 0), _sample(2, 2)],
        },
      );
      final row = _row(report, HealthDataType.HEART_RATE);
      expect(row.rawCount, 3);
      expect(row.afterPluginDedup, 2);
      expect(row.uploadable, 2); // mapped, no drop rule
      expect(row.mappedMetric, 'HR_INSTANT');
      expect(row.dropReason, isNull);
    });

    test('emits a zero-count row for a requested type with no samples', () {
      final report = _run(
        requested: [HealthDataType.HEART_RATE, HealthDataType.STEPS],
        raw: {
          HealthDataType.HEART_RATE: [_sample(0, 0)],
        },
      );
      final steps = _row(report, HealthDataType.STEPS);
      expect(steps.rawCount, 0);
      expect(steps.afterPluginDedup, 0);
      expect(steps.uploadable, 0);
      expect(steps.mappedMetric, 'STEPS_DELTA');
    });

    test('empty requested list -> empty report', () {
      final report = _run(requested: const [], raw: const {});
      expect(report.rows, isEmpty);
    });
  });

  group('drop-reason attribution', () {
    test('SLEEP_IN_BED -> inBedEnvelope, uploadable 0', () {
      final report = _run(
        requested: [HealthDataType.SLEEP_IN_BED],
        raw: {
          HealthDataType.SLEEP_IN_BED: [_sample(0, 480), _sample(1440, 1920)],
        },
      );
      final row = _row(report, HealthDataType.SLEEP_IN_BED);
      expect(row.rawCount, 2);
      expect(row.afterPluginDedup, 2);
      expect(row.uploadable, 0);
      expect(row.dropReason, 'inBedEnvelope');
    });

    test('SLEEP_AWAKE -> awakeFiltered, uploadable 0', () {
      final report = _run(
        requested: [HealthDataType.SLEEP_AWAKE],
        raw: {
          HealthDataType.SLEEP_AWAKE: [_sample(0, 10)],
        },
      );
      final row = _row(report, HealthDataType.SLEEP_AWAKE);
      expect(row.uploadable, 0);
      expect(row.dropReason, 'awakeFiltered');
    });

    test('unmapped type -> noMapping, uploadable 0, mappedMetric null', () {
      // SLEEP_AWAKE_IN_BED has no backend mapping AND is awake-filtered;
      // awakeFiltered wins (checked first). Use a genuinely unmapped
      // non-sleep type instead to isolate the noMapping branch.
      final report = _run(
        requested: [HealthDataType.WATER],
        raw: {
          HealthDataType.WATER: [_sample(0, 0)],
        },
      );
      final row = _row(report, HealthDataType.WATER);
      expect(row.mappedMetric, isNull);
      expect(row.uploadable, 0);
      expect(row.dropReason, 'noMapping');
    });
  });

  group('SLEEP_ASLEEP overlap exclusion', () {
    test('ASLEEP samples overlapping a granular stage are excluded', () {
      // Three ASLEEP segments; the middle one overlaps a SLEEP_DEEP sample.
      final report = _run(
        requested: [HealthDataType.SLEEP_ASLEEP, HealthDataType.SLEEP_DEEP],
        raw: {
          HealthDataType.SLEEP_ASLEEP: [
            _sample(0, 30),
            _sample(60, 90), // overlaps DEEP below
            _sample(120, 150),
          ],
          HealthDataType.SLEEP_DEEP: [_sample(70, 80)],
        },
      );
      final asleep = _row(report, HealthDataType.SLEEP_ASLEEP);
      expect(asleep.afterPluginDedup, 3);
      expect(asleep.uploadable, 2); // middle one excluded
      expect(asleep.dropReason, isNull);

      final deep = _row(report, HealthDataType.SLEEP_DEEP);
      expect(deep.uploadable, 1); // granular stages upload as-is
      expect(deep.mappedMetric, 'SLEEP_DEEP');
    });

    test('with no granular stages present, all ASLEEP samples are uploadable',
        () {
      final report = _run(
        requested: [HealthDataType.SLEEP_ASLEEP],
        raw: {
          HealthDataType.SLEEP_ASLEEP: [_sample(0, 30), _sample(60, 90)],
        },
      );
      expect(_row(report, HealthDataType.SLEEP_ASLEEP).uploadable, 2);
    });

    test('touching endpoints do not count as overlap', () {
      // ASLEEP [60,90) and DEEP [90,100) touch but do not overlap.
      final report = _run(
        requested: [HealthDataType.SLEEP_ASLEEP, HealthDataType.SLEEP_DEEP],
        raw: {
          HealthDataType.SLEEP_ASLEEP: [_sample(60, 90)],
          HealthDataType.SLEEP_DEEP: [_sample(90, 100)],
        },
      );
      expect(_row(report, HealthDataType.SLEEP_ASLEEP).uploadable, 1);
    });
  });

  group('earliest / latest', () {
    test('earliest is min(from), latest is max(to) across raw samples', () {
      final report = _run(
        requested: [HealthDataType.HEART_RATE],
        raw: {
          HealthDataType.HEART_RATE: [
            _sample(120, 121),
            _sample(10, 11),
            _sample(60, 200),
          ],
        },
      );
      final row = _row(report, HealthDataType.HEART_RATE);
      expect(row.earliest, _base.add(const Duration(minutes: 10)));
      expect(row.latest, _base.add(const Duration(minutes: 200)));
    });

    test('zero-count row has null earliest/latest', () {
      final report = _run(
        requested: [HealthDataType.STEPS],
        raw: const {},
      );
      final row = _row(report, HealthDataType.STEPS);
      expect(row.earliest, isNull);
      expect(row.latest, isNull);
    });
  });
}
