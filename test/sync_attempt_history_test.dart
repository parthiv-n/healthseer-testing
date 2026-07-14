// Tests for SyncAttemptHistory — the bounded on-device ring buffer of recent
// sync attempts the Dev Tools screen renders.
//
// What MUST hold:
//   1. append/load round-trips a record faithfully (all fields).
//   2. The buffer is capped at 20; the OLDEST records are evicted first and
//      order is preserved (oldest first, newest last).
//   3. A corrupt pref is tolerated (load returns empty, next append resets).

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:vitametric_app/services/sync_attempt_history.dart';

SyncAttemptRecord _rec(int i, {String outcome = 'success'}) => SyncAttemptRecord(
      at: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
      path: 'foreground',
      outcome: outcome,
      eventsSent: i,
      errorClass: outcome == 'success' ? null : 'network',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('round-trip', () {
    test('append then load returns the record with all fields', () async {
      final r = SyncAttemptRecord(
        at: DateTime.utc(2026, 5, 1, 12, 30),
        path: 'background',
        outcome: 'deviceLocked',
        eventsSent: 42,
        errorClass: 'deviceLocked',
      );
      await SyncAttemptHistory.append(r);

      final loaded = await SyncAttemptHistory.load();
      expect(loaded, hasLength(1));
      final got = loaded.single;
      expect(got.at, DateTime.utc(2026, 5, 1, 12, 30));
      expect(got.path, 'background');
      expect(got.outcome, 'deviceLocked');
      expect(got.eventsSent, 42);
      expect(got.errorClass, 'deviceLocked');
    });

    test('toJson/fromJson round-trips including null errorClass', () {
      final r = _rec(3);
      final back = SyncAttemptRecord.fromJson(r.toJson());
      expect(back.at, r.at);
      expect(back.path, r.path);
      expect(back.outcome, r.outcome);
      expect(back.eventsSent, r.eventsSent);
      expect(back.errorClass, isNull);
    });

    test('appends accumulate in order (oldest first)', () async {
      for (var i = 0; i < 3; i++) {
        await SyncAttemptHistory.append(_rec(i));
      }
      final loaded = await SyncAttemptHistory.load();
      expect(loaded.map((r) => r.eventsSent).toList(), [0, 1, 2]);
    });
  });

  group('20-cap eviction', () {
    test('capRecords keeps only the newest 20, preserving order', () {
      final records = [for (var i = 0; i < 25; i++) _rec(i)];
      final capped = SyncAttemptHistory.capRecords(records);
      expect(capped, hasLength(20));
      // Oldest 5 (0..4) evicted; newest retained in order 5..24.
      expect(capped.first.eventsSent, 5);
      expect(capped.last.eventsSent, 24);
    });

    test('append past the cap evicts oldest first', () async {
      for (var i = 0; i < 23; i++) {
        await SyncAttemptHistory.append(_rec(i));
      }
      final loaded = await SyncAttemptHistory.load();
      expect(loaded, hasLength(SyncAttemptHistory.maxRecords));
      // 0,1,2 dropped; window is 3..22.
      expect(loaded.first.eventsSent, 3);
      expect(loaded.last.eventsSent, 22);
    });
  });

  group('corrupt-pref tolerance', () {
    test('load returns empty on non-JSON garbage', () async {
      SharedPreferences.setMockInitialValues({
        SyncAttemptHistory.prefsKey: 'not-json-at-all {{{',
      });
      final loaded = await SyncAttemptHistory.load();
      expect(loaded, isEmpty);
    });

    test('load returns empty when the JSON is an object, not an array', () async {
      SharedPreferences.setMockInitialValues({
        SyncAttemptHistory.prefsKey: '{"unexpected": true}',
      });
      final loaded = await SyncAttemptHistory.load();
      expect(loaded, isEmpty);
    });

    test('append after corruption resets the store to a valid single record',
        () async {
      SharedPreferences.setMockInitialValues({
        SyncAttemptHistory.prefsKey: 'garbage',
      });
      await SyncAttemptHistory.append(_rec(7, outcome: 'network'));
      final loaded = await SyncAttemptHistory.load();
      expect(loaded, hasLength(1));
      expect(loaded.single.outcome, 'network');
      expect(loaded.single.errorClass, 'network');
    });
  });
}
