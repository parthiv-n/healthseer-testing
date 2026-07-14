// Tests for SyncStateStore (Track B) — the single source of truth for
// "what's the state of mobile sync?".
//
// What MUST be true after these tests pass, no matter what state the
// previous build left in SharedPreferences:
//
//   1. A stale `lp_api_url` (the dead `lifepulse-api-…run.app` from
//      build 22) is cleared on app start.  Without this the v4.5
//      stuck-on-stale-URL outage cannot self-heal.
//
//   2. Legacy sync-state keys (`last_sync_iso`, `last_sync_success`,
//      etc.) are forwarded into the new schema and then deleted.  The
//      user does not see "never synced" after upgrading.
//
//   3. SyncState's lastAttemptFailed predicate correctly distinguishes
//      "last attempt was a failure" from "the most recent thing that
//      happened was a success".  This is what kills the v4.5
//      "Last synced 4 days ago / Failed today" UX bug.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:vitametric_app/services/sync_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SyncStateStore.instance.resetForTest();
  });

  // ── isAllowedApiUrl ────────────────────────────────────────────────────────

  group('isAllowedApiUrl', () {
    test('accepts the production Firebase Hosting URL', () {
      expect(isAllowedApiUrl('https://vitametric.web.app'), isTrue);
    });

    test('accepts *.tikcare.co subdomain', () {
      expect(isAllowedApiUrl('https://api.tikcare.co'), isTrue);
      expect(isAllowedApiUrl('https://staging.tikcare.co'), isTrue);
    });

    test('accepts localhost / 127.0.0.1 for dev', () {
      expect(isAllowedApiUrl('http://localhost:8080'), isTrue);
      expect(isAllowedApiUrl('http://127.0.0.1:8080'), isTrue);
    });

    test('REJECTS the dead lifepulse-api Cloud Run URL', () {
      // This is the v4.5 trap.  This URL DNS-resolves but the service
      // is gone, so requests timeout / 404 with no useful diagnostic.
      expect(
        isAllowedApiUrl(
          'https://lifepulse-api-63410932899.us-central1.run.app',
        ),
        isFalse,
        reason:
            'lifepulse-api Cloud Run service is decommissioned; clients '
            'still pointing here would silently fail forever',
      );
    });

    test('rejects null / empty / malformed', () {
      expect(isAllowedApiUrl(null), isFalse);
      expect(isAllowedApiUrl(''), isFalse);
      expect(isAllowedApiUrl('not a url'), isFalse);
      expect(isAllowedApiUrl('ftp://vitametric.web.app'), isFalse);
    });

    test('REJECTS http:// for non-localhost hosts (MITM defense)', () {
      // Without this rule, an attacker on a captive portal / poisoned
      // DNS could redirect a build that historically wrote
      // http://api.tikcare.co into prefs and the migration would
      // preserve it as a plaintext-credential MITM target.
      expect(isAllowedApiUrl('http://api.tikcare.co'), isFalse);
      expect(isAllowedApiUrl('http://vitametric.web.app'), isFalse);
    });

    test('still ALLOWS http:// for localhost (dev builds)', () {
      // Loopback is the only place plain http is acceptable.
      expect(isAllowedApiUrl('http://localhost:8080'), isTrue);
      expect(isAllowedApiUrl('http://127.0.0.1:8080'), isTrue);
    });

    test('rejects URL with embedded userinfo (Basic-auth injection)', () {
      // An attacker-crafted URL with userinfo would otherwise pass the
      // host check and be stored in lp_api_url.  The HTTP client would
      // then send the userinfo as a Basic auth header on every request.
      expect(
        isAllowedApiUrl('https://attacker:pw@vitametric.web.app'),
        isFalse,
        reason: 'userinfo must invalidate the URL even when host whitelisted',
      );
    });

    test('rejects look-alike host names', () {
      // A host that contains "vitametric.web.app" but is not it.
      expect(
        isAllowedApiUrl('https://attacker.com/vitametric.web.app'),
        isFalse,
      );
      expect(
        isAllowedApiUrl('https://vitametric.web.app.attacker.com'),
        isFalse,
      );
    });
  });

  // ── migrate(): URL self-heal ───────────────────────────────────────────────

  group('SyncStateStore.migrate URL self-heal', () {
    test('clears the dead lifepulse-api URL on first launch', () async {
      SharedPreferences.setMockInitialValues({
        'lp_api_url':
            'https://lifepulse-api-63410932899.us-central1.run.app',
      });

      final report = await SyncStateStore.instance.migrate();

      expect(report.staleUrlCleared, isNotNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lp_api_url'), isNull,
          reason:
              'stale URL must be evicted so _baseUrl falls back to the '
              'compile-time default kDefaultApiUrl');
    });

    test('clears the dead URL even on subsequent launches', () async {
      // First launch: nothing to clear.
      await SyncStateStore.instance.migrate();
      // User somehow ended up with a stale URL after the migration
      // flag was set (e.g. a downgrade roundtrip).  The self-heal
      // must NOT be gated by the migration flag.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'lp_api_url', 'https://lifepulse-api-anything.run.app');

      final report = await SyncStateStore.instance.migrate();
      expect(report.staleUrlCleared, isNotNull);
      expect(prefs.getString('lp_api_url'), isNull);
    });

    test('does NOT clear a valid URL', () async {
      SharedPreferences.setMockInitialValues({
        'lp_api_url': 'https://vitametric.web.app',
      });
      final report = await SyncStateStore.instance.migrate();

      expect(report.staleUrlCleared, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lp_api_url'), 'https://vitametric.web.app');
    });
  });

  // ── migrate(): legacy key forwarding ───────────────────────────────────────

  group('SyncStateStore.migrate legacy forwarding', () {
    test('forwards a successful legacy sync into the new schema', () async {
      SharedPreferences.setMockInitialValues({
        'last_sync_iso': '2026-04-25T10:00:00.000Z',
        'last_sync_success': true,
        'last_event_count': 42,
        'client_upload_anchor_iso': '2026-04-25T09:30:00.000Z',
      });

      await SyncStateStore.instance.migrate();
      final state = SyncStateStore.instance.value;

      expect(state.lastAttemptAtIso, '2026-04-25T10:00:00.000Z');
      expect(state.lastSuccessAtIso, '2026-04-25T10:00:00.000Z');
      expect(state.lastEventCount, 42);
      expect(state.clientUploadAnchorIso, '2026-04-25T09:30:00.000Z');
      expect(state.lastErrorClass, isNull);
    });

    test('forwards a failed legacy sync without a success timestamp', () async {
      SharedPreferences.setMockInitialValues({
        'last_sync_iso': '2026-04-25T10:00:00.000Z',
        'last_sync_success': false,
        'last_sync_error_type': 'serverError',
      });

      await SyncStateStore.instance.migrate();
      final state = SyncStateStore.instance.value;

      expect(state.lastAttemptAtIso, '2026-04-25T10:00:00.000Z');
      expect(state.lastSuccessAtIso, isNull);
      expect(state.lastErrorClass, 'serverError');
    });

    test('removes legacy keys after a successful migration', () async {
      SharedPreferences.setMockInitialValues({
        'last_sync_iso': '2026-04-25T10:00:00.000Z',
        'last_sync_success': true,
        'last_event_count': 42,
      });

      await SyncStateStore.instance.migrate();
      final prefs = await SharedPreferences.getInstance();

      for (final k in SyncStateStore.legacyKeys) {
        expect(prefs.containsKey(k), isFalse,
            reason: 'legacy key $k must be evicted after migration');
      }
    });

    test('migration is idempotent: rerunning is a no-op', () async {
      SharedPreferences.setMockInitialValues({
        'last_sync_iso': '2026-04-25T10:00:00.000Z',
        'last_sync_success': true,
      });

      final first = await SyncStateStore.instance.migrate();
      expect(first.migrationApplied, isTrue);
      expect(first.migrationAlreadyDone, isFalse);

      final second = await SyncStateStore.instance.migrate();
      expect(second.migrationApplied, isFalse);
      expect(second.migrationAlreadyDone, isTrue);
    });
  });

  // ── lastAttemptFailed predicate ────────────────────────────────────────────

  group('SyncState.lastAttemptFailed', () {
    test('returns false when there has been no attempt', () {
      const s = SyncState();
      expect(s.lastAttemptFailed, isFalse);
    });

    test('returns true when an attempt exists but no success has', () {
      const s = SyncState(lastAttemptAtIso: '2026-05-01T00:00:00Z');
      expect(s.lastAttemptFailed, isTrue);
    });

    test('returns false when the latest attempt IS a success', () {
      const s = SyncState(
        lastAttemptAtIso: '2026-05-01T10:00:00Z',
        lastSuccessAtIso: '2026-05-01T10:00:00Z',
      );
      expect(s.lastAttemptFailed, isFalse);
    });

    test('returns true when an attempt happened AFTER the last success',
        () {
      // Profile must show "synced earlier today, latest attempt failed".
      // Without this distinction we get the v4.5 contradictory UX.
      const s = SyncState(
        lastSuccessAtIso: '2026-05-01T08:00:00Z',
        lastAttemptAtIso: '2026-05-01T10:00:00Z',
      );
      expect(s.lastAttemptFailed, isTrue);
    });
  });

  // ── update() persistence + ValueNotifier propagation ──────────────────────

  group('SyncStateStore.update', () {
    test('persists fields and notifies listeners atomically', () async {
      final updates = <SyncState>[];
      void listener() => updates.add(SyncStateStore.instance.value);
      SyncStateStore.instance.listenable.addListener(listener);

      await SyncStateStore.instance.update(
        (s) => s.copyWith(
          lastAttemptAtIso: '2026-05-01T10:00:00Z',
          lastSuccessAtIso: '2026-05-01T10:00:00Z',
          lastEventCount: 17,
        ),
      );

      // Restart the store from disk and confirm persistence.
      SyncStateStore.instance.resetForTest();
      await SyncStateStore.instance.load();
      final reloaded = SyncStateStore.instance.value;
      expect(reloaded.lastAttemptAtIso, '2026-05-01T10:00:00Z');
      expect(reloaded.lastSuccessAtIso, '2026-05-01T10:00:00Z');
      expect(reloaded.lastEventCount, 17);

      expect(updates, isNotEmpty);
      SyncStateStore.instance.listenable.removeListener(listener);
    });

    test('clearLastErrorClass=true wipes the field', () async {
      await SyncStateStore.instance.update(
        (s) => s.copyWith(lastErrorClass: 'network'),
      );
      expect(SyncStateStore.instance.value.lastErrorClass, 'network');

      await SyncStateStore.instance.update(
        (s) => s.copyWith(clearLastErrorClass: true),
      );
      expect(SyncStateStore.instance.value.lastErrorClass, isNull);
    });
  });

  // ── ValueNotifier identity ─────────────────────────────────────────────────

  test('listenable is the same object across calls', () {
    final a = SyncStateStore.instance.listenable;
    final b = SyncStateStore.instance.listenable;
    expect(identical(a, b), isTrue);
    // ValueListenable is the right contract for ValueListenableBuilder.
    expect(a, isA<ValueListenable<SyncState>>());
  });

  // ── round-2 review regressions ───────────────────────────────────────────

  group('SyncStateStore.migrate handles invalid legacy timestamps', () {
    test('drops a non-ISO last_sync_time label instead of forwarding it',
        () async {
      // Before fix: a "5/1 23:44" display label landed in
      // syncstate_v1_attempt_at and DateTime.tryParse(...) returned
      // null forever afterwards, breaking lastAttemptFailed and the
      // auto-resume throttle.
      SharedPreferences.setMockInitialValues({
        'last_sync_time': '5/1 23:44',
        'last_sync_success': true,
      });
      await SyncStateStore.instance.migrate();
      final state = SyncStateStore.instance.value;
      expect(state.lastAttemptAtIso, isNull,
          reason:
              'a non-ISO display label must NOT be forwarded as a canonical timestamp');
    });

    test('forwards a valid last_sync_iso even when last_sync_time is garbage',
        () async {
      SharedPreferences.setMockInitialValues({
        'last_sync_iso': '2026-04-25T10:00:00.000Z',
        'last_sync_time': '5/1 23:44',
        'last_sync_success': true,
      });
      await SyncStateStore.instance.migrate();
      final state = SyncStateStore.instance.value;
      expect(state.lastAttemptAtIso, '2026-04-25T10:00:00.000Z');
      expect(state.lastSuccessAtIso, '2026-04-25T10:00:00.000Z');
    });
  });

  group('SyncStateStore.clear (logout)', () {
    test('clears the migration-done flag so the next user re-migrates',
        () async {
      SharedPreferences.setMockInitialValues({});
      await SyncStateStore.instance.migrate();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('syncstate_v1_migration_done'), isTrue);

      await SyncStateStore.instance.clear();
      expect(prefs.getBool('syncstate_v1_migration_done'), isNull,
          reason:
              'shared-device user-switch must re-run migration for the new user');
    });

    test('clear() resets the in-memory ValueNotifier (not just disk)',
        () async {
      // Round-3 finding: a future refactor that removes the
      // ``_notifier.value = SyncState.empty`` line would still pass
      // the disk-clear assertion above, but the next user would
      // inherit the previous user's lastSuccessAtIso in memory until
      // a hot restart — phantom "synced X ago" UX.
      SharedPreferences.setMockInitialValues({});
      await SyncStateStore.instance.update(
        (s) => s.copyWith(
          lastSuccessAtIso: '2026-05-01T10:00:00Z',
          lastEventCount: 99,
        ),
      );
      expect(SyncStateStore.instance.value.lastSuccessAtIso, isNotNull);
      expect(SyncStateStore.instance.value.lastEventCount, 99);

      await SyncStateStore.instance.clear();
      expect(SyncStateStore.instance.value.lastSuccessAtIso, isNull,
          reason: 'in-memory state must be wiped on logout, not only disk');
      expect(SyncStateStore.instance.value.lastEventCount, isNull);
      expect(SyncStateStore.instance.value.lastAttemptAtIso, isNull);
    });
  });

  group('SyncStateStore.migrate populates in-memory state on subsequent launches', () {
    test('an already-migrated launch still populates the ValueNotifier',
        () async {
      // Simulate a build that ran migrate() previously (flag set + new
      // schema written).  On the next process start, migrate() must
      // still load the persisted state into memory; otherwise the
      // ValueNotifier sits at SyncState.empty until something triggers
      // a manual load and the home screen reports "never synced".
      SharedPreferences.setMockInitialValues({
        'syncstate_v1_migration_done': true,
        'syncstate_v1_success_at': '2026-04-30T08:00:00Z',
        'syncstate_v1_attempt_at': '2026-04-30T08:00:00Z',
        'syncstate_v1_event_count': 42,
      });
      SyncStateStore.instance.resetForTest();

      await SyncStateStore.instance.migrate();
      final state = SyncStateStore.instance.value;
      expect(state.lastSuccessAtIso, '2026-04-30T08:00:00Z',
          reason:
              'migrate() must hydrate the in-memory state even on the '
              'already-migrated short path');
      expect(state.lastEventCount, 42);
    });
  });
}
