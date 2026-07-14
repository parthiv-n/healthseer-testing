import 'package:flutter_test/flutter_test.dart';
import 'package:vitametric_app/models/reconciliation.dart';

void main() {
  // A representative full-shape response matching the backend contract.
  Map<String, dynamic> fullJson() => {
        'user_id': 'u-123',
        'window_days': 180,
        'generated_at': '2026-07-13T08:00:00.000Z',
        'raw_window': 'created_at',
        'sync_log_id': 42,
        'metrics': {
          'HR_INSTANT': {
            'raw_uploaded': 1000,
            'canonical_total': 990,
            'by_status': {
              'valid': 900,
              'valid_low_quality': 20,
              'valid_dedup_survivor': 30,
              'invalid_physiological': 10,
              'invalid_duplicate': 25,
              'invalid_context_conflict': 5,
            },
            'usable': 950,
            'latest_event_time': '2026-07-13T07:59:00.000Z',
          },
          'STEPS_DELTA': {
            'raw_uploaded': 200,
            'canonical_total': 200,
            'by_status': {'valid': 200},
            'usable': 200,
            'latest_event_time': null,
          },
        },
      };

  group('ReconciliationResponse.fromJson', () {
    test('parses the full contract shape', () {
      final r = ReconciliationResponse.fromJson(fullJson());
      expect(r.userId, 'u-123');
      expect(r.windowDays, 180);
      expect(r.rawWindow, 'created_at');
      expect(r.syncLogId, 42);
      expect(r.generatedAt, DateTime.utc(2026, 7, 13, 8, 0, 0));
      expect(r.metrics.keys, containsAll(['HR_INSTANT', 'STEPS_DELTA']));

      final hr = r.metrics['HR_INSTANT']!;
      expect(hr.rawUploaded, 1000);
      expect(hr.canonicalTotal, 990);
      expect(hr.usable, 950);
      expect(hr.byStatus['valid'], 900);
      expect(hr.byStatus['invalid_duplicate'], 25);
      expect(hr.latestEventTime, DateTime.utc(2026, 7, 13, 7, 59, 0));
    });

    test('null latest_event_time yields a null DateTime', () {
      final r = ReconciliationResponse.fromJson(fullJson());
      expect(r.metrics['STEPS_DELTA']!.latestEventTime, isNull);
    });

    test('tolerates missing top-level fields', () {
      final r = ReconciliationResponse.fromJson({});
      expect(r.userId, '');
      expect(r.windowDays, 0);
      expect(r.rawWindow, '');
      expect(r.syncLogId, isNull);
      expect(r.generatedAt, isNull);
      expect(r.metrics, isEmpty);
    });

    test('tolerates missing per-metric fields (defaults 0 / empty)', () {
      final r = ReconciliationResponse.fromJson({
        'metrics': {
          'HRV_SDNN': {}, // completely empty metric object
        },
      });
      final m = r.metrics['HRV_SDNN']!;
      expect(m.rawUploaded, 0);
      expect(m.canonicalTotal, 0);
      expect(m.usable, 0);
      expect(m.byStatus, isEmpty);
      expect(m.latestEventTime, isNull);
    });

    test('null sync_log_id is preserved as null', () {
      final j = fullJson()..['sync_log_id'] = null;
      expect(ReconciliationResponse.fromJson(j).syncLogId, isNull);
    });
  });

  group('round-trip', () {
    test('toJson -> fromJson preserves all fields', () {
      final original = ReconciliationResponse.fromJson(fullJson());
      final roundTripped =
          ReconciliationResponse.fromJson(original.toJson());

      expect(roundTripped.userId, original.userId);
      expect(roundTripped.windowDays, original.windowDays);
      expect(roundTripped.rawWindow, original.rawWindow);
      expect(roundTripped.syncLogId, original.syncLogId);
      expect(roundTripped.generatedAt, original.generatedAt);
      expect(roundTripped.metrics.length, original.metrics.length);

      final hr = roundTripped.metrics['HR_INSTANT']!;
      final origHr = original.metrics['HR_INSTANT']!;
      expect(hr.rawUploaded, origHr.rawUploaded);
      expect(hr.canonicalTotal, origHr.canonicalTotal);
      expect(hr.usable, origHr.usable);
      expect(hr.byStatus, origHr.byStatus);
      expect(hr.latestEventTime, origHr.latestEventTime);
    });
  });
}
