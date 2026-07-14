// SyncTelemetry — Track A's client-side writer.
//
// Every sync attempt (success and failure) emits one record to
// `/api/v1/client-telemetry`.  The server-side schema lives in
// `app/api/v1/client_telemetry.py`; this file just buffers and flushes.
//
// Design constraints:
//
//   * Telemetry MUST NOT block sync.  We fire-and-forget: the sync code
//     calls [SyncTelemetry.record] and immediately moves on.  A network
//     failure on telemetry itself is logged locally and queued.
//
//   * No new heavyweight dependency just for IDs / timestamps.  UUIDv4
//     is a 30-line implementation using `Random.secure()`.  Build /
//     version come from a simple compile-time const that the build
//     pipeline rewrites; package_info_plus would have been one more
//     pubspec dep to manage and the only field that needs platform
//     access is "build" which we already know at build time.
//
//   * Offline buffer.  Records collected while offline are persisted in
//     SharedPreferences so reopening the app drains them.  Cap at 100
//     events — losing old telemetry on a 30-day-offline phone is fine.
//
//   * Idempotency — every event has a UUIDv4 attempt_id.  The server's
//     `(tenant_id, attempt_id)` unique constraint dedupes flushes from
//     the offline queue without inflating failure counts.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Build / version metadata for telemetry.
///
/// Round-8: previously these were ``String.fromEnvironment`` constants
/// fed by ``--dart-define`` from the build script.  That broke whenever
/// Xcode rebuilt the IPA from scratch during the archive step (no
/// defines forwarded → every TestFlight build labelled "dev"), making
/// portal Sync Health useless for distinguishing rollouts.
///
/// New scheme: read ``CFBundleShortVersionString`` and
/// ``CFBundleVersion`` at runtime via ``package_info_plus``.  Same
/// values Xcode and Apple's TestFlight UI surface, so they cannot drift
/// from what the user sees.  The first call seeds an in-memory cache;
/// subsequent calls are synchronous strings.
///
/// The legacy ``kAppVersion`` / ``kAppBuild`` symbols are kept as
/// getters for call-site compatibility.  They return ``"loading"``
/// before [BuildMetadata.ensureLoaded] has been awaited (call this
/// once in ``main()`` before any sync runs); after that they return
/// the real values.
class BuildMetadata {
  static String _version = 'loading';
  static String _build = 'loading';
  static bool _loaded = false;
  static Future<void>? _loadInFlight;

  /// Read CFBundle values at most once.  Idempotent and concurrent-safe:
  /// a second simultaneous call awaits the first.
  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    if (_loadInFlight != null) {
      await _loadInFlight;
      return;
    }
    _loadInFlight = _doLoad();
    try {
      await _loadInFlight;
    } finally {
      _loadInFlight = null;
    }
  }

  static Future<void> _doLoad() async {
    try {
      final info = await PackageInfo.fromPlatform();
      _version = info.version.isNotEmpty ? info.version : 'unknown';
      _build = info.buildNumber.isNotEmpty ? info.buildNumber : 'unknown';
    } catch (e) {
      // package_info_plus throws on a desktop test environment where
      // the platform channel isn't wired.  Fall back to "test" so unit
      // tests can run without mocking; production paths always succeed
      // because main() awaits ensureLoaded() before the first sync.
      _version = 'test';
      _build = 'test';
    } finally {
      _loaded = true;
    }
  }

  static String get version => _version;
  static String get build => _build;

  /// Test-only override.  Lets unit tests pin specific values without
  /// going through the platform channel.
  @visibleForTesting
  static void overrideForTest({String version = 'test', String build = 'test'}) {
    _version = version;
    _build = build;
    _loaded = true;
  }
}

// Legacy top-level getters — every existing call-site like
// ``kAppVersion`` keeps reading the same name and just gets the
// runtime-loaded value instead of the compile-time define.
String get kAppVersion => BuildMetadata.version;
String get kAppBuild => BuildMetadata.build;

/// Logical sync paths the Flutter app drives — must match the server-side
/// allow-list in `client_telemetry.py::_ALLOWED_SYNC_PATHS`.
enum SyncPath { foreground, background, gapFill, historical, other }

extension SyncPathName on SyncPath {
  String get wireValue {
    switch (this) {
      case SyncPath.foreground:
        return 'foreground';
      case SyncPath.background:
        return 'background';
      case SyncPath.gapFill:
        return 'gap_fill';
      case SyncPath.historical:
        return 'historical';
      case SyncPath.other:
        return 'other';
    }
  }
}

/// Event types — must match the server's `_ALLOWED_EVENT_TYPES`.
enum SyncEventType {
  attempt,
  success,
  failure,
  partial,
  clientError,
}

extension SyncEventTypeName on SyncEventType {
  String get wireValue {
    switch (this) {
      case SyncEventType.attempt:
        return 'sync_attempt';
      case SyncEventType.success:
        return 'sync_success';
      case SyncEventType.failure:
        return 'sync_failure';
      case SyncEventType.partial:
        return 'sync_partial';
      case SyncEventType.clientError:
        return 'client_error';
    }
  }
}

/// One telemetry record.  Field names match the server's pydantic schema.
@immutable
class SyncTelemetryEvent {
  final String attemptId;
  final SyncEventType eventType;
  final SyncPath syncPath;
  final String? baseUrl;
  final String? endpoint;
  final int? httpStatus;
  final int? latencyMs;
  final int? eventsSent;
  final int? eventsAccepted;
  final String? anchorBefore;
  final String? anchorAfter;
  final String? errorClass;
  final String? errorMessage;
  final Map<String, Object?>? extra;

  const SyncTelemetryEvent({
    required this.attemptId,
    required this.eventType,
    required this.syncPath,
    this.baseUrl,
    this.endpoint,
    this.httpStatus,
    this.latencyMs,
    this.eventsSent,
    this.eventsAccepted,
    this.anchorBefore,
    this.anchorAfter,
    this.errorClass,
    this.errorMessage,
    this.extra,
  });

  Map<String, Object?> toJson() => {
        'attempt_id': attemptId,
        'event_type': eventType.wireValue,
        'sync_path': syncPath.wireValue,
        'app_version': kAppVersion,
        'app_build': kAppBuild,
        'platform': _platform(),
        if (baseUrl != null) 'base_url': baseUrl,
        if (endpoint != null) 'endpoint': endpoint,
        if (httpStatus != null) 'http_status': httpStatus,
        if (latencyMs != null) 'latency_ms': latencyMs,
        if (eventsSent != null) 'events_sent': eventsSent,
        if (eventsAccepted != null) 'events_accepted': eventsAccepted,
        if (anchorBefore != null) 'anchor_before': anchorBefore,
        if (anchorAfter != null) 'anchor_after': anchorAfter,
        if (errorClass != null) 'error_class': errorClass,
        if (errorMessage != null)
          'error_message': errorMessage!.length > 2000
              ? errorMessage!.substring(0, 2000)
              : errorMessage,
        if (extra != null) 'extra': extra,
      };

  static String _platform() {
    if (kIsWeb) return 'web';
    try {
      if (Platform.isIOS) return 'ios';
      if (Platform.isAndroid) return 'android';
    } catch (_) {
      // Platform unavailable (e.g. unit test on host) — fall through.
    }
    return 'unknown';
  }
}

/// Derive a per-batch attempt_id from a parent root.
///
/// Historical re-sync POSTs many batches (1 per week × 1+ per 2000-event
/// sub-batch).  Each batch needs a distinct ``attempt_id`` so the
/// server's Track D dedup creates a separate SyncLog and enqueues a
/// separate ingestion job — sharing one parent ID across all batches
/// is the round-2 CRITICAL data-loss bug.
///
/// The shape is ``${root}_w${chunkIdx}_b${batchIdx}``.  The TEST suite
/// MUST call this function rather than reproducing the formula
/// locally; otherwise a refactor that changes the shape would pass the
/// test (which is testing its own copy) but break the production
/// dedup contract (round-3 / round-4 review HIGH).
String deriveChunkAttemptId({
  required String root,
  required int chunkIdx,
  required int batchIdx,
}) =>
    '${root}_w${chunkIdx}_b$batchIdx';


/// A small generator that produces RFC 4122-ish v4 UUIDs without a
/// crypto dep.  Sufficient for an idempotency key — collision odds are
/// negligible across the fleet's lifetime.
String newAttemptId() {
  final r = Random.secure();
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant 1
  String hex(int i) => i.toRadixString(16).padLeft(2, '0');
  final b = bytes.map(hex).join();
  return '${b.substring(0, 8)}-${b.substring(8, 12)}-${b.substring(12, 16)}-'
      '${b.substring(16, 20)}-${b.substring(20, 32)}';
}

/// Buffered, fire-and-forget client.  Singleton because the offline
/// queue is global across the process.
class SyncTelemetry {
  SyncTelemetry._();
  static final SyncTelemetry instance = SyncTelemetry._();

  static const _bufferKey = 'sync_telemetry_offline_buffer_v1';
  static const _maxBuffered = 100;
  static const _flushBatchSize = 25;

  /// Resolved at flush time; injected by `HealthService` so this module
  /// stays decoupled from the rest of the app.  If the resolver returns
  /// null the flush is skipped (e.g. user is logged out).
  static Future<({String baseUrl, String token})?> Function()?
      authResolver;

  /// In-memory queue.  Flushed periodically + on event arrival.  Backed
  /// by SharedPreferences so a hard kill doesn't lose events.
  final List<SyncTelemetryEvent> _queue = <SyncTelemetryEvent>[];
  bool _loaded = false;
  bool _flushing = false;
  Timer? _flushTimer;
  Timer? _persistTimer;
  bool _persistDirty = false;

  /// Wire authResolver from app init.
  static void wire({
    required Future<({String baseUrl, String token})?> Function() resolver,
  }) {
    authResolver = resolver;
  }

  /// Record a telemetry event.  Fire-and-forget — never throws to caller.
  Future<void> record(SyncTelemetryEvent event) async {
    try {
      await _ensureLoaded();
      _queue.add(event);
      if (_queue.length > _maxBuffered) {
        _queue.removeRange(0, _queue.length - _maxBuffered);
      }
      // Persistence is debounced (see _schedulePersist).  Earlier
      // revision called ``await _persist()`` synchronously on every
      // event, re-encoding the entire queue (~50 KB at 100 events) to
      // SharedPrefs each time.  During a sync burst (attempt + success
      // pair, plus per-batch retries) that re-write fired 4–5 times in
      // a few hundred ms.
      _schedulePersist();
      _scheduleFlush();
    } catch (e) {
      debugPrint('[SyncTelemetry.record] failed (non-fatal): $e');
    }
  }

  /// Force a flush attempt now.  Useful at app foreground transition.
  Future<void> flushNow() async {
    await _ensureLoaded();
    await _flush();
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_bufferKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
        for (final m in list) {
          _queue.add(_deserialize(m));
        }
      } catch (e) {
        debugPrint('[SyncTelemetry] dropping corrupt offline buffer: $e');
        await prefs.remove(_bufferKey);
      }
    }
    _loaded = true;
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    if (_queue.isEmpty) {
      await prefs.remove(_bufferKey);
      _persistDirty = false;
      return;
    }
    final encoded = jsonEncode(_queue.map((e) => e.toJson()).toList());
    await prefs.setString(_bufferKey, encoded);
    // Clear the dirty flag AFTER the work completes — if a record()
    // arrives mid-await, _schedulePersist will set the flag back to
    // true and arm a fresh timer, which is the correct behaviour.
    _persistDirty = false;
  }

  /// Coalesce SharedPrefs writes within a 2-second window — full re-
  /// encode of the queue each call is what we're trying to avoid.
  /// Persistence happens fast enough that a hard kill in the gap is
  /// vanishingly rare; if the window grows we should switch to a
  /// real append-log instead.
  void _schedulePersist() {
    _persistDirty = true;
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(seconds: 2), () {
      if (_persistDirty) {
        _persist();
      }
    });
  }

  void _scheduleFlush() {
    _flushTimer?.cancel();
    // Coalesce bursts: a 1-second debounce groups the
    // attempt + success pair into one HTTP request.
    _flushTimer = Timer(const Duration(seconds: 1), () async {
      // Make sure the buffer on disk is up to date before we send the
      // network call so an in-flight crash leaves the right state.
      if (_persistDirty) {
        await _persist();
      }
      await _flush();
    });
  }

  Future<void> _flush() async {
    if (_flushing) return;
    if (_queue.isEmpty) return;
    if (authResolver == null) return;

    _flushing = true;
    try {
      final auth = await authResolver!();
      if (auth == null) return;

      while (_queue.isNotEmpty) {
        final batch =
            _queue.take(_flushBatchSize).toList(growable: false);
        final body = jsonEncode({
          'events': batch.map((e) => e.toJson()).toList(),
        });
        try {
          final resp = await http
              .post(
                Uri.parse('${auth.baseUrl}/api/v1/client-telemetry'),
                headers: {
                  'Content-Type': 'application/json',
                  'Authorization': 'Bearer ${auth.token}',
                },
                body: body,
              )
              .timeout(const Duration(seconds: 12));
          if (resp.statusCode == 202 || resp.statusCode == 200) {
            // Server accepted (or deduped) — drop from queue.
            _queue.removeRange(0, batch.length);
            await _persist();
          } else if (resp.statusCode == 401) {
            // Token expired — stop flushing; let the auth flow handle it.
            return;
          } else if (resp.statusCode >= 400 && resp.statusCode < 500) {
            // 4xx (other than 401) means the server permanently
            // rejects this payload — schema mismatch, validation
            // failure, etc.  Retrying changes nothing and would block
            // every following event behind a poison pill.  Drop the
            // batch, log locally, and continue with the rest of the
            // queue.  Without this branch the queue would top out at
            // [_maxBuffered] events forever, evicting NEW telemetry to
            // make room for the same un-flushable head event.
            debugPrint(
              '[SyncTelemetry] dropping ${batch.length} events on '
              'HTTP ${resp.statusCode}: ${resp.body}',
            );
            _queue.removeRange(0, batch.length);
            await _persist();
          } else {
            // 5xx / other transient — keep the queue and try later.
            return;
          }
        } catch (e) {
          // Network blew up — keep the queue, try again on next schedule.
          debugPrint('[SyncTelemetry] flush blocked: $e');
          return;
        }
      }
    } finally {
      _flushing = false;
    }
  }

  static SyncTelemetryEvent _deserialize(Map<String, dynamic> m) {
    SyncEventType evt = SyncEventType.attempt;
    final etRaw = m['event_type'] as String?;
    if (etRaw != null) {
      for (final e in SyncEventType.values) {
        if (e.wireValue == etRaw) {
          evt = e;
          break;
        }
      }
    }
    SyncPath path = SyncPath.other;
    final spRaw = m['sync_path'] as String?;
    if (spRaw != null) {
      for (final p in SyncPath.values) {
        if (p.wireValue == spRaw) {
          path = p;
          break;
        }
      }
    }
    return SyncTelemetryEvent(
      attemptId: m['attempt_id'] as String? ?? newAttemptId(),
      eventType: evt,
      syncPath: path,
      baseUrl: m['base_url'] as String?,
      endpoint: m['endpoint'] as String?,
      httpStatus: m['http_status'] as int?,
      latencyMs: m['latency_ms'] as int?,
      eventsSent: m['events_sent'] as int?,
      eventsAccepted: m['events_accepted'] as int?,
      anchorBefore: m['anchor_before'] as String?,
      anchorAfter: m['anchor_after'] as String?,
      errorClass: m['error_class'] as String?,
      errorMessage: m['error_message'] as String?,
      extra: (m['extra'] as Map?)?.cast<String, Object?>(),
    );
  }

  /// Drain everything: queue, on-disk buffer, in-flight timer.  Called
  /// on logout so pending telemetry for the previous user does not flush
  /// under the next user's JWT.
  Future<void> clear() async {
    _queue.clear();
    _loaded = false;
    _flushing = false;
    _persistDirty = false;
    _flushTimer?.cancel();
    _flushTimer = null;
    _persistTimer?.cancel();
    _persistTimer = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_bufferKey);
  }

  /// Test-only reset.  Identical to [clear] today but kept as a separate
  /// symbol so a future test-only knob (e.g. resetting the static
  /// authResolver, which prod code must NOT touch) lives here.
  @visibleForTesting
  Future<void> resetForTest() async {
    await clear();
    authResolver = null;
  }

  /// Test-only inspection of the full queue contents.
  @visibleForTesting
  List<SyncTelemetryEvent> get queueSnapshot => List.unmodifiable(_queue);

  /// Production-safe queue depth indicator for diagnostics.  Distinct
  /// symbol from [queueSnapshot] so the latter's @visibleForTesting
  /// constraint is preserved while diagnostic dumps stay legal under
  /// `flutter analyze --fatal-warnings`.
  int get pendingEventCount => _queue.length;
}
