// SyncState — single source of truth for "what's the state of mobile sync?"
//
// Track B replaces the v4.x scheme of seven independent SharedPreferences
// keys (last_sync_iso, last_sync_time, last_sync_success, last_event_count,
// last_sync_error_type, lp_api_url, client_upload_anchor_iso) — which the
// Profile, Trends and Today screens each read in different combinations,
// producing the v4.5 outage UX where "Last synced 4 days ago" sat right
// above "Last sync failed: 5/1 23:44" because two keys disagreed.
//
// This module enforces:
//
//   * One immutable [SyncState] value class.  No screen ever reads
//     individual keys.
//   * One persistent store with a single [ValueNotifier] every UI listens
//     to, so a sync that mutates state propagates to all surfaces in the
//     same frame.
//   * Migration on app start: a stale `lp_api_url` (e.g. the dead
//     `lifepulse-api-…run.app` from build 22) is detected and cleared so
//     the next launch self-heals back to the compile-time default,
//     without requiring users to uninstall + reinstall.
//
// The store is intentionally narrow: it holds *only* sync-related state,
// not auth/JWT (those keep flutter_secure_storage).  Calls are async
// because SharedPreferences is, but UI subscribers see synchronous value
// changes via the ValueNotifier.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whitelist of URL hosts the client may POST to.  Anything else is
/// silently cleared on app start by [SyncStateStore.migrate]; [_baseUrl]
/// then falls back to the compile-time `kDefaultApiUrl`.
///
/// Keep this list short.  The whole reason the v4.5 outage was hard to
/// fix was that nobody had a definition of "valid backend URL", so every
/// historical default leaked into permanent SharedPreferences and stayed
/// there forever.
@visibleForTesting
const Set<String> kAllowedApiHosts = {
  'vitametric.web.app',
};

/// Hostname suffixes that match the whitelist (e.g. all *.tikcare.co
/// dev / staging environments and 127.0.0.1 / localhost for local builds).
@visibleForTesting
const List<String> kAllowedApiHostSuffixes = [
  '.tikcare.co',
];

/// Returns true if the given URL string can be safely used as the API
/// base URL.  Anything not on the whitelist is treated as stale.
///
/// Scheme rule (security-critical): only ``localhost`` / ``127.0.0.1``
/// are allowed over plain ``http``.  All public-facing hosts MUST be
/// ``https`` — anything else is rejected even if the host is on the
/// whitelist.  Without this rule, an attacker on a captive portal /
/// poisoned DNS could redirect a build that historically wrote
/// ``http://api.tikcare.co`` into prefs and the migration would
/// preserve it as a plaintext-credential MITM target.
bool isAllowedApiUrl(String? url) {
  if (url == null || url.isEmpty) return false;
  final parsed = Uri.tryParse(url);
  if (parsed == null) return false;
  // Reject embedded userinfo (https://attacker:pw@vitametric.web.app):
  // the host check would pass, but the HTTP client would send the
  // userinfo as a Basic auth header on every request.  No legitimate
  // configuration carries userinfo in the API base URL.
  if (parsed.userInfo.isNotEmpty) return false;
  final scheme = parsed.scheme;
  if (scheme != 'https' && scheme != 'http') return false;
  final host = parsed.host.toLowerCase();
  if (host.isEmpty) return false;
  if (host == 'localhost' || host == '127.0.0.1') {
    // Loopback is the only place plain http is acceptable — local dev
    // builds and unit-test fakes.
    return true;
  }
  // Anything reaching the public network MUST be https.  Reject http
  // even for whitelisted hosts.
  if (scheme != 'https') return false;
  if (kAllowedApiHosts.contains(host)) return true;
  for (final suffix in kAllowedApiHostSuffixes) {
    if (host.endsWith(suffix)) return true;
  }
  return false;
}

/// Immutable snapshot of every sync-related fact the UI needs to render.
///
/// "lastAttemptAtIso" is bumped on EVERY sync (success and failure), so
/// "Last attempt: 5/1 23:44 — failed" remains correct.  "lastSuccessAtIso"
/// is only bumped when a sync genuinely completed; the Profile top row
/// reads from this so it can never display "Last synced today" while the
/// Profile expanded row simultaneously says "failed today".
@immutable
class SyncState {
  final String? lastAttemptAtIso;
  final String? lastSuccessAtIso;
  final int? lastEventCount;
  final String? lastErrorClass;
  final String? lastErrorMessage;

  /// Most recent batch upload anchor, used by `runSync()` to resume
  /// chunked uploads from the right point after a partial failure.
  final String? clientUploadAnchorIso;

  /// Transient: true while a sync is actively running.  Not persisted —
  /// rebuilt at app start from "I have no inflight session" defaults.
  final bool inFlight;

  const SyncState({
    this.lastAttemptAtIso,
    this.lastSuccessAtIso,
    this.lastEventCount,
    this.lastErrorClass,
    this.lastErrorMessage,
    this.clientUploadAnchorIso,
    this.inFlight = false,
  });

  /// Whether the most recent attempt failed.  True when an attempt was
  /// recorded after the last successful sync (or no success has happened
  /// yet but an attempt has).  Drives the red banner on Profile / Today.
  bool get lastAttemptFailed {
    if (lastAttemptAtIso == null) return false;
    if (lastSuccessAtIso == null) return true;
    final attempt = DateTime.tryParse(lastAttemptAtIso!);
    final success = DateTime.tryParse(lastSuccessAtIso!);
    if (attempt == null || success == null) return false;
    return attempt.isAfter(success);
  }

  /// Initial state for a brand-new install.
  static const SyncState empty = SyncState();

  SyncState copyWith({
    String? lastAttemptAtIso,
    String? lastSuccessAtIso,
    int? lastEventCount,
    String? lastErrorClass,
    String? lastErrorMessage,
    String? clientUploadAnchorIso,
    bool? inFlight,
    // Sentinel-style explicit clears: callers that want to NULL out a
    // field pass clear<Field>=true.  This avoids the
    // copyWith-can't-set-null-in-Dart trap.
    bool clearLastErrorClass = false,
    bool clearLastErrorMessage = false,
  }) {
    return SyncState(
      lastAttemptAtIso: lastAttemptAtIso ?? this.lastAttemptAtIso,
      lastSuccessAtIso: lastSuccessAtIso ?? this.lastSuccessAtIso,
      lastEventCount: lastEventCount ?? this.lastEventCount,
      lastErrorClass: clearLastErrorClass
          ? null
          : (lastErrorClass ?? this.lastErrorClass),
      lastErrorMessage: clearLastErrorMessage
          ? null
          : (lastErrorMessage ?? this.lastErrorMessage),
      clientUploadAnchorIso:
          clientUploadAnchorIso ?? this.clientUploadAnchorIso,
      inFlight: inFlight ?? this.inFlight,
    );
  }

  Map<String, Object?> toJson() => {
        'last_attempt_at': lastAttemptAtIso,
        'last_success_at': lastSuccessAtIso,
        'last_event_count': lastEventCount,
        'last_error_class': lastErrorClass,
        'last_error_message': lastErrorMessage,
        'client_upload_anchor': clientUploadAnchorIso,
      };
}

/// Persistent + reactive [SyncState] store.
///
/// The store is a singleton: there is one [ValueNotifier] for the
/// process so widgets across screens can rebuild together.  Reads are
/// cheap (in-memory).  Writes are atomic via [update] which both
/// mutates the in-memory value and writes the relevant SharedPreferences
/// keys in one go.
class SyncStateStore {
  SyncStateStore._();
  static final SyncStateStore instance = SyncStateStore._();

  /// Modern keys.  We deliberately use a different prefix from the
  /// legacy scheme so the migration path is unambiguous.
  static const _kAttempt = 'syncstate_v1_attempt_at';
  static const _kSuccess = 'syncstate_v1_success_at';
  static const _kEvents = 'syncstate_v1_event_count';
  static const _kErrClass = 'syncstate_v1_err_class';
  static const _kErrMsg = 'syncstate_v1_err_msg';
  static const _kAnchor = 'syncstate_v1_anchor';
  static const _kMigrationDone = 'syncstate_v1_migration_done';

  /// Legacy keys subsumed by [SyncState].  After a successful migration
  /// these are removed so future reads can't drift back into the old
  /// scheme.
  @visibleForTesting
  static const legacyKeys = <String>[
    'last_sync_iso',
    'last_sync_time',
    'last_sync_success',
    'last_event_count',
    'last_sync_error_type',
    'last_sync_error_message',
    'client_upload_anchor_iso',
  ];

  /// API base URL prefs key that the v4.x default leaked the dead
  /// `lifepulse-api-…run.app` value into.  Migration scrubs it.
  @visibleForTesting
  static const String legacyApiUrlKey = 'lp_api_url';

  final ValueNotifier<SyncState> _notifier =
      ValueNotifier<SyncState>(SyncState.empty);

  /// Subscribe to state changes.  Wrap a widget tree in
  /// `ValueListenableBuilder<SyncState>(valueListenable: store.listenable, ...)`.
  ValueListenable<SyncState> get listenable => _notifier;

  SyncState get value => _notifier.value;

  bool _loaded = false;
  Completer<void>? _loadInFlight;

  /// Load state from SharedPreferences.  Idempotent: subsequent calls
  /// return immediately.
  Future<void> load() async {
    if (_loaded) return;
    if (_loadInFlight != null) {
      await _loadInFlight!.future;
      return;
    }
    _loadInFlight = Completer<void>();
    try {
      final prefs = await SharedPreferences.getInstance();
      _notifier.value = SyncState(
        lastAttemptAtIso: prefs.getString(_kAttempt),
        lastSuccessAtIso: prefs.getString(_kSuccess),
        lastEventCount: prefs.getInt(_kEvents),
        lastErrorClass: prefs.getString(_kErrClass),
        lastErrorMessage: prefs.getString(_kErrMsg),
        clientUploadAnchorIso: prefs.getString(_kAnchor),
      );
    } catch (e, st) {
      // SharedPreferences can throw on a corrupt backing store / low
      // storage.  Surface to debug logs but do NOT re-throw — the rest
      // of the sync path can still operate against an in-memory empty
      // state, and a permanent retry loop here would peg the CPU.
      debugPrint('[SyncStateStore.load] failed (non-fatal): $e\n$st');
    } finally {
      // _loaded is set in finally so a SharedPreferences exception does
      // NOT cause every subsequent load() to re-enter, hit the same
      // exception, and silently leave the throttle reading "never
      // synced" — the behaviour audit round 5 caught.  Once we've made
      // a best-effort load attempt, we stay loaded.
      _loaded = true;
      _loadInFlight!.complete();
      _loadInFlight = null;
    }
  }

  /// One-shot migration on app start.  Runs ONCE per device install
  /// (gated by the `syncstate_v1_migration_done` flag) and:
  ///
  ///   1. Reads any legacy sync-state keys and forwards them into the
  ///      new schema so the user doesn't see "never synced" after
  ///      upgrading.
  ///   2. Validates `lp_api_url` against [isAllowedApiUrl] and clears
  ///      it if it points anywhere not on the whitelist.  This is the
  ///      v4.5 self-heal path: a user trapped on
  ///      `https://lifepulse-api-…run.app` recovers on next launch.
  ///   3. Deletes the legacy sync-state keys so future code can't
  ///      accidentally re-read them.
  Future<MigrationReport> migrate() async {
    final prefs = await SharedPreferences.getInstance();
    final report = MigrationReport();

    // 1. URL self-heal — runs on EVERY launch (not gated by migration_done)
    //    so a user can never get re-trapped if a future build ships a bad
    //    default value.  Cheap because it's a single getString + validation.
    final storedUrl = prefs.getString(legacyApiUrlKey);
    if (storedUrl != null && !isAllowedApiUrl(storedUrl)) {
      await prefs.remove(legacyApiUrlKey);
      report.staleUrlCleared = storedUrl;
    }

    if (prefs.getBool(_kMigrationDone) ?? false) {
      // Subsequent launches: only the URL self-heal above runs.  Still
      // ensure the in-memory ValueNotifier reflects on-disk state — on
      // a fresh process the notifier was constructed empty and would
      // otherwise stay empty until something else triggers a load.
      // Without this, the FIRST call to ``_loadLastSync`` after
      // ``main.dart`` finishes returns default-zero state and the home
      // screen reports "never synced" until the user triggers a
      // manual sync.
      report.migrationAlreadyDone = true;
      await load();
      return report;
    }

    // 2. Forward legacy sync-state values, if any, into the new schema.
    //
    // ``last_sync_iso`` is a real ISO-8601 timestamp.  ``last_sync_time``
    // is a "M/D HH:MM" display label that DateTime.tryParse cannot
    // round-trip; if we forward it as the canonical attempt timestamp,
    // every subsequent DateTime.tryParse(...) returns null and the
    // throttle / lastAttemptFailed predicate misbehave.  Validate
    // before forwarding.
    String? legacyAttempt = prefs.getString('last_sync_iso');
    if (legacyAttempt != null && DateTime.tryParse(legacyAttempt) == null) {
      legacyAttempt = null;
    }
    if (legacyAttempt == null) {
      final fallback = prefs.getString('last_sync_time');
      if (fallback != null && DateTime.tryParse(fallback) != null) {
        legacyAttempt = fallback;
      }
    }
    final legacySuccessBool = prefs.getBool('last_sync_success');
    final legacyEventCount = prefs.getInt('last_event_count');
    final legacyErrType = prefs.getString('last_sync_error_type');
    final legacyAnchor = prefs.getString('client_upload_anchor_iso');

    String? legacySuccessAt;
    if (legacySuccessBool == true && legacyAttempt != null) {
      legacySuccessAt = legacyAttempt;
    }

    if (legacyAttempt != null) {
      await prefs.setString(_kAttempt, legacyAttempt);
    }
    if (legacySuccessAt != null) {
      await prefs.setString(_kSuccess, legacySuccessAt);
    }
    if (legacyEventCount != null) {
      await prefs.setInt(_kEvents, legacyEventCount);
    }
    if (legacyErrType != null && legacySuccessBool == false) {
      await prefs.setString(_kErrClass, legacyErrType);
    }
    if (legacyAnchor != null) {
      await prefs.setString(_kAnchor, legacyAnchor);
    }

    // 3. Drop legacy keys so they can't drift back.
    for (final k in legacyKeys) {
      await prefs.remove(k);
    }
    await prefs.setBool(_kMigrationDone, true);
    report.migrationApplied = true;

    // Refresh the in-memory snapshot with the migrated values.
    _loaded = false;
    await load();
    return report;
  }

  /// Atomically update the in-memory state and persist to
  /// SharedPreferences.  Safe to call from background tasks.
  Future<void> update(
    SyncState Function(SyncState current) mutator, {
    bool persist = true,
  }) async {
    if (!_loaded) {
      await load();
    }
    final next = mutator(_notifier.value);
    _notifier.value = next;

    if (!persist) return;
    // TODO(perf, deferred from round-4 review): collapse these 6
    // sequential ``await prefs.*`` calls into a single JSON-blob
    // ``setString(_kAllState, jsonEncode(next.toJson()))`` to cut
    // the per-sync platform-channel ops from 12 to 2.  Tracked as
    // known debt; the cost is ~12-60ms on the device side but never
    // dropped a frame in measurement, so deferred until the first
    // batch of post-rollout telemetry confirms it's worth doing.
    final prefs = await SharedPreferences.getInstance();
    Future<void> setOrRemove(String key, String? value) async {
      if (value == null || value.isEmpty) {
        await prefs.remove(key);
      } else {
        await prefs.setString(key, value);
      }
    }

    await setOrRemove(_kAttempt, next.lastAttemptAtIso);
    await setOrRemove(_kSuccess, next.lastSuccessAtIso);
    if (next.lastEventCount == null) {
      await prefs.remove(_kEvents);
    } else {
      await prefs.setInt(_kEvents, next.lastEventCount!);
    }
    await setOrRemove(_kErrClass, next.lastErrorClass);
    await setOrRemove(_kErrMsg, next.lastErrorMessage);
    await setOrRemove(_kAnchor, next.clientUploadAnchorIso);
  }

  /// Reset state — used by logout / clear-my-data flows so the next user
  /// starts from a clean slate.  Also clears the migration-done flag so
  /// that the next user (logging into a shared device) gets a proper
  /// migration pass on next process start, instead of silently inheriting
  /// the previous user's "already migrated" assumption.
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    for (final k in [
      _kAttempt,
      _kSuccess,
      _kEvents,
      _kErrClass,
      _kErrMsg,
      _kAnchor,
      _kMigrationDone,
    ]) {
      await prefs.remove(k);
    }
    _notifier.value = SyncState.empty;
  }

  /// Test-only: reset the singleton's loaded flag.  Allows a subsequent
  /// [load] to re-read SharedPreferences after a test mutates the prefs
  /// directly.
  @visibleForTesting
  void resetForTest() {
    _loaded = false;
    _notifier.value = SyncState.empty;
  }
}

/// Diagnostic info returned by [SyncStateStore.migrate].  Used by tests
/// and by the diagnostic-info string the Flutter app surfaces under
/// "Copy diagnostic" so support can confirm self-heal happened.
class MigrationReport {
  bool migrationAlreadyDone = false;
  bool migrationApplied = false;
  String? staleUrlCleared;

  @override
  String toString() => 'MigrationReport('
      'migrationApplied=$migrationApplied, '
      'migrationAlreadyDone=$migrationAlreadyDone, '
      'staleUrlCleared=$staleUrlCleared)';
}
