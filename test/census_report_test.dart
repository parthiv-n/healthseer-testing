// Tests for lib/models/census_report.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:vitametric_app/models/census_report.dart';

void main() {
  final sampleRows = [
    const CensusMetricRow(
      hkType: 'HEART_RATE',
      mappedMetric: 'HR_INSTANT',
      rawCount: 120,
      afterPluginDedup: 118,
      uploadable: 118,
    ),
    const CensusMetricRow(
      hkType: 'SLEEP_IN_BED',
      rawCount: 4,
      afterPluginDedup: 4,
      uploadable: 0,
      dropReason: 'inBedEnvelope',
    ),
  ];

  CensusReport buildReport() => CensusReport(
        windowStart: DateTime.utc(2026, 7, 1),
        windowEnd: DateTime.utc(2026, 7, 8),
        rows: sampleRows,
      );

  group('CensusReport.toTsv', () {
    test('header matches the exact pinned column order', () {
      final lines = buildReport().toTsv().trim().split('\n');
      expect(
        lines.first,
        'Metric\tApple Raw Count\tAfter Dedup\tUploadable\tMapped Type\tDrop Reason',
      );
    });

    test('rows are tab-separated in header column order', () {
      final lines = buildReport().toTsv().trim().split('\n');
      expect(
        lines[1].split('\t'),
        ['HEART_RATE', '120', '118', '118', 'HR_INSTANT', ''],
      );
      expect(
        lines[2].split('\t'),
        ['SLEEP_IN_BED', '4', '4', '0', '', 'inBedEnvelope'],
      );
    });

    test('emits exactly one line per row plus the header', () {
      final lines = buildReport().toTsv().trim().split('\n');
      expect(lines.length, sampleRows.length + 1);
    });
  });

  group('CensusReport.toDisplayText', () {
    test('produces non-empty human-readable text', () {
      expect(buildReport().toDisplayText(), isNotEmpty);
    });

    test('includes each hkType and the window bounds', () {
      final report = buildReport();
      final text = report.toDisplayText();
      for (final r in sampleRows) {
        expect(text.contains(r.hkType), isTrue);
      }
      expect(text.contains(report.windowStart.toIso8601String()), isTrue);
      expect(text.contains(report.windowEnd.toIso8601String()), isTrue);
    });
  });

  group('JSON round-trip', () {
    test('CensusMetricRow survives toJson/fromJson', () {
      for (final row in sampleRows) {
        final decoded = CensusMetricRow.fromJson(row.toJson());
        expect(decoded.hkType, row.hkType);
        expect(decoded.mappedMetric, row.mappedMetric);
        expect(decoded.rawCount, row.rawCount);
        expect(decoded.afterPluginDedup, row.afterPluginDedup);
        expect(decoded.uploadable, row.uploadable);
        expect(decoded.dropReason, row.dropReason);
        expect(decoded.earliest, row.earliest);
        expect(decoded.latest, row.latest);
      }
    });

    test('CensusReport survives toJson/fromJson', () {
      final report = buildReport();
      final decoded = CensusReport.fromJson(report.toJson());
      expect(decoded.windowStart, report.windowStart);
      expect(decoded.windowEnd, report.windowEnd);
      expect(decoded.rows.length, report.rows.length);
      for (var i = 0; i < report.rows.length; i++) {
        expect(decoded.rows[i].hkType, report.rows[i].hkType);
        expect(decoded.rows[i].mappedMetric, report.rows[i].mappedMetric);
        expect(decoded.rows[i].uploadable, report.rows[i].uploadable);
        expect(decoded.rows[i].dropReason, report.rows[i].dropReason);
      }
    });

    test('earliest/latest DateTime fields round-trip exactly', () {
      final row = CensusMetricRow(
        hkType: 'STEPS',
        mappedMetric: 'STEPS_DELTA',
        rawCount: 10,
        afterPluginDedup: 10,
        uploadable: 10,
        earliest: DateTime.utc(2026, 7, 1, 8, 30),
        latest: DateTime.utc(2026, 7, 1, 20, 0),
      );
      final decoded = CensusMetricRow.fromJson(row.toJson());
      expect(decoded.earliest, row.earliest);
      expect(decoded.latest, row.latest);
    });

    test('null earliest/latest round-trip as null', () {
      final decoded = CensusMetricRow.fromJson(sampleRows[1].toJson());
      expect(decoded.earliest, isNull);
      expect(decoded.latest, isNull);
    });
  });
}
