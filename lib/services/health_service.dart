import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart'
    show ValueNotifier, debugPrint, kReleaseMode, visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:health/health.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import '../models/health_snapshot.dart';
import '../models/risk_insight.dart';
import '../models/daily_report.dart';
import '../models/anomaly_item.dart';
import '../models/trend_point.dart';
import '../models/reconciliation.dart';
import 'device_lock_channel.dart';
import 'health_mapping.dart' as health_mapping;
import 'sleep_apnea_channel.dart';
import 'sync_accounting.dart';
import 'sync_attempt_history.dart';
import 'sync_state.dart';
import 'sync_telemetry.dart';
import 'vo2max_channel.dart';

// ── Default API config (demo / TestFlight) ───────────────────────────────────
// Default API URL — points at Firebase Hosting for vitametric.web.app, which
// rewrites /api/** and /partner/** to the Cloud Run backend. Falls back to
// the Cloud Run URL directly if Firebase is not yet provisioned.
const kDefaultApiUrl = 'https://vitametric.web.app';
const kTenantSlug = 'tikcare';

/// Connection mode: OW = full chain via Open Wearables (unavailable — SDK removed);
/// Direct = read HealthKit via `health` package, POST to Vitametric Partner API directly.
enum SyncMode { openWearables, direct }

/// Classifies the type of error that occurred during a sync or data fetch.
///
/// deviceLocked: the HealthKit store is file-protected and unreadable while
/// the device is locked — the sync must be retried later, NOT recorded as a
/// successful "up to date" run. healthReadFailed: the HealthKit query itself
/// threw; previously swallowed into an empty list and misreported as success.
enum SyncErrorType {
  network,
  noData,
  serverError,
  authExpired,
  permissionDenied,
  deviceLocked,
  healthReadFailed,
  unknown,
}

class SyncResult {
  final bool success;
  final String message;
  final Map<String, dynamic>? data;
  final SyncErrorType? errorType;
  SyncResult({
    required this.success,
    required this.message,
    this.data,
    this.errorType,
  });
}

/// Core health types supported on all devices (Apple Watch S1+ / most Android).
/// iOS uses HRV_SDNN; Android Health Connect uses HRV_RMSSD.
// Moved verbatim to lib/services/health_mapping.dart (Phase 1.1 extraction)
// as health_mapping.platformSyncTypesIos / platformSyncTypesAndroid — see
// that file for the full doc comments (SLEEP_AWAKE rationale, v3.0 removals)
// which are unchanged.
List<HealthDataType> _platformSyncTypes() => Platform.isIOS
    ? health_mapping.platformSyncTypesIos
    : health_mapping.platformSyncTypesAndroid;

/// Optional types only available on newer hardware or specific accessories.
/// Fetched separately with null-safe handling — missing data is silently ignored.
///
/// Optional types requiring newer hardware or accessories (fetched separately,
/// silently skipped when unavailable).
///
/// Blood pressure: needs a 3rd-party BP cuff app writing to HealthKit.
/// WALKING_SPEED: Apple Watch Series 3+, added in health v13.1.0 (iOS only).
/// APPLE_STAND_TIME: added in health v13.1.1 (iOS only).
///
/// NOT available in health package v13.x:
///   - VO2MAX (HKQuantityTypeIdentifierVO2Max) — read via Vo2MaxChannel (native bridge); not in health plugin v13.x.
///   - SLEEP_APNEA_EVENT (HKCategoryTypeIdentifierApneaEvents) — category type,
///     not wrapped; file export only (Apple Watch S9+, watchOS 10+).
// Moved verbatim to lib/services/health_mapping.dart (Phase 1.1 extraction)
// as health_mapping.optionalSyncTypes.
const _optionalSyncTypes = health_mapping.optionalSyncTypes;


class HealthService {
  // ── Secure credential storage (iOS Keychain / Android Keystore) ───────────
  // JWT tokens and API keys are stored here instead of SharedPreferences to
  // prevent exposure via iCloud backups and on jailbroken/rooted devices.
  static final _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(),
    // firstUnlock: item is accessible after first unlock following a reboot,
    // which is required for WorkManager background syncs that run before the
    // user next opens the app. Without this, background syncs silently fail
    // with an empty token on cold-boot until the user unlocks the device once.
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock,
      // synchronizable: false prevents the JWT from being synced to iCloud
      // Keychain, which would allow the token to be accessible on other devices
      // the user owns. Health data access tokens must be device-local only.
      synchronizable: false,
    ),
  );

  // ── Global sync state ────────────────────────────────────────────────────
  /// True while a syncDirect() call is in flight (any screen).
  /// Prevents the IndexedStack from spawning duplicate syncs when multiple
  /// tabs call syncDirect() simultaneously on first render.
  static Future<SyncResult>? _ongoingSync;
  static bool get isSyncing => _ongoingSync != null;

  /// Fires `true` whenever any API call returns HTTP 401.
  /// Screens can listen and route the user to the login screen.
  static final sessionExpired = ValueNotifier<bool>(false);

  /// Progress label for chunked historical re-sync ("Week 3 of 52").
  /// Null when no historical sync is running.
  static final historicalSyncProgress = ValueNotifier<String?>(null);

  // ── Preference keys ──────────────────────────────────────────────────────
  static const _keyOwUrl = 'ow_api_url';
  static const _keyOwUserId = 'ow_user_id';
  static const _keyOwToken = 'ow_access_token';
  static const _keyLpUrl = 'lp_api_url';
  static const _keyLpApiKey = 'lp_api_key';
  static const _keyLpUserId = 'lp_user_id';
  static const _keySyncMode = 'sync_mode';
  static const _keyRiskInsightCache = 'risk_insight_cache';
  static const _keyJwtToken = 'jwt_token';
  static const _keyLoggedInEmail = 'logged_in_email';
  // Round-17 diagnostic: most recent fetchTodaySnapshot outcome, for
  // Copy Diagnostic to surface what HK actually returned.  Without this,
  // when a tester reports "all metrics show 0/—" we have no way to tell
  // whether HK returned no points (auth/source bug) vs returned points
  // but the widget didn't bind (UI bug).
  static const _keyLastSnapshotDiag = 'last_snapshot_diag';
  // Per-batch upload watermark — advances after every successfully ingested
  // batch (NOT just after a full sync). Defends against partial-failure
  // data loss: when batches 1-3 succeed and batch 4 fails, the server's
  // max-event timestamp may have jumped past events that never made it
  // through. Using this client-side watermark as the floor for the next
  // sync's anchor guarantees we re-query any range we haven't confirmed.
  static const _keyClientUploadAnchor = 'client_upload_anchor_iso';
  // Offline cache keys for reports
  static const _keyCachedDailyReport = 'cached_daily_report';
  static const _keyCachedDailyReportAt = 'cached_daily_report_at';
  static const _keyCachedDailyReportStale = 'cached_daily_report_stale';
  static const _keyCachedRangeReportPrefix = 'cached_range_report_';

  // ── Auth ──────────────────────────────────────────────────────────────────
  static Future<bool> isLoggedIn() async {
    return ((await _secureStorage.read(key: _keyJwtToken)) ?? '').isNotEmpty;
  }

  static Future<String?> getJwtToken() async {
    return _secureStorage.read(key: _keyJwtToken);
  }

  static Future<String?> getLoggedInEmail() async {
    return _secureStorage.read(key: _keyLoggedInEmail);
  }

  /// Compact diagnostic snapshot for testers to copy when sync fails.
  /// Includes everything we'd ask for in a bug report — minus secrets.
  static Future<String> getDiagnosticInfo() async {
    final prefs = await SharedPreferences.getInstance();
    final lpUrl = await _baseUrl();
    final email = await getLoggedInEmail();
    final hasToken = (await _secureStorage.read(key: _keyJwtToken) ?? '').isNotEmpty;

    // Track B: read sync state from SyncStateStore.  The legacy keys
    // (last_sync_iso etc.) are deleted by migrate() on first run of
    // the v5 build, so this used to print "(never)" for every user
    // after upgrading.
    await SyncStateStore.instance.load();
    final state = SyncStateStore.instance.value;
    final lastSyncIso = state.lastSuccessAtIso ?? '(never)';
    final lastAttemptIso = state.lastAttemptAtIso ?? '(never)';
    final lastSuccess =
        state.lastSuccessAtIso != null && !state.lastAttemptFailed;
    final lastErr = state.lastErrorClass ?? '(none)';
    final lastEvents = state.lastEventCount ?? 0;
    final lastDevices =
        (prefs.getStringList('last_sync_devices') ?? []).join(', ');
    final lastException = prefs.getString('last_sync_exception') ?? '(none)';
    final telemetryQueueLen = SyncTelemetry.instance.pendingEventCount;
    // Round-17: surface the most recent fetchTodaySnapshot outcome so a
    // tester reporting "all metrics show 0/—" gives us actionable
    // information.  Without this we couldn't distinguish HK returning
    // no points (auth/source bug) from the widget mis-binding (UI bug).
    final lastSnapDiag =
        prefs.getString(_keyLastSnapshotDiag) ?? '(no snapshot read recorded)';
    return '''
TikCare diagnostic
──────────────────
now: ${DateTime.now().toIso8601String()}
platform: ${Platform.isIOS ? 'iOS' : 'Android'}
app_version: $kAppVersion+$kAppBuild
api: $lpUrl
email: ${email ?? '(none)'}
has_token: $hasToken
last_success_at: $lastSyncIso
last_attempt_at: $lastAttemptIso
last_sync_succeeded: $lastSuccess
last_sync_error: $lastErr
last_event_count: $lastEvents
last_sync_devices: ${lastDevices.isEmpty ? '(none)' : lastDevices}
last_sync_exception: $lastException
telemetry_queue: $telemetryQueueLen
last_snapshot: $lastSnapDiag
''';
  }

  /// Persist the most recent exception text so a tester can paste it via
  /// "Copy diagnostic" — gives us network-layer detail (DNS / TLS / Socket
  /// / Timeout) without requiring a console attached.
  static Future<void> _recordLastSyncException(Object e) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Cap to 200 chars — defensive against gigantic stack traces.
      final msg = e.toString();
      await prefs.setString(
        'last_sync_exception',
        '${DateTime.now().toIso8601String()} ${msg.length > 200 ? "${msg.substring(0, 200)}…" : msg}',
      );
    } catch (_) {/* prefs failure shouldn't cascade */}
  }

  static Future<SyncResult> login({
    required String email,
    required String password,
  }) async {
    final baseUrl = await _baseUrl();
    final prefs = await SharedPreferences.getInstance();

    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/v1/auth/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'tenant_slug': kTenantSlug,
          'email': email,
          'password': password,
        }),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is! Map<String, dynamic>) {
          return SyncResult(success: false, message: 'Unexpected server response. Please try again.');
        }
        final token = decoded['access_token'] as String?;
        final userId = decoded['user_id'] as String?;
        if (token == null || userId == null) {
          return SyncResult(success: false, message: 'Incomplete server response. Please try again.');
        }
        // JWT and email stored in Keychain — not SharedPreferences — to prevent
        // iCloud backup exposure of health-context PII.
        await _secureStorage.write(key: _keyJwtToken, value: token);
        await _secureStorage.write(key: _keyLoggedInEmail, value: email);
        // userId stored in Keychain alongside JWT — it appears in API URL paths
        // and must not be exposed in unencrypted device backups.
        await _secureStorage.write(key: _keyLpUserId, value: userId);
        // Ensure the URL is saved as default
        await prefs.setString(_keyLpUrl, baseUrl);
        return SyncResult(success: true, message: 'Logged in successfully.');
      } else if (response.statusCode == 401) {
        return SyncResult(success: false, message: 'Invalid email or password.');
      } else if (response.statusCode == 400) {
        String? detail;
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is Map<String, dynamic>) detail = decoded['detail'] as String?;
        } catch (_) {}
        return SyncResult(success: false, message: detail ?? 'Invalid request. Please check your input.');
      } else {
        return SyncResult(success: false, message: 'Login failed (HTTP ${response.statusCode}).');
      }
    } on TimeoutException {
      return SyncResult(success: false, message: 'Connection timed out. Please check your network and try again.');
    } catch (e) {
      debugPrint('[HealthService.login] $e');
      return SyncResult(success: false, message: 'Unable to connect. Please check your internet connection.');
    }
  }

  static Future<SyncResult> register({
    required String email,
    required String password,
  }) async {
    final baseUrl = await _baseUrl();
    final prefs = await SharedPreferences.getInstance();

    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/v1/auth/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'tenant_slug': kTenantSlug,
          'email': email,
          'password': password,
        }),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 403) {
        return SyncResult(success: false, message: 'Registration is currently disabled. Please contact your administrator.');
      } else if (response.statusCode == 201) {
        final decoded = jsonDecode(response.body);
        if (decoded is! Map<String, dynamic>) {
          return SyncResult(success: false, message: 'Unexpected server response. Please try again.');
        }
        final token = decoded['access_token'] as String?;
        final userId = decoded['user_id'] as String?;
        if (token == null || userId == null) {
          return SyncResult(success: false, message: 'Incomplete server response. Please try again.');
        }
        await _secureStorage.write(key: _keyJwtToken, value: token);
        await _secureStorage.write(key: _keyLoggedInEmail, value: email);
        await _secureStorage.write(key: _keyLpUserId, value: userId);
        await prefs.setString(_keyLpUrl, baseUrl);
        return SyncResult(success: true, message: 'Account created successfully.');
      } else if (response.statusCode == 409) {
        return SyncResult(success: false, message: 'Email already registered. Please sign in.');
      } else if (response.statusCode == 400) {
        String? raw;
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is Map<String, dynamic>) raw = decoded['detail'] as String?;
        } catch (_) {}
        // Cap to 200 chars to prevent server stack traces or internal field names
        // from being shown verbatim to users.
        final detail = raw != null && raw.length > 200 ? '${raw.substring(0, 200)}…' : raw;
        return SyncResult(success: false, message: detail ?? 'Registration failed.');
      } else {
        return SyncResult(success: false, message: 'Registration failed (HTTP ${response.statusCode}).');
      }
    } on TimeoutException {
      return SyncResult(success: false, message: 'Connection timed out. Please check your network and try again.');
    } catch (e) {
      debugPrint('[HealthService.register] $e');
      return SyncResult(success: false, message: 'Unable to connect. Please check your internet connection.');
    }
  }

  /// Request a password reset token for [email].
  static Future<SyncResult> requestPasswordReset({
    required String email,
  }) async {
    final baseUrl = await _baseUrl();
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/v1/auth/forgot-password'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'tenant_slug': kTenantSlug,
          'email': email,
        }),
      ).timeout(const Duration(seconds: 30));

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return SyncResult(success: false, message: 'Unexpected server response.');
      }
      // Dev/demo: token is returned directly. Production: sent via email.
      final token = decoded['reset_token'] as String?;
      return SyncResult(
        success: true,
        message: decoded['message'] as String? ?? 'Reset token generated.',
        data: token != null ? {'reset_token': token} : null,
      );
    } on TimeoutException {
      return SyncResult(success: false, message: 'Connection timed out. Please try again.');
    } catch (e) {
      debugPrint('[HealthService.requestPasswordReset] $e');
      return SyncResult(success: false, message: 'Unable to connect. Please check your internet connection.');
    }
  }

  /// Reset the password using a valid [token].
  static Future<SyncResult> resetPassword({
    required String token,
    required String newPassword,
  }) async {
    final baseUrl = await _baseUrl();
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/v1/auth/reset-password'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': token,
          'new_password': newPassword,
        }),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        return SyncResult(
          success: true,
          message: (decoded is Map<String, dynamic>)
              ? (decoded['message'] as String? ?? 'Password reset successfully.')
              : 'Password reset successfully.',
        );
      } else {
        String? detail;
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is Map<String, dynamic>) detail = decoded['detail'] as String?;
        } catch (_) {}
        return SyncResult(success: false, message: detail ?? 'Reset failed. Token may be expired.');
      }
    } on TimeoutException {
      return SyncResult(success: false, message: 'Connection timed out. Please try again.');
    } catch (e) {
      debugPrint('[HealthService.resetPassword] $e');
      return SyncResult(success: false, message: 'Unable to connect. Please check your internet connection.');
    }
  }

  static Future<void> logout() async {
    sessionExpired.value = false;
    // Remove sensitive credentials from Keychain
    await _secureStorage.delete(key: _keyJwtToken);
    await _secureStorage.delete(key: _keyOwToken);
    await _secureStorage.delete(key: _keyLpApiKey);
    await _secureStorage.delete(key: _keyLoggedInEmail);
    await _secureStorage.delete(key: _keyLpUserId);
    // clearAllCaches() removes risk insight cache, sync anchor, and all health
    // report caches — no need to remove them individually here first.
    await clearAllCaches();
    await Workmanager().cancelByUniqueName('vitametric.periodicSync');
  }

  /// Removes all locally cached health reports and sync-state flags from
  /// SharedPreferences. Called on logout and can be called independently when
  /// switching accounts or resetting the app.
  ///
  /// NOTE: JWT and API keys live in the Keychain and are NOT cleared here —
  /// they are always cleared explicitly in [logout].
  static Future<void> clearAllCaches() async {
    final prefs = await SharedPreferences.getInstance();
    // Daily report cache
    await prefs.remove(_keyCachedDailyReport);
    await prefs.remove(_keyCachedDailyReportAt);
    await prefs.remove(_keyCachedDailyReportStale);
    // Range report caches (all standard windows)
    for (final days in [7, 30, 90]) {
      final key = '$_keyCachedRangeReportPrefix$days';
      await prefs.remove(key);
      await prefs.remove('${key}_at');
      await prefs.remove('${key}_stale');
    }
    // Sync state flags (written by _doSyncDirect and the home screen)
    await prefs.remove('last_sync_time');
    await prefs.remove('last_sync_success');
    await prefs.remove('last_event_count');
    await prefs.remove('last_sync_devices');
    await prefs.remove('new_device_detected');
    await prefs.remove('last_sync_iso');
    await prefs.remove('last_sync_error_type');
    await prefs.remove(_keyRiskInsightCache);
    // Dismissed anomaly IDs (written by alerts_screen) — cleared on logout so
    // the next user on the same device starts with a clean dismissed set.
    await prefs.remove('dismissed_anomaly_ids');
    // Sync mutex + cursor + last-exception — also user-scoped state.
    // Without these clears, a shared-device user-switch would let user B
    // inherit user A's "sync recently active" mutex and historical-resync
    // cursor, mid-history.  last_sync_exception leaks one user's
    // diagnostic into another's bug report.
    await prefs.remove('sync_in_progress_at');
    await prefs.remove('historical_sync_cursor');
    await prefs.remove('last_sync_exception');
    // Track B SyncStateStore — must be wiped on logout. Without this the
    // ValueNotifier in memory and the syncstate_v1_* keys persist across
    // user switches, leaking the previous user's lastSuccessAt + anchor
    // into the next user's session. The migration flag (_kMigrationDone)
    // is also reset implicitly because clear() is followed by a fresh
    // login flow which only re-runs migrate() on the next process start;
    // the next user is a clean slate from SyncStateStore's perspective.
    await SyncStateStore.instance.clear();
    // Drain the offline telemetry buffer too — pending events for the
    // logged-out user must not flush under the next user's JWT.
    await SyncTelemetry.instance.clear();
  }

  /// Register a background sync task that fires every 6 hours.
  /// Must be called after login and register so the task persists even when
  /// the user doesn't open the app.
  ///
  /// uniqueName MUST equal the BGTask identifier from Info.plist
  /// (BGTaskSchedulerPermittedIdentifiers): on iOS workmanager submits
  /// BGAppRefreshTaskRequest(identifier: uniqueName), so the old
  /// 'periodicHealthSync' uniqueName was rejected by BGTaskScheduler on
  /// every submit and the background sync never got scheduled.
  static Future<void> registerBackgroundSync() async {
    await Workmanager().registerPeriodicTask(
      'vitametric.periodicSync',
      'vitametric.periodicSync',
      frequency: const Duration(hours: 6),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      constraints: Constraints(networkType: NetworkType.connected),
    );
  }

  // ── Config accessors ─────────────────────────────────────────────────────
  static Future<SyncMode> getSyncMode() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keySyncMode) ?? 'direct';
    return raw == 'direct' ? SyncMode.direct : SyncMode.openWearables;
  }

  static Future<Map<String, String>> getConfig() async {
    final prefs = await SharedPreferences.getInstance();
    // owToken and lpApiKey are credentials — read from Keychain
    final owToken = await _secureStorage.read(key: _keyOwToken) ?? '';
    final lpApiKey = await _secureStorage.read(key: _keyLpApiKey) ?? '';
    return {
      'owUrl': prefs.getString(_keyOwUrl) ?? '',
      'owUserId': prefs.getString(_keyOwUserId) ?? '',
      'owToken': owToken,
      'lpUrl': prefs.getString(_keyLpUrl) ?? '',
      'lpApiKey': lpApiKey,
      'lpUserId': (await _secureStorage.read(key: _keyLpUserId)) ?? '',
      'syncMode': prefs.getString(_keySyncMode) ?? 'direct',
    };
  }

  static Future<void> saveConfig(Map<String, String> cfg) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyOwUrl, cfg['owUrl'] ?? '');
    await prefs.setString(_keyOwUserId, cfg['owUserId'] ?? '');
    await _secureStorage.write(key: _keyOwToken, value: cfg['owToken'] ?? '');
    await prefs.setString(_keyLpUrl, cfg['lpUrl'] ?? '');
    await _secureStorage.write(key: _keyLpApiKey, value: cfg['lpApiKey'] ?? '');
    await _secureStorage.write(key: _keyLpUserId, value: cfg['lpUserId'] ?? '');
    await prefs.setString(_keySyncMode, cfg['syncMode'] ?? 'direct');
  }

  // ── Health plugin configuration guard ─────────────────────────────────────
  static bool _healthConfigured = false;

  /// Ensures the health package is configured before any HealthKit/HC call.
  /// Safe to call multiple times — only configures once per isolate.
  /// Public so main.dart can call it at startup to set the flag.
  static Future<void> ensureHealthConfigured() async {
    if (!_healthConfigured) {
      await Health().configure();
      _healthConfigured = true;
    }
  }

  // ── Open Wearables path (unavailable) ────────────────────────────────────
  static Future<bool> requestPermissions() async {
    await ensureHealthConfigured();
    // On Android, Health Connect must be available before requesting permissions.
    if (Platform.isAndroid) {
      final status = await Health().getHealthConnectSdkStatus();
      if (status != HealthConnectSdkStatus.sdkAvailable) {
        return false; // Caller should surface the install prompt to the user.
      }
    }
    // Request ALL types that _doSyncDirect() uses — core (includes sleep stages) + optional.
    final coreTypes = _platformSyncTypes();
    final allTypes = [...coreTypes, ..._optionalSyncTypes];
    final granted = await Health().requestAuthorization(allTypes);
    // VO2_MAX and SLEEP_APNEA_EVENT are read via native bridges outside the
    // health plugin, so their HealthKit authorization must be requested
    // separately — here, in the foreground, where iOS can actually present
    // the sheet. Additive only: a denial must not fail the overall grant.
    if (Platform.isIOS) {
      await Vo2MaxChannel.requestAuthorization();
      await SleepApneaChannel.requestAuthorization();
    }
    return granted;
  }

  /// Probes whether the app can actually read health data from the platform.
  /// On iOS, requestAuthorization() always returns true (Apple privacy policy),
  /// so the only reliable way to detect permission denial is to attempt a read.
  /// Uses a 7-day window to reduce false negatives on day-zero devices.
  ///
  /// NOTE: On a brand-new device with zero activity, this may return false
  /// even if permissions are granted. This is an iOS limitation — Apple does
  /// not expose read authorization status. Callers should treat false as
  /// "likely denied" not "definitely denied".
  static Future<bool> canReadHealthData() async {
    try {
      await ensureHealthConfigured();
      final now = DateTime.now();
      // Use 7-day window: even brand-new iPhones passively record steps,
      // so a 7-day window with zero data strongly suggests permission denial.
      final data = await Health().getHealthDataFromTypes(
        types: const [HealthDataType.STEPS],
        startTime: now.subtract(const Duration(days: 7)),
        endTime: now,
      );
      return data.isNotEmpty;
    } on Exception catch (e) {
      // Only treat HealthKit/platform errors as permission denial.
      // Re-throw unexpected errors so callers don't confuse a network
      // issue with a permission problem.
      debugPrint('[HealthService.canReadHealthData] $e');
      return false;
    }
  }

  /// Returns true if Health Connect is installed and available on Android.
  /// Always returns true on iOS (HealthKit is always available).
  static Future<bool> isHealthConnectAvailable() async {
    if (!Platform.isAndroid) return true;
    await ensureHealthConfigured();
    final status = await Health().getHealthConnectSdkStatus();
    return status == HealthConnectSdkStatus.sdkAvailable;
  }

  /// Redirects the user to the Play Store to install Health Connect.
  /// Only meaningful on Android when Health Connect is not installed.
  static Future<void> promptInstallHealthConnect() async {
    if (Platform.isAndroid) {
      await Health().installHealthConnect();
    }
  }

  // ── Device brand detection ─────────────────────────────────────────────────
  static const _keyDetectedBrand = 'detected_device_brand';
  static const _keyDetectedSources = 'detected_source_names';

  /// Bundle-ID prefix → brand mapping (mirrors backend device_resolver.py).
  static const _bundleBrandMap = <String, String>{
    'com.apple.health': 'Apple',
    'com.garmin.connect': 'Garmin',
    'com.fitbit': 'Fitbit',
    'com.ouraring': 'Oura',
    'com.polar': 'Polar',
    'com.samsung.health': 'Samsung',
    'com.huawei.health': 'Huawei',
    'com.xiaomi': 'Xiaomi',
    'com.withings': 'Withings',
    'com.whoop': 'Whoop',
  };

  /// HealthKit device names embed a non-breaking space (U+00A0): the real
  /// `sourceName` is "Poi Ki’s Apple\u{00A0}Watch", so a plain
  /// `contains('apple watch')` never matches. Fold U+00A0 and any run of
  /// whitespace to a single ASCII space before keyword matching.
  @visibleForTesting
  static String normalizeSourceName(String raw) => raw
      .toLowerCase()
      .replaceAll('\u00A0', ' ') // NBSP -> ASCII space
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// Keyword fallback when sourceId is unhelpful.
  /// Keys must be matched against [normalizeSourceName], not the raw value.
  static const _keywordBrandMap = <String, String>{
    'apple watch': 'Apple',
    'garmin': 'Garmin',
    'connect': 'Garmin',
    'fitbit': 'Fitbit',
    'oura': 'Oura',
    'polar': 'Polar',
    'samsung': 'Samsung',
    'huawei': 'Huawei',
    'whoop': 'Whoop',
    'withings': 'Withings',
  };

  /// Detects the primary wearable brand by reading recent HR data sources
  /// from HealthKit. Caches result in SharedPreferences.
  /// Returns the brand name ("Apple", "Garmin", etc.) or null if unknown.
  static Future<String?> detectDeviceBrand({bool forceRefresh = false}) async {
    if (!forceRefresh) {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(_keyDetectedBrand);
      if (cached != null) return cached.isEmpty ? null : cached;
    }

    try {
      await ensureHealthConfigured();
      final now = DateTime.now();
      // Query multiple types together — iOS HealthKit can return empty for
      // single-type queries but succeeds with combined multi-type requests.
      final data = await Health().getHealthDataFromTypes(
        types: [
          HealthDataType.HEART_RATE,
          HealthDataType.STEPS,
          HealthDataType.BLOOD_OXYGEN,
        ],
        startTime: now.subtract(const Duration(days: 7)),
        endTime: now,
      );

      // Collect unique sourceId + sourceName pairs
      final brands = <String>{};
      for (final p in data) {
        // Try bundle ID first
        final id = p.sourceId.toLowerCase();
        for (final entry in _bundleBrandMap.entries) {
          if (id.startsWith(entry.key)) {
            brands.add(entry.value);
            break;
          }
        }
        // Keyword fallback on sourceName. Must go through normalizeSourceName:
        // HealthKit writes "Apple Watch" with a non-breaking space.
        if (brands.isEmpty) {
          final name = normalizeSourceName(p.sourceName);
          for (final entry in _keywordBrandMap.entries) {
            if (name.contains(entry.key)) {
              brands.add(entry.value);
              break;
            }
          }
        }
      }

      // Pick the wearable brand (prefer non-Apple if both exist,
      // because iPhone also writes HR data passively).
      String? primary;
      if (brands.length == 1) {
        primary = brands.first;
      } else if (brands.length > 1) {
        // If we see both Apple and a 3rd-party, the 3rd-party is the wearable
        final nonApple = brands.where((b) => b != 'Apple').toList();
        primary = nonApple.isNotEmpty ? nonApple.first : brands.first;
      }

      // Cache result
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyDetectedBrand, primary ?? '');
      await prefs.setStringList(
        _keyDetectedSources,
        data.map((p) => p.sourceName).toSet().toList(),
      );

      return primary;
    } catch (e) {
      debugPrint('[HealthService.detectDeviceBrand] $e');
      return null;
    }
  }

  /// Returns the cached brand without re-querying HealthKit.
  static Future<String?> getCachedDeviceBrand() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_keyDetectedBrand);
    return (cached == null || cached.isEmpty) ? null : cached;
  }

  /// Returns device-specific hint for a metric that shows "—".
  /// If brand is known, gives actionable advice; otherwise generic.
  static String metricHint(String metric, String? brand) {
    switch (metric) {
      case 'hrv':
        if (brand == 'Garmin') return 'Garmin does not sync HRV to Apple Health';
        if (brand == 'Fitbit') return 'Fitbit does not sync HRV to Apple Health';
        return 'Requires a wearable that writes HRV to Health';
      case 'hr':
        if (brand == 'Garmin') return 'Check Garmin Connect → Health sync';
        if (brand != null) return 'Check $brand → Health sync';
        return 'Requires a wearable syncing to Health';
      case 'rhr':
        if (brand == 'Garmin') return 'Check Garmin Connect → Health sync';
        return 'Requires a wearable syncing to Health';
      case 'spo2':
        if (brand == 'Garmin') return 'Check if your Garmin model supports SpO₂ → Health';
        return 'Requires a device with SpO₂ sensor';
      case 'resp':
        if (brand == 'Garmin') return 'Garmin does not sync Resp Rate to Health';
        return 'Requires Apple Watch Series 6+';
      case 'exercise':
        if (brand == 'Garmin') return 'Check Garmin Connect → Health sync';
        return 'Start a workout on your wearable';
      case 'sleep':
        if (brand == 'Garmin') return 'Enable sleep tracking in Garmin Connect → Health';
        return 'Enable sleep tracking on your wearable';
      case 'bp':
        return 'Requires a BP monitor app syncing to Health';
      case 'afib':
        return 'Requires Apple Watch with AFib detection';
      default:
        return 'Requires a compatible wearable';
    }
  }

  static Future<SyncResult> syncViaOW({
    void Function(String)? onLog,
  }) async {
    onLog?.call('⚠️  Open Wearables sync path is not available in this build.');
    onLog?.call('   Switch to Direct mode in Config to sync via Vitametric Partner API.');
    return SyncResult(
      success: false,
      message: 'OW sync path unavailable. Use Direct mode.',
    );
  }

  // ── Local HealthKit snapshot (rolling 24h, latest reading per metric) ──
  /// Reads recent HealthKit data and returns a local snapshot for immediate
  /// display. Does NOT require the Vitametric server to be reachable.
  ///
  /// Bug fix (v4.6): used to filter by "today since midnight". At 00:31 the
  /// user just rolled into a new day, no readings yet → all tiles showed
  /// empty even though Apple Health had yesterday's data 30 minutes earlier.
  /// Switched HR / HRV / SpO2 / Resp to a rolling 24h "latest reading" model.
  /// Steps remain a daily SUM but fall back to the most recent 24h window
  /// when the calendar-day count is suspiciously small near midnight.
  static Future<HealthSnapshot> fetchTodaySnapshot() async {
    try {
      await ensureHealthConfigured();
      // Permissions are requested once in syncDirect(). Here we just read
      // whatever the OS allows without showing another authorization dialog.

      final now = DateTime.now();
      final startOfDay = DateTime(now.year, now.month, now.day);

      // Lookback strategy (v4.5 redesign — split from analytics path):
      //   * Latest-reading metrics use a 30-day window so we can show "yesterday
      //     8:17pm — 76 bpm" with a freshness label, the way Apple Health does.
      //     The previous 24h hard cutoff dropped any reading older than a day,
      //     leaving the tile blank whenever a user took the watch off overnight.
      //   * Steps and Exercise stay rooted at local midnight — those reset
      //     daily in Apple Fitness rings and we keep parity.
      //   * Sleep keeps the yesterday-18:00 anchor so segments that span
      //     midnight attribute to the right night.
      const _displayLookbackDays = 30;
      final displayStart = now.subtract(const Duration(days: _displayLookbackDays));
      final last7d = now.subtract(const Duration(days: 7));

      // iOS uses SDNN; Android Health Connect only supports RMSSD.
      final hrvType = Platform.isIOS
          ? HealthDataType.HEART_RATE_VARIABILITY_SDNN
          : HealthDataType.HEART_RATE_VARIABILITY_RMSSD;
      final sleepTypes = Platform.isIOS
          ? const [HealthDataType.SLEEP_IN_BED, HealthDataType.SLEEP_ASLEEP,
                   HealthDataType.SLEEP_DEEP, HealthDataType.SLEEP_REM, HealthDataType.SLEEP_LIGHT]
          : const [HealthDataType.SLEEP_SESSION, HealthDataType.SLEEP_DEEP,
                   HealthDataType.SLEEP_REM, HealthDataType.SLEEP_LIGHT];

      // Query ALL types in a SINGLE call. Combined queries side-step an iOS
      // health-plugin bug where per-type queries silently return empty while
      // the combined version returns the same authorized data correctly.
      //
      // Round-17: STEPS added so the raw samples are available as a fallback
      // when ``getTotalStepsInInterval`` (HKStatisticsQuery) returns 0 in
      // edge cases — multi-source attribution where the priority source
      // recorded nothing today, very recent samples not yet indexed by
      // statistics, or wasUserEntered=true samples excluded by predicate.
      final allTypes = [
        HealthDataType.HEART_RATE,
        hrvType,
        HealthDataType.RESTING_HEART_RATE,
        HealthDataType.BLOOD_OXYGEN,
        HealthDataType.EXERCISE_TIME,
        HealthDataType.RESPIRATORY_RATE,
        HealthDataType.BLOOD_PRESSURE_SYSTOLIC,
        HealthDataType.BLOOD_PRESSURE_DIASTOLIC,
        HealthDataType.ATRIAL_FIBRILLATION_BURDEN,
        HealthDataType.STEPS,
        ...sleepTypes,
      ];

      // Steps use HKStatisticsQuery (source-deduplicated aggregate, today only).
      final stepsFuture = Health()
          .getTotalStepsInInterval(startOfDay, now)
          .catchError((_) => null as int?);

      // Single combined query covering 30 days — enough to surface stale
      // readings while still completing in well under 200ms on real devices
      // (HK has internal indexes; we filter in Dart afterward).
      List<HealthDataPoint> rawPoints;
      String? snapshotReadError;
      try {
        rawPoints = await Health().getHealthDataFromTypes(
          types: allTypes,
          startTime: displayStart,
          endTime: now,
        );
      } catch (e) {
        // Round-17: capture the error text so getDiagnosticInfo() can
        // surface it.  Pre-fix the error went to debugPrint only and
        // testers had no visibility — every metric silently showed 0/—.
        snapshotReadError = e.toString();
        debugPrint('[Snapshot] getHealthDataFromTypes failed: $e');
        rawPoints = [];
      }

      final deduped = Health().removeDuplicates(rawPoints);
      final statsSteps = await stepsFuture;

      // Diagnostic: log what HealthKit returned per data type.
      final snapshotTypeCounts = <String, int>{};
      for (final p in deduped) {
        snapshotTypeCounts[p.type.name] = (snapshotTypeCounts[p.type.name] ?? 0) + 1;
      }
      debugPrint('[Snapshot] HealthKit returned ${deduped.length} points: ${snapshotTypeCounts.entries.map((e) => '${e.key}=${e.value}').join(', ')}');
      debugPrint('[Snapshot] Steps via HKStatisticsQuery: $statsSteps');

      // Round-17: steps fallback.  HKStatisticsQuery (used by
      // getTotalStepsInInterval) can return 0 in edge cases even when
      // Apple Health UI clearly shows non-zero steps for today —
      // multi-source attribution, very recent samples not yet indexed,
      // or wasUserEntered=true samples excluded by default predicate.
      // When that happens, sum the raw STEPS samples we already pulled
      // in the combined query and take whichever is larger.
      int? fallbackSteps;
      final stepSamples = deduped
          .where((p) => p.type == HealthDataType.STEPS && !p.dateFrom.isBefore(startOfDay))
          .where((p) => p.value is NumericHealthValue)
          .toList();
      if (stepSamples.isNotEmpty) {
        final sum = stepSamples.fold<double>(
          0,
          (acc, p) => acc + (p.value as NumericHealthValue).numericValue.toDouble(),
        );
        fallbackSteps = sum.round();
      }
      final totalSteps = (statsSteps ?? 0) >= (fallbackSteps ?? 0)
          ? statsSteps
          : fallbackSteps;
      debugPrint(
          '[Snapshot] Steps resolved: stats=$statsSteps fallback=$fallbackSteps -> $totalSteps');

      // Round-17: persist a compact diagnostic blob so getDiagnosticInfo()
      // can surface what HK returned — without this, a "metrics show 0"
      // bug report from a tester is ungrep-able.  Cap the dump at 600 chars
      // (SharedPreferences value limit is generous but we keep it tight).
      try {
        final prefsForDiag = await SharedPreferences.getInstance();
        final summary = snapshotReadError != null
            ? 'ERROR: ${snapshotReadError.length > 200 ? snapshotReadError.substring(0, 200) : snapshotReadError}'
            : 'OK total=${deduped.length} ${snapshotTypeCounts.entries.map((e) => '${e.key}=${e.value}').join(',')}';
        final blob =
            '${now.toIso8601String()} | window=${_displayLookbackDays}d | steps_stats=$statsSteps fallback=$fallbackSteps -> $totalSteps | $summary';
        await prefsForDiag.setString(_keyLastSnapshotDiag,
            blob.length > 600 ? blob.substring(0, 600) : blob);
      } catch (_) {
        // Diagnostic write is best-effort — never block snapshot.
      }

      // Sleep window — sleep segments straddle midnight so we look back to
      // yesterday 18:00 to capture the full prior night.
      final sleepStart = startOfDay.subtract(const Duration(hours: 6));

      // Helper: filter deduped points by type and time window.
      List<HealthDataPoint> _filter(HealthDataType type, DateTime from) =>
          deduped.where((p) => p.type == type && !p.dateFrom.isBefore(from)).toList();

      // Helper: latest numeric reading of [type] over the 30-day display window
      // — returns (value, sampleAt) so the tile can show an age label. No time
      // cutoff: if the freshest sample is 12 days old, we still show it with
      // "12 days ago", just like Apple Health.
      ({double value, DateTime at})? _latestNumeric(HealthDataType type) {
        final pts = _filter(type, displayStart)
            .where((p) => p.value is NumericHealthValue)
            .toList()
          ..sort((a, b) => b.dateFrom.compareTo(a.dateFrom));
        if (pts.isEmpty) return null;
        return (
          value: (pts.first.value as NumericHealthValue).numericValue.toDouble(),
          at: pts.first.dateFrom,
        );
      }

      // Determine primary HR source from the last 7 days of HR data — recent
      // enough to reflect the user's current device, broad enough to survive
      // a day or two of not wearing the watch.
      final last7dHr = _filter(HealthDataType.HEART_RATE, last7d);
      String? primarySource;
      if (last7dHr.isNotEmpty) {
        final sourceCounts = <String, int>{};
        for (final p in last7dHr) {
          sourceCounts[p.sourceName] = (sourceCounts[p.sourceName] ?? 0) + 1;
        }
        primarySource = sourceCounts.entries
            .reduce((a, b) => a.value >= b.value ? a : b)
            .key;
      }
      final noHrLast7Days = last7dHr.isEmpty;

      // Latest HR — over the full 30-day window, primary-source filtered.
      // No 24h cutoff: a watch left on the charger overnight should still
      // surface yesterday's reading instead of going blank.
      final hrPoints = _filter(HealthDataType.HEART_RATE, displayStart)
          .where((p) =>
              p.value is NumericHealthValue &&
              (primarySource == null || p.sourceName == primarySource))
          .toList()
        ..sort((a, b) => b.dateFrom.compareTo(a.dateFrom));
      final double? latestHr = hrPoints.isEmpty
          ? null
          : (hrPoints.first.value as NumericHealthValue).numericValue.toDouble();
      final DateTime? hrSampleAt = hrPoints.isEmpty ? null : hrPoints.first.dateFrom;

      // HRV: latest SDNN/RMSSD in the 30-day window.
      final hrvLatest = _latestNumeric(hrvType);
      final double? latestHrv = hrvLatest?.value;
      final DateTime? hrvSampleAt = hrvLatest?.at;

      // Sleep: yesterday 18:00 → now. DEEP+REM+LIGHT, fallback SLEEP_ASLEEP.
      const stageTypes = {
        HealthDataType.SLEEP_DEEP,
        HealthDataType.SLEEP_REM,
        HealthDataType.SLEEP_LIGHT,
      };
      final allSleepPoints = deduped.where((p) =>
          sleepTypes.contains(p.type) && !p.dateFrom.isBefore(sleepStart)).toList();
      final stagePoints = allSleepPoints.where((p) => stageTypes.contains(p.type)).toList();
      final asleepPoints = allSleepPoints.where((p) => p.type == HealthDataType.SLEEP_ASLEEP).toList();
      final sleepPoints = stagePoints.isNotEmpty ? stagePoints : asleepPoints;
      double sleepSec = 0;
      for (final p in sleepPoints) {
        sleepSec += p.dateTo.difference(p.dateFrom).inSeconds;
      }
      final sleepHours = sleepPoints.isEmpty ? null : sleepSec / 3600.0;

      // Per-stage minutes for the Sleep tile breakdown. Only populated when
      // granular DEEP/REM/LIGHT data is present (newer Apple Watch / Health
      // Connect); a SLEEP_ASLEEP-only night leaves these null and the tile
      // falls back to showing the total alone.
      int stageMinutes(HealthDataType t) {
        if (stagePoints.isEmpty) return 0;
        double sec = 0;
        for (final p in stagePoints.where((p) => p.type == t)) {
          sec += p.dateTo.difference(p.dateFrom).inSeconds;
        }
        return (sec / 60).round();
      }
      final deepMin  = stagePoints.isEmpty ? null : stageMinutes(HealthDataType.SLEEP_DEEP);
      final remMin   = stagePoints.isEmpty ? null : stageMinutes(HealthDataType.SLEEP_REM);
      final lightMin = stagePoints.isEmpty ? null : stageMinutes(HealthDataType.SLEEP_LIGHT);

      // SpO2 / RHR / RespRate / BP / AFib — all use the 30-day display window
      // and surface the latest sample with its timestamp. Apple Health does the
      // same: a single weekly cuff reading or yesterday's RHR shouldn't blank
      // the tile.
      final spo2Latest = _latestNumeric(HealthDataType.BLOOD_OXYGEN);
      final double? latestSpo2 = spo2Latest == null ? null : spo2Latest.value * 100;
      final DateTime? spo2SampleAt = spo2Latest?.at;

      final rhrLatest = _latestNumeric(HealthDataType.RESTING_HEART_RATE);
      final double? latestRhr = rhrLatest?.value;
      final DateTime? rhrSampleAt = rhrLatest?.at;

      final respLatest = _latestNumeric(HealthDataType.RESPIRATORY_RATE);
      final double? latestRespRate = respLatest?.value;
      final DateTime? respRateSampleAt = respLatest?.at;

      final bpSysLatest = _latestNumeric(HealthDataType.BLOOD_PRESSURE_SYSTOLIC);
      final bpDiaLatest = _latestNumeric(HealthDataType.BLOOD_PRESSURE_DIASTOLIC);
      // BP is paired — use the older of the two timestamps so the age label
      // doesn't claim freshness based on only one half of the reading.
      final DateTime? bpSampleAt = (bpSysLatest != null && bpDiaLatest != null)
          ? (bpSysLatest.at.isBefore(bpDiaLatest.at) ? bpSysLatest.at : bpDiaLatest.at)
          : (bpSysLatest?.at ?? bpDiaLatest?.at);

      final afibLatest = _latestNumeric(HealthDataType.ATRIAL_FIBRILLATION_BURDEN);
      final bool? afibDetected = afibLatest == null ? null : afibLatest.value > 0;
      final DateTime? afibSampleAt = afibLatest?.at;

      // Exercise Time: midnight-reset daily count, parity with Apple Fitness.
      final exerciseMin = _filter(HealthDataType.EXERCISE_TIME, startOfDay)
          .where((p) => p.value is NumericHealthValue)
          .fold<double>(0, (acc, p) =>
              acc + (p.value as NumericHealthValue).numericValue.toDouble());
      final exerciseMinDisplay = exerciseMin == 0 ? null : exerciseMin.round();

      return HealthSnapshot(
        latestHr: latestHr != null ? double.parse(latestHr.toStringAsFixed(0)) : null,
        hrSampleAt: hrSampleAt,
        hrv: latestHrv != null ? double.parse(latestHrv.toStringAsFixed(0)) : null,
        hrvSampleAt: hrvSampleAt,
        rhr: latestRhr != null ? double.parse(latestRhr.toStringAsFixed(0)) : null,
        rhrSampleAt: rhrSampleAt,
        spo2: latestSpo2 != null ? double.parse(latestSpo2.toStringAsFixed(1)) : null,
        spo2SampleAt: spo2SampleAt,
        respRate: latestRespRate != null ? double.parse(latestRespRate.toStringAsFixed(1)) : null,
        respRateSampleAt: respRateSampleAt,
        bpSystolic: bpSysLatest != null ? double.parse(bpSysLatest.value.toStringAsFixed(0)) : null,
        bpDiastolic: bpDiaLatest != null ? double.parse(bpDiaLatest.value.toStringAsFixed(0)) : null,
        bpSampleAt: bpSampleAt,
        afibDetected: afibDetected,
        afibSampleAt: afibSampleAt,
        steps: totalSteps,
        exerciseMin: exerciseMinDisplay,
        sleepHours: sleepHours != null ? double.parse(sleepHours.toStringAsFixed(1)) : null,
        sleepDeepMin: deepMin,
        sleepRemMin: remMin,
        sleepLightMin: lightMin,
        fetchedAt: now,
        primarySource: primarySource,
        noHrLast7Days: noHrLast7Days,
      );
    } catch (e) {
      debugPrint('[HealthService.fetchTodaySnapshot] $e');
      return HealthSnapshot(fetchedAt: DateTime.now());
    }
  }

  // ── Local HealthKit metric history (offline, multi-day) ─────────────────
  /// Fetches daily metric aggregates for the past [days] days from HealthKit.
  /// Uses local HealthKit data (no network) for fast chart rendering.
  static Future<List<DailyMetricPoint>> fetchMetricHistory({required int days}) async {
    try {
      await ensureHealthConfigured();
      final now = DateTime.now();
      final startTime = DateTime(now.year, now.month, now.day)
          .subtract(Duration(days: days - 1));

      final hrvType = Platform.isIOS
          ? HealthDataType.HEART_RATE_VARIABILITY_SDNN
          : HealthDataType.HEART_RATE_VARIABILITY_RMSSD;

      final sleepTypes = Platform.isIOS
          ? [HealthDataType.SLEEP_DEEP, HealthDataType.SLEEP_REM, HealthDataType.SLEEP_LIGHT,
             HealthDataType.SLEEP_ASLEEP]
          : [HealthDataType.SLEEP_DEEP, HealthDataType.SLEEP_REM, HealthDataType.SLEEP_LIGHT,
             HealthDataType.SLEEP_SESSION];

      // Query ALL types in a SINGLE call to avoid an iOS health plugin issue
      // where individual-type queries silently return empty. The sync function
      // uses one combined call and works — match that pattern here.
      final allTypes = [
        HealthDataType.HEART_RATE,
        hrvType,
        HealthDataType.STEPS,
        HealthDataType.RESTING_HEART_RATE,
        HealthDataType.BLOOD_OXYGEN,
        HealthDataType.EXERCISE_TIME,
        HealthDataType.RESPIRATORY_RATE,
        HealthDataType.ATRIAL_FIBRILLATION_BURDEN,
        ...sleepTypes,
      ];

      // Use the widest window needed (sleep looks back 6h before startTime).
      final queryStart = startTime.subtract(const Duration(hours: 6));

      List<HealthDataPoint> rawPoints;
      try {
        rawPoints = await Health().getHealthDataFromTypes(
          types: allTypes,
          startTime: queryStart,
          endTime: now,
        );
      } catch (e) {
        debugPrint('[fetchMetricHistory] getHealthDataFromTypes failed: $e');
        rawPoints = [];
      }

      final allDeduped = Health().removeDuplicates(rawPoints);

      // Diagnostic logging
      final typeCounts = <String, int>{};
      for (final p in allDeduped) {
        typeCounts[p.type.name] = (typeCounts[p.type.name] ?? 0) + 1;
      }
      debugPrint('[MetricHistory] HealthKit returned ${allDeduped.length} points: ${typeCounts.entries.map((e) => '${e.key}=${e.value}').join(', ')}');

      // Split into logical groups for processing below.
      final allHrHrv = allDeduped.where((p) =>
          p.type == HealthDataType.HEART_RATE || p.type == hrvType).toList();
      final allSteps = allDeduped.where((p) =>
          p.type == HealthDataType.STEPS).toList();
      final allSleep = allDeduped.where((p) =>
          sleepTypes.contains(p.type)).toList();
      final allExtra = allDeduped.where((p) =>
          p.type == HealthDataType.RESTING_HEART_RATE ||
          p.type == HealthDataType.BLOOD_OXYGEN ||
          p.type == HealthDataType.EXERCISE_TIME ||
          p.type == HealthDataType.RESPIRATORY_RATE ||
          p.type == HealthDataType.ATRIAL_FIBRILLATION_BURDEN).toList();

      // Determine primary HR source (most readings) to avoid cross-device mixing
      final hrSourceCounts = <String, int>{};
      for (final p in allHrHrv.where((p) => p.type == HealthDataType.HEART_RATE)) {
        hrSourceCounts[p.sourceName] = (hrSourceCounts[p.sourceName] ?? 0) + 1;
      }
      final primaryHrSource = hrSourceCounts.isEmpty
          ? null
          : hrSourceCounts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;

      // Determine primary Steps source
      final stepSourceCounts = <String, int>{};
      for (final p in allSteps) {
        stepSourceCounts[p.sourceName] = (stepSourceCounts[p.sourceName] ?? 0) + 1;
      }
      final primaryStepSource = stepSourceCounts.isEmpty
          ? null
          : stepSourceCounts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;

      // Build one DailyMetricPoint per calendar day
      final points = <DailyMetricPoint>[];
      for (int i = 0; i < days; i++) {
        final dayStart = DateTime(startTime.year, startTime.month, startTime.day)
            .add(Duration(days: i));
        final dayEnd = dayStart.add(const Duration(days: 1));

        // HR average for this day (primary source only)
        final hrVals = allHrHrv
            .where((p) =>
                p.type == HealthDataType.HEART_RATE &&
                p.value is NumericHealthValue &&
                (primaryHrSource == null || p.sourceName == primaryHrSource) &&
                !p.dateFrom.isBefore(dayStart) && p.dateFrom.isBefore(dayEnd))
            .map((p) => (p.value as NumericHealthValue).numericValue.toDouble())
            .toList();
        final avgHr = hrVals.isEmpty
            ? null
            : hrVals.reduce((a, b) => a + b) / hrVals.length;

        // HRV: latest reading for the day
        final hrvPoints = allHrHrv
            .where((p) =>
                p.type == hrvType &&
                p.value is NumericHealthValue &&
                !p.dateFrom.isBefore(dayStart) && p.dateFrom.isBefore(dayEnd))
            .toList()
          ..sort((a, b) => b.dateFrom.compareTo(a.dateFrom));
        final latestHrv = hrvPoints.isEmpty
            ? null
            : (hrvPoints.first.value as NumericHealthValue).numericValue.toDouble();

        // Steps: sum from primary source only for this day
        final stepVals = allSteps
            .where((p) =>
                p.value is NumericHealthValue &&
                (primaryStepSource == null || p.sourceName == primaryStepSource) &&
                !p.dateFrom.isBefore(dayStart) && p.dateFrom.isBefore(dayEnd))
            .map((p) => (p.value as NumericHealthValue).numericValue.toDouble())
            .toList();
        final totalSteps = stepVals.isEmpty
            ? null
            : stepVals.reduce((a, b) => a + b).toInt();

        // Sleep: sum DEEP+REM+LIGHT stages for the night covering this day
        // Sleep night = previous day 18:00 → this day 14:00
        final sleepNightStart = dayStart.subtract(const Duration(hours: 6));
        const stageTypes = {
          HealthDataType.SLEEP_DEEP,
          HealthDataType.SLEEP_REM,
          HealthDataType.SLEEP_LIGHT,
        };
        final stagePts = allSleep.where((p) =>
            stageTypes.contains(p.type) &&
            !p.dateFrom.isBefore(sleepNightStart) &&
            p.dateFrom.isBefore(dayEnd)).toList();
        final asleepPts = allSleep.where((p) =>
            p.type == HealthDataType.SLEEP_ASLEEP &&
            !p.dateFrom.isBefore(sleepNightStart) &&
            p.dateFrom.isBefore(dayEnd)).toList();
        final sleepPts = stagePts.isNotEmpty ? stagePts : asleepPts;
        double sleepSec = 0;
        for (final p in sleepPts) {
          sleepSec += p.dateTo.difference(p.dateFrom).inSeconds;
        }
        final sleepHours = sleepPts.isEmpty ? null : sleepSec / 3600.0;

        // RHR: Apple Watch writes one value per day.
        final rhrPts = allExtra
            .where((p) =>
                p.type == HealthDataType.RESTING_HEART_RATE &&
                p.value is NumericHealthValue &&
                !p.dateFrom.isBefore(dayStart) && p.dateFrom.isBefore(dayEnd))
            .toList()
          ..sort((a, b) => b.dateFrom.compareTo(a.dateFrom));
        final dayRhr = rhrPts.isEmpty
            ? null
            : (rhrPts.first.value as NumericHealthValue).numericValue.toDouble();

        // SpO2: latest reading of the day.
        final spo2Pts = allExtra
            .where((p) =>
                p.type == HealthDataType.BLOOD_OXYGEN &&
                p.value is NumericHealthValue &&
                !p.dateFrom.isBefore(dayStart) && p.dateFrom.isBefore(dayEnd))
            .toList()
          ..sort((a, b) => b.dateFrom.compareTo(a.dateFrom));
        // HealthKit stores BLOOD_OXYGEN as a ratio (0.0–1.0); multiply by 100.
        final daySpo2 = spo2Pts.isEmpty
            ? null
            : (spo2Pts.first.value as NumericHealthValue).numericValue.toDouble() * 100;

        // Exercise Time: HealthKit returns minutes (HKUnit.minute()), so the
        // numericValue is already the minute count. Sum directly.
        final dayExerciseMinDouble = allExtra
            .where((p) =>
                p.type == HealthDataType.EXERCISE_TIME &&
                p.value is NumericHealthValue &&
                !p.dateFrom.isBefore(dayStart) && p.dateFrom.isBefore(dayEnd))
            .fold<double>(0, (acc, p) =>
                acc + (p.value as NumericHealthValue).numericValue.toDouble());
        final dayExerciseMin = dayExerciseMinDouble == 0 ? null : dayExerciseMinDouble.round();

        // Resp Rate: latest reading of the day.
        final respPts = allExtra
            .where((p) =>
                p.type == HealthDataType.RESPIRATORY_RATE &&
                p.value is NumericHealthValue &&
                !p.dateFrom.isBefore(dayStart) && p.dateFrom.isBefore(dayEnd))
            .toList()
          ..sort((a, b) => b.dateFrom.compareTo(a.dateFrom));
        final dayRespRate = respPts.isEmpty
            ? null
            : (respPts.first.value as NumericHealthValue).numericValue.toDouble();

        // AFib: any burden > 0 means AFib detected that day.
        final afibPts = allExtra
            .where((p) =>
                p.type == HealthDataType.ATRIAL_FIBRILLATION_BURDEN &&
                p.value is NumericHealthValue &&
                !p.dateFrom.isBefore(dayStart) && p.dateFrom.isBefore(dayEnd))
            .toList();
        final bool? dayAfib = afibPts.isEmpty
            ? null
            : afibPts.any((p) =>
                (p.value as NumericHealthValue).numericValue > 0);

        points.add(DailyMetricPoint(
          date: dayStart,
          avgHr: avgHr != null ? double.parse(avgHr.toStringAsFixed(1)) : null,
          hrv: latestHrv != null ? double.parse(latestHrv.toStringAsFixed(1)) : null,
          steps: totalSteps,
          sleepHours: sleepHours != null ? double.parse(sleepHours.toStringAsFixed(1)) : null,
          rhr: dayRhr != null ? double.parse(dayRhr.toStringAsFixed(1)) : null,
          spo2: daySpo2 != null ? double.parse(daySpo2.toStringAsFixed(1)) : null,
          exerciseMin: dayExerciseMin,
          respRate: dayRespRate != null ? double.parse(dayRespRate.toStringAsFixed(1)) : null,
          afibDetected: dayAfib,
        ));
      }
      return points;
    } catch (e) {
      debugPrint('[HealthService.fetchMetricHistory] $e');
      return [];
    }
  }

  // ── Cloud risk insights (requires network + JWT) ──────────────────────────
  /// Calls GET /api/v1/reports/summary and parses the HRI + anomalies.
  /// Caches the result in SharedPreferences for offline display on next launch.
  static Future<RiskInsight?> fetchRiskInsight({
    void Function(String)? onLog,
  }) async {
    final lpUrl = await _baseUrl();
    final lpUserId = (await _secureStorage.read(key: _keyLpUserId)) ?? '';
    final token = (await _secureStorage.read(key: _keyJwtToken)) ?? '';

    if (lpUserId.isEmpty || token.isEmpty) return null;

    try {
      onLog?.call('Fetching risk insights from TikCare…');
      final response = await http.get(
        Uri.parse('$lpUrl/api/v1/reports/summary/$lpUserId'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 401) {
        sessionExpired.value = true;
        return _loadCachedInsight();
      }
      if (response.statusCode != 200) {
        onLog?.call('⚠️  Insights fetch: HTTP ${response.statusCode}');
        return _loadCachedInsight();
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;

      final anomalyBreakdown = Map<String, int>.from(
        (body['anomaly_breakdown'] as Map? ?? {}).map(
          (k, v) => MapEntry(k as String, (v as num?)?.toInt() ?? 0),
        ),
      );

      final latestAnomalies = List<Map<String, dynamic>>.from(
        (body['latest_anomalies'] as List? ?? []).map(
          (e) => Map<String, dynamic>.from(e as Map),
        ),
      );

      // Round-16: ``latest_upload`` from /reports/summary is now an ISO
      // string (the timestamp of the last completed sync), NOT a Map.
      // The pre-round-16 reader did ``as Map?`` which threw a TypeError
      // on every user who had at least one completed sync — the
      // exception bubbled to _fetchInsightsWithRetry's broad catch,
      // marked _insightFetchFailed=true, and rendered the
      // "Could not load your insights" card.  The bug bit Louis
      // (louislol@yahoo.com.hk) but spared cath@tikcare.co only because
      // she had never had a successful sync, so latest_upload was null
      // and ``null as Map?`` returns null harmlessly.
      //
      // Be type-safe here: handle Map (legacy wrapped form), String
      // (current ISO form), and null.  fraudRiskScore is insurer-side
      // and intentionally not displayed to members anyway, so the
      // String branch just leaves it null.
      final latestUploadRaw = body['latest_upload'];
      final fraudScore = latestUploadRaw is Map
          ? (latestUploadRaw['fraud_risk_score'] as num?)?.toDouble()
          : null;

      final abi = (body['abi'] as Map?) ?? const {};
      final abiBase = (abi['base'] as Map?) ?? const {};
      final abiComp = abi['comprehensive'] as Map?;

      final insight = RiskInsight(
        hriScore: (body['hri_score'] as num? ?? 0).toInt(),
        hriLabel: body['hri_label'] as String? ?? 'unknown',
        anomalyBreakdown: anomalyBreakdown,
        latestAnomalies: latestAnomalies,
        fraudRiskScore: fraudScore,
        fetchedAt: DateTime.now(),
        baselineMaturity: body['baseline_maturity'] as String? ?? 'cold_start',
        daysWithData: (body['days_with_data'] as num? ?? 0).toInt(),
        estimatedEstablishedDate: body['estimated_established_date'] as String?,
        abiTier: abi['tier'] as String? ?? 'accumulating',
        dataAdequacyStage:
            abi['data_adequacy_stage'] as String? ?? 'accumulating',
        abiBaseScore: (abiBase['score'] as num?)?.toDouble(),
        abiBaseLabel: abiBase['label'] as String?,
        abiComprehensiveScore:
            abiComp != null ? (abiComp['score'] as num?)?.toDouble() : null,
        abiComprehensiveLabel:
            abiComp != null ? abiComp['label'] as String? : null,
        abiActiveMetrics: List<String>.from(
          (abi['active_metrics'] as List? ?? const []).map((e) => '$e'),
        ),
        abiMissingForUpgrade: List<String>.from(
          (abi['missing_for_upgrade'] as List? ?? const []).map((e) => '$e'),
        ),
      );

      // Cache for offline use
      await _cacheInsight(insight, body);
      onLog?.call('✅ Risk insights updated (ABI: ${insight.hriScore})');
      return insight;
    } catch (e) {
      onLog?.call('⚠️  Could not fetch insights: $e');
      return _loadCachedInsight();
    }
  }

  static Future<void> _cacheInsight(
    RiskInsight insight,
    Map<String, dynamic> raw,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    // Strip insurer-side actuarial signal before writing to SharedPreferences.
    // SharedPreferences is unencrypted and can appear in plaintext device backups.
    // fraudRiskScore must never be persisted outside of in-memory RiskInsight objects.
    final safeRaw = Map<String, dynamic>.from(raw);
    final lu = safeRaw['latest_upload'];
    if (lu is Map) {
      final safeLu = Map<String, dynamic>.from(lu as Map<String, dynamic>);
      safeLu.remove('fraud_risk_score');
      safeRaw['latest_upload'] = safeLu;
    }
    await prefs.setString(_keyRiskInsightCache, jsonEncode({
      ...safeRaw,
      '_cached_at': insight.fetchedAt.toIso8601String(),
    }));
  }

  static Future<RiskInsight?> _loadCachedInsight() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyRiskInsightCache);
    if (raw == null) return null;
    try {
      final body = jsonDecode(raw) as Map<String, dynamic>;
      final anomalyBreakdown = Map<String, int>.from(
        (body['anomaly_breakdown'] as Map? ?? {}).map(
          (k, v) => MapEntry(k as String, (v as num?)?.toInt() ?? 0),
        ),
      );
      final latestAnomalies = List<Map<String, dynamic>>.from(
        (body['latest_anomalies'] as List? ?? []).map(
          (e) => Map<String, dynamic>.from(e as Map),
        ),
      );
      final abi = (body['abi'] as Map?) ?? const {};
      final abiBase = (abi['base'] as Map?) ?? const {};
      final abiComp = abi['comprehensive'] as Map?;

      return RiskInsight(
        hriScore: (body['hri_score'] as num? ?? 0).toInt(),
        hriLabel: body['hri_label'] as String? ?? 'unknown',
        anomalyBreakdown: anomalyBreakdown,
        latestAnomalies: latestAnomalies,
        // fraudRiskScore is never written to the cache (stripped in _cacheInsight).
        // Always null here — do NOT read it from the unencrypted cache.
        fraudRiskScore: null,
        fetchedAt: DateTime.tryParse(body['_cached_at'] as String? ?? '') ?? DateTime.now(),
        baselineMaturity: body['baseline_maturity'] as String? ?? 'cold_start',
        daysWithData: (body['days_with_data'] as num? ?? 0).toInt(),
        estimatedEstablishedDate: body['estimated_established_date'] as String?,
        abiTier: abi['tier'] as String? ?? 'accumulating',
        dataAdequacyStage:
            abi['data_adequacy_stage'] as String? ?? 'accumulating',
        abiBaseScore: (abiBase['score'] as num?)?.toDouble(),
        abiBaseLabel: abiBase['label'] as String?,
        abiComprehensiveScore:
            abiComp != null ? (abiComp['score'] as num?)?.toDouble() : null,
        abiComprehensiveLabel:
            abiComp != null ? abiComp['label'] as String? : null,
        abiActiveMetrics: List<String>.from(
          (abi['active_metrics'] as List? ?? const []).map((e) => '$e'),
        ),
        abiMissingForUpgrade: List<String>.from(
          (abi['missing_for_upgrade'] as List? ?? const []).map((e) => '$e'),
        ),
      );
    } catch (_) {
      return null;
    }
  }

  // ── Direct sync path (JWT auth, incremental) ─────────────────────────────
  /// Dedup wrapper: if a sync is already running, the caller joins the
  /// existing Future instead of spawning a second upload.  This prevents
  /// duplicate events when the IndexedStack mounts multiple tabs at once.
  static Future<SyncResult> syncDirect({
    void Function(String)? onLog,
    int? maxDays,
    bool forceFullResync = false,
    SyncPath syncPath = SyncPath.foreground,
  }) {
    if (_ongoingSync != null) {
      onLog?.call('ℹ️  Sync already running — waiting for it to complete…');
      return _ongoingSync!;
    }
    _ongoingSync = _runWithTelemetry(
      onLog: onLog,
      maxDays: maxDays,
      forceFullResync: forceFullResync,
      syncPath: syncPath,
    ).whenComplete(() {
      _ongoingSync = null;
    });
    return _ongoingSync!;
  }

  /// Track A + B wrapper around [_doSyncDirect].
  ///
  /// Generates a fresh attempt_id for the lifecycle, emits ``sync_attempt``
  /// at the start and ``sync_success`` / ``sync_failure`` / ``sync_partial``
  /// at the end, and atomically updates [SyncStateStore] so every UI
  /// listening to its [ValueNotifier] reflects the same source of truth.
  ///
  /// The wrapper deliberately doesn't touch the inner sync logic — that
  /// stays in [_doSyncDirect] so the substantial existing test surface
  /// keeps applying.  All cross-cutting observability lives here.
  static Future<SyncResult> _runWithTelemetry({
    void Function(String)? onLog,
    int? maxDays,
    bool forceFullResync = false,
    required SyncPath syncPath,
  }) async {
    final attemptId = newAttemptId();
    final stopwatch = Stopwatch()..start();
    final baseUrl = await _baseUrl();
    final attemptIso = DateTime.now().toUtc().toIso8601String();

    final anchorBefore = (await SharedPreferences.getInstance())
        .getString(_keyClientUploadAnchor);

    // Emit attempt FIRST so a hard kill mid-sync still leaves a trail.
    // Failure to emit telemetry never blocks the sync.
    unawaited(SyncTelemetry.instance.record(SyncTelemetryEvent(
      attemptId: attemptId,
      eventType: SyncEventType.attempt,
      syncPath: syncPath,
      baseUrl: baseUrl,
      endpoint: '/api/v1/data/mobile-sync',
      anchorBefore: anchorBefore,
    )));

    // SyncState — bump attempt timestamp + flag inFlight=true so any
    // listener (Profile / Today / Trends) shows the spinner immediately.
    //
    // Wrapped in try/catch: a SharedPreferences failure (corrupt
    // backing store on a low-storage device, etc.) must NOT prevent
    // the actual sync from running.  Telemetry/state is observability
    // infrastructure, not a sync gate.
    try {
      await SyncStateStore.instance.update((s) => s.copyWith(
            lastAttemptAtIso: attemptIso,
            inFlight: true,
          ));
    } catch (e) {
      debugPrint('[Sync._runWithTelemetry] state update failed (non-fatal): $e');
    }

    SyncResult result;
    try {
      result = await _doSyncDirect(
        onLog: onLog,
        maxDays: maxDays,
        forceFullResync: forceFullResync,
        attemptId: attemptId,
      );
    } catch (e, st) {
      // _doSyncDirect already converts most exceptions into SyncResult,
      // but a top-level crash should still produce a telemetry record.
      debugPrint('[Sync._runWithTelemetry] crashed: $e\n$st');
      result = SyncResult(
        success: false,
        message: 'Unexpected error: $e',
        errorType: SyncErrorType.unknown,
      );
    }

    final latencyMs = stopwatch.elapsedMilliseconds;
    final eventsSent = (result.data?['events_received'] as int?) ?? 0;
    final eventsAccepted =
        (result.data?['events_accepted'] as int?) ?? eventsSent;

    final anchorAfter = (await SharedPreferences.getInstance())
        .getString(_keyClientUploadAnchor);

    // Emit terminal event.
    final terminalType = result.success
        ? (eventsSent > 0 && eventsAccepted < eventsSent
            ? SyncEventType.partial
            : SyncEventType.success)
        : SyncEventType.failure;

    unawaited(SyncTelemetry.instance.record(SyncTelemetryEvent(
      attemptId: attemptId,
      eventType: terminalType,
      syncPath: syncPath,
      baseUrl: baseUrl,
      endpoint: '/api/v1/data/mobile-sync',
      latencyMs: latencyMs,
      eventsSent: eventsSent,
      eventsAccepted: eventsAccepted,
      anchorBefore: anchorBefore,
      anchorAfter: anchorAfter,
      errorClass: result.errorType?.name,
      errorMessage: result.message,
    )));

    // Sync-attempt history — a bounded on-device ring buffer the hidden Dev
    // Tools screen renders as a "last N attempts" table. Outcome is the
    // terminal event name on success/partial, or the error class name on
    // failure ('deviceLocked' / 'network' / …). Fire-and-forget + try/catch
    // inside append() so history recording can never break a sync, and it
    // works in the background isolate too (SharedPreferences is functional
    // there).
    try {
      final outcome = result.success
          ? terminalType.name
          : (result.errorType?.name ?? SyncEventType.failure.name);
      unawaited(SyncAttemptHistory.append(SyncAttemptRecord(
        at: DateTime.now().toUtc(),
        path: syncPath.name,
        outcome: outcome,
        eventsSent: eventsSent,
        errorClass: result.success ? null : result.errorType?.name,
      )));
    } catch (e) {
      debugPrint('[Sync._runWithTelemetry] attempt-history append failed (non-fatal): $e');
    }

    // SyncState — split attempt vs success timestamps so the
    // contradictory "synced 4 days ago / failed today" UX of v4.5
    // is impossible by construction.  Wrapped — see attempt-side
    // rationale above.
    try {
      await SyncStateStore.instance.update((s) {
        if (result.success) {
          return s.copyWith(
            lastSuccessAtIso: attemptIso,
            lastEventCount: eventsAccepted,
            clientUploadAnchorIso: anchorAfter,
            clearLastErrorClass: true,
            clearLastErrorMessage: true,
            inFlight: false,
          );
        }
        return s.copyWith(
          lastErrorClass: result.errorType?.name,
          lastErrorMessage: result.message,
          clientUploadAnchorIso: anchorAfter,
          inFlight: false,
        );
      });
    } catch (e) {
      debugPrint('[Sync._runWithTelemetry] terminal state update failed (non-fatal): $e');
    }

    return result;
  }

  /// Resolver that lets [SyncTelemetry] flush its offline queue without
  /// importing HealthService directly (avoids a cycle).  Returns null
  /// when the user is logged out.
  static Future<({String baseUrl, String token})?>
      telemetryAuthResolver() async {
    final token = (await _secureStorage.read(key: _keyJwtToken)) ?? '';
    if (token.isEmpty) return null;
    final url = await _baseUrl();
    return (baseUrl: url, token: token);
  }

  /// Outcome of polling a SyncLog after a 202 Accepted upload.
  ///
  /// The server's /mobile-sync contract is queue-then-process: a 202
  /// only means "the events are queued for ingestion".  We need to wait
  /// until ``status=complete`` before advancing the upload anchor —
  /// otherwise a background failure permanently strands those events
  /// (round-6 audit CRITICAL #3, the actual root cause of "sync 长期
  /// 修不好").
  static Future<({String status, String? errorMessage, int eventsSaved})>
      _pollSyncLogStatus({
    required String lpUrl,
    required String token,
    required int syncLogId,
    Duration totalTimeout = const Duration(seconds: 90),
  }) async {
    final deadline = DateTime.now().add(totalTimeout);
    // Backoff: 1s, 2s, 4s, 6s, then 8s steady-state. Caps at the
    // deadline boundary; ingestion of a normal incremental batch is
    // sub-second, but historical chunks can run 30-60s on a cold pool.
    final intervals = <int>[1, 2, 4, 6];
    var attemptIdx = 0;
    while (DateTime.now().isBefore(deadline)) {
      final waitSec = attemptIdx < intervals.length ? intervals[attemptIdx] : 8;
      attemptIdx++;
      await Future.delayed(Duration(seconds: waitSec));
      try {
        final resp = await http.get(
          Uri.parse('$lpUrl/api/v1/data/import/$syncLogId/status'),
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(const Duration(seconds: 10));
        if (resp.statusCode == 401) {
          sessionExpired.value = true;
          return (
            status: 'failed',
            errorMessage: 'Session expired during status poll',
            eventsSaved: 0,
          );
        }
        if (resp.statusCode != 200) {
          // Transient — keep polling until deadline.
          debugPrint(
            '[Sync._pollSyncLogStatus] non-200 (${resp.statusCode}); retrying',
          );
          continue;
        }
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        final status = body['status'] as String? ?? 'processing';
        // ``skipped`` is also a terminal success state on the server —
        // see ingestion_sync_log.py:127 where the SyncLog is closed
        // with status="skipped" when events_saved=0 (all events were
        // duplicates already in canonical_events).  Without treating it
        // as terminal, the poller would spin until the 90s/3min
        // deadline on every healthy duplicate-only sync, surface a
        // spurious "Server still processing" failure to the user, and
        // refuse to advance the anchor — causing the next sync to
        // re-upload the same dups and loop the failure (round-7 audit).
        if (status == 'complete' || status == 'skipped' || status == 'failed') {
          return (
            status: status,
            errorMessage: body['error_message'] as String?,
            eventsSaved: (body['events_saved'] as int?) ?? 0,
          );
        }
        // Still processing — loop.
      } catch (e) {
        // Network blip — keep polling until deadline.
        debugPrint('[Sync._pollSyncLogStatus] poll error: $e');
      }
    }
    return (
      status: 'timeout',
      errorMessage: 'Server still processing after ${totalTimeout.inSeconds}s',
      eventsSaved: 0,
    );
  }

  /// Smart incremental sync:
  ///   - First sync (no anchor): pulls the last 180 days to build a baseline
  ///   - Subsequent syncs: pulls from (server anchor − 2h) to cover HealthKit write latency
  ///   - Fallback on network error: pulls the last 2 days
  ///
  /// Sleep data uses a separate window (yesterday 18:00 → now) because sleep spans
  /// midnight and needs to be fetched relative to the prior evening.
  static const _keySyncInProgress = 'sync_in_progress_at';
  static const _keyHistoricalSyncCursor = 'historical_sync_cursor';
  // Round-19: dropped from 365 → 180 days. Reasons:
  //   * UI copy on Profile + the trends gap banner has always read
  //     "the last 180 days" — the value 365 silently drifted out of
  //     sync, leaving members watching "Week 37 of 53" (1-yr) under
  //     a "180 days" promise.
  //   * Backend baselines are 90-day rolling, so 180 days is plenty
  //     of buffer (2× the window). Going to 365 doubled chunk count
  //     (53 vs 26) and ingest time without improving any downstream
  //     metric — the 4th-quarter chunks land in a 90-day window
  //     that's already aged out of every baseline calculation.
  //   * Halves the operator's wait when re-syncing a fresh device.
  static const _historicalSyncDays = 180;

  /// Ceiling on how far back an incremental sync window may reach. The
  /// per-metric anchor (oldest max across synced metric types) protects
  /// low-frequency metrics from being leapfrogged by HR_INSTANT, but a
  /// metric that went quiet (e.g. a BP cuff used once months ago) would
  /// otherwise drag every sync into a near-full re-read of HealthKit.
  /// 30 days comfortably covers real HealthKit backfill latency (hours to
  /// days) while keeping the per-sync read bounded.
  static const int _maxIncrementalLookbackDays = 30;

  /// Public read-only accessor so UI copy strings can interpolate the
  /// constant ("Re-sync uploads the last $kHistoricalSyncDays days …")
  /// instead of repeating the literal. Round-19 split this off after the
  /// 365-vs-180 drift bug — callers from Profile / Trends / re-sync hint
  /// must use this so a future tweak ripples through every label.
  static int get kHistoricalSyncDays => _historicalSyncDays;

  /// Returns true if a sync completed or started within the last [minutes].
  /// Used by the background isolate to avoid duplicate syncs (static fields
  /// are not shared across Dart isolates).
  static Future<bool> isSyncRecentlyActive({int minutes = 5}) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keySyncInProgress);
    if (raw == null) return false;
    final ts = DateTime.tryParse(raw);
    if (ts == null) return false;
    return DateTime.now().difference(ts).inMinutes < minutes;
  }

  static Future<SyncResult> _doSyncDirect({
    void Function(String)? onLog,
    int? maxDays,
    bool forceFullResync = false,
    String? attemptId,
  }) async {
    // Ensure health plugin is configured before any HealthKit/HC call.
    await ensureHealthConfigured();

    // Cross-isolate sync mutex: write a timestamp so the background isolate
    // can detect a foreground sync in progress and skip.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keySyncInProgress, DateTime.now().toIso8601String());

    // Refresh the JWT before doing anything else — a long batch upload (first
    // sync can be 180 days / thousands of events) may outlast a near-expired
    // token if we only read it once at the top.
    await refreshTokenIfNeeded();

    final lpUrl = await _baseUrl();
    // var (not final) — re-read after each periodic refresh during long uploads.
    var token = (await _secureStorage.read(key: _keyJwtToken)) ?? '';

    if (token.isEmpty) {
      // Token was cleared (most often by refreshTokenIfNeeded() after a 401
      // from /auth/refresh). Without firing sessionExpired, the Today screen
      // surfaces a Retry button with no error context and the user is stuck
      // in an infinite loop tapping Retry against an empty Keychain.
      sessionExpired.value = true;
      return SyncResult(
        success: false,
        message: 'Session expired. Please sign in again.',
        errorType: SyncErrorType.authExpired,
      );
    }

    if (forceFullResync) {
      return _runChunkedHistoricalSync(
        prefs: prefs, lpUrl: lpUrl, token: token, onLog: onLog,
        attemptId: attemptId,
      );
    }

    try {
      if (Platform.isAndroid) {
        final status = await Health().getHealthConnectSdkStatus();
        if (status != HealthConnectSdkStatus.sdkAvailable) {
          return SyncResult(
            success: false,
            message: 'Health Connect is not available. '
                'Please install it from the Play Store to sync health data.',
          );
        }
      }

      // ── Step 1: Determine sync start time via server anchor ───────────────
      final endTime = DateTime.now();
      DateTime startTime;

      try {
        final anchorResp = await http.get(
          Uri.parse('$lpUrl/api/v1/data/latest-event-time'),
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(const Duration(seconds: 10));

        if (anchorResp.statusCode == 200) {
          final body = jsonDecode(anchorResp.body) as Map<String, dynamic>;
          final rawAnchor = body['latest_event_time'] as String?;
          if (rawAnchor == null) {
            // New user — pull the full baseline window from day one.
            startTime = endTime.subtract(const Duration(days: _historicalSyncDays));
            onLog?.call('First sync detected — fetching last $_historicalSyncDays days to build baseline…');
          } else {
            // The GLOBAL max is not a safe anchor: it is pinned to "now" by
            // the highest-frequency metric (HR_INSTANT), so late-landing
            // samples of slower metrics — overnight sleep stages written in
            // the morning, watch-transfer lag, RHR/SpO2/RESP backfills —
            // fell permanently behind the window. Anchor on the OLDEST
            // per-metric max among the types this app syncs instead, capped
            // at _maxIncrementalLookbackDays so one long-dormant metric
            // (e.g. a BP cuff used once) can't force a full re-pull forever.
            final perMetricRaw =
                body['latest_event_times'] as Map<String, dynamic>? ?? const {};
            DateTime? serverAnchor;
            for (final entry in perMetricRaw.entries) {
              if (entry.key == 'VO2_MAX') continue; // own 90-day lookback below
              final t = DateTime.tryParse(entry.value as String? ?? '');
              if (t == null) continue;
              if (serverAnchor == null || t.isBefore(serverAnchor)) {
                serverAnchor = t;
              }
            }
            // Older servers don't send the per-metric map — fall back to the
            // legacy global anchor.
            serverAnchor ??= DateTime.tryParse(rawAnchor);
            // Per-batch client anchor (set after every successful batch in
            // the previous sync). Defends against partial-failure data loss:
            // server max may have advanced past events that never made it
            // through, so we use the older of (server anchor, client
            // anchor that was the floor we're certain server has).
            final clientAnchorIso = prefs.getString(_keyClientUploadAnchor);
            final clientAnchor = clientAnchorIso != null
                ? DateTime.tryParse(clientAnchorIso)
                : null;
            final anchor = (serverAnchor != null && clientAnchor != null)
                // Use the OLDER of the two when last sync wasn't a full
                // success — that re-queries any range we're not 100% sure
                // about, and the server dedupes via content_hash so the
                // overlap is cheap. After a full success, both anchors
                // agree, so this collapses to a no-op.
                ? (serverAnchor.isBefore(clientAnchor) ? serverAnchor : clientAnchor)
                : (serverAnchor ?? clientAnchor);
            if (anchor == null) {
              // Malformed anchor from server — fall back to a full re-sync.
              startTime = endTime.subtract(const Duration(days: _historicalSyncDays));
              onLog?.call('Invalid sync anchor — falling back to full $_historicalSyncDays-day re-sync…');
            } else {
              startTime = anchor.subtract(const Duration(hours: 2));
              // Bound the incremental window: the per-metric min can reach
              // far back when a rarely-produced metric went quiet. The server
              // upserts idempotently, but re-reading months of HealthKit on
              // every sync is wasted battery and upload.
              final lookbackFloor = endTime
                  .subtract(const Duration(days: _maxIncrementalLookbackDays));
              if (startTime.isBefore(lookbackFloor)) {
                startTime = lookbackFloor;
              }
              onLog?.call('Incremental sync from ${startTime.toLocal().toString().substring(0, 16)}…');
            }
          }
        } else if (anchorResp.statusCode == 401) {
          // Token expired before the sync even started — trigger session flow
          // immediately rather than continuing with a doomed upload.
          sessionExpired.value = true;
          return SyncResult(
            success: false,
            message: 'Session expired. Please sign in again.',
            errorType: SyncErrorType.authExpired,
          );
        } else {
          // Unexpected status — fall back to 2-day safe window
          startTime = endTime.subtract(const Duration(days: 2));
          onLog?.call('Anchor check failed (HTTP ${anchorResp.statusCode}), using 2-day fallback…');
        }
      } catch (_) {
        // Network error reaching anchor endpoint — safe fallback
        startTime = endTime.subtract(const Duration(days: 2));
        onLog?.call('Could not reach anchor endpoint, using 2-day fallback…');
      }

      // Apply maxDays cap (background sync context) — prevents iOS from killing
      // the process mid-upload when a large first-time sync is attempted in the
      // background. Background tasks should only do incremental windows (≤2 days).
      if (maxDays != null) {
        final cap = endTime.subtract(Duration(days: maxDays));
        if (startTime.isBefore(cap)) {
          startTime = cap;
          onLog?.call('Background mode: capping sync window to $maxDays days to stay within iOS time limit…');
        }
      }

      // ── Step 2: Request permissions ───────────────────────────────────────
      // Sleep stages are now in coreTypes (added directly to _platformSyncTypes).
      final coreTypes = _platformSyncTypes();
      final allTypes = [...coreTypes, ..._optionalSyncTypes];

      onLog?.call(Platform.isIOS ? 'Requesting HealthKit permissions…' : 'Requesting Health Connect permissions…');
      final granted = await Health().requestAuthorization(allTypes);
      if (!granted) {
        return SyncResult(
          success: false,
          message: Platform.isIOS
              ? 'Apple Health access is required. Tap "Grant Permission" below, or open the Health app → Sharing → Apps → TikCare Vitametric and enable all categories.'
              : 'Health Connect permission denied. Please grant access and try again.',
          errorType: SyncErrorType.permissionDenied,
        );
      }

      // VO2_MAX and SLEEP_APNEA_EVENT ride native bridges outside the health
      // plugin's permission list — their HealthKit authorization is requested
      // separately, and only in the FOREGROUND (maxDays is set exclusively by
      // the background isolate, which cannot present a permission sheet).
      if (Platform.isIOS && maxDays == null) {
        await Vo2MaxChannel.requestAuthorization();
        await SleepApneaChannel.requestAuthorization();
      }

      // ── Step 3–5: Fetch core (includes sleep stages), optional in parallel ─
      onLog?.call('Fetching health data…');

      // The HealthKit store is file-protected: queries on a locked device
      // return zero samples WITHOUT throwing. Background refresh fires
      // exactly then (idle, charging, overnight), so without this guard a
      // locked-device run read nothing and was recorded as a successful
      // "Already up to date" sync. Fail so WorkManager retries later.
      if (!await DeviceLockChannel.isProtectedDataAvailable()) {
        onLog?.call('Device is locked — HealthKit is unreadable. Will retry.');
        return SyncResult(
          success: false,
          message: 'Device locked — health data is unreadable until unlock. '
              'Sync will retry automatically.',
          errorType: SyncErrorType.deviceLocked,
        );
      }

      // Sleep spans midnight: always look back to yesterday 18:00 at minimum,
      // but respect the incremental startTime if it's earlier. Sleep stage types
      // are now in coreTypes, so the same extended window applies to all core data.
      final sleepWindowStart = [
        startTime,
        DateTime(endTime.year, endTime.month, endTime.day)
            .subtract(const Duration(hours: 6)), // yesterday 18:00
      ].reduce((a, b) => a.isBefore(b) ? a : b);

      // Single combined query — iOS HealthKit returns empty for individual-type
      // queries but succeeds when all authorized types are fetched together.
      //
      // A throw here must FAIL the sync, not degrade to an empty list: the
      // empty-list path below concludes "Already up to date" (success), which
      // hid every read failure — locked store, HealthKit timeout, plugin
      // error — behind a green checkmark.
      List<HealthDataPoint> rawPoints;
      try {
        rawPoints = await Health().getHealthDataFromTypes(
          types: allTypes,
          startTime: sleepWindowStart, // use extended window for all (covers sleep)
          endTime: endTime,
        );
      } catch (e) {
        debugPrint('[Sync] getHealthDataFromTypes failed: $e');
        return SyncResult(
          success: false,
          message: 'Could not read health data: $e',
          errorType: SyncErrorType.healthReadFailed,
        );
      }

      // ── Step 6: Deduplicate, convert ───────────────────────────────────────
      final allPoints = Health().removeDuplicates(rawPoints);
      onLog?.call('Fetched ${allPoints.length} data points.');

      // Per-metric-type breakdown for diagnostics — helps identify HealthKit
      // permission denials (iOS returns empty, not an error) and device gaps.
      final typeCounts = <String, int>{};
      for (final p in allPoints) {
        final key = p.type.name;
        typeCounts[key] = (typeCounts[key] ?? 0) + 1;
      }
      if (typeCounts.isNotEmpty) {
        final breakdown = typeCounts.entries
            .map((e) => '${e.key}: ${e.value}')
            .join(', ');
        onLog?.call('Breakdown: $breakdown');
        debugPrint('[Sync] HealthKit type breakdown: $breakdown');
      }

      // Collect unique source device names for UI display
      final sourceDevices = allPoints
          .map((p) => p.sourceName)
          .where((n) => n.isNotEmpty)
          .toSet()
          .toList();

      // Read VO2_MAX BEFORE the empty-check on allPoints.  Round-7 audit
      // caught: when HealthKit's core-type read returns nothing in this
      // window but VO2 has new readings, the early-return below would
      // skip VO2 entirely and silently lose the data.  90-day lookback
      // is intentional — VO2 is sampled at most once per week, and the
      // incremental anchor (driven by high-frequency HR_INSTANT events)
      // would otherwise leapfrog past Saturday VO2 readings forever.
      final vo2Start = endTime.subtract(const Duration(days: 90));
      final vo2Events = await Vo2MaxChannel.readVo2Max(vo2Start, endTime);

      // Sleep apnea events ride the same native-bridge pattern as VO2 —
      // the health plugin doesn't wrap the category type at all. Sparse
      // (Apple Watch S9+/watchOS 10+ only, a handful per night at most),
      // so the generous lookback costs nothing; the server dedupes.
      final apneaEvents =
          await SleepApneaChannel.readApneaEvents(vo2Start, endTime);

      if (allPoints.isEmpty && vo2Events.isEmpty && apneaEvents.isEmpty) {
        // On iOS, requestAuthorization() returns true even when the user denies
        // all categories (Apple privacy policy). So we can reach this point with
        // zero data because permissions were denied, not because data is current.
        //
        // Heuristic: if this is a first-time sync (window ≥ 30 days) and we got
        // zero data on iOS, it's almost certainly a permission issue — an iPhone
        // passively collects steps/distance even without Apple Watch.
        // For incremental syncs (short windows), zero data genuinely means
        // "already up to date".
        final syncWindowDays = endTime.difference(startTime).inDays;
        if (Platform.isIOS && syncWindowDays >= 30) {
          onLog?.call('⚠️  First sync returned zero data — likely Health permissions not granted.');
          return SyncResult(
            success: false,
            message: 'Apple Health access is required. Tap "Grant Permission" below, or open the Health app → Sharing → Apps → TikCare Vitametric and enable all categories.',
            errorType: SyncErrorType.permissionDenied,
            data: const {'events_received': 0, 'source_devices': <String>[]},
          );
        }

        // Incremental sync with no new data — genuinely up to date.
        onLog?.call('ℹ️  Already up to date — no new data in this window.');
        return SyncResult(
          success: true,
          message: 'Already up to date.',
          errorType: SyncErrorType.noData,
          data: const {'events_received': 0, 'source_devices': <String>[]},
        );
      }

      final dedupedPoints = _dedupeOverlappingSleepAsleep(allPoints);
      final events = dedupedPoints
          .map(_convertToMobileSyncEvent)
          .whereType<Map<String, dynamic>>()
          .toList();

      // Append the VO2_MAX samples we already read above.  Server dedupes
      // by content_hash so re-fetched entries aren't double-stored.
      if (vo2Events.isNotEmpty) {
        events.addAll(vo2Events);
        onLog?.call('VO2_MAX: ${vo2Events.length} samples (90-day lookback) added via native bridge.');
      }
      if (apneaEvents.isNotEmpty) {
        events.addAll(apneaEvents);
        onLog?.call('SLEEP_APNEA_EVENT: ${apneaEvents.length} events (90-day lookback) added via native bridge.');
      }

      // Sort events ASCENDING by timestamp. Required for partial-failure
      // recovery: if batches N+1..N+k fail, the client_upload_anchor will
      // be left at the last successful batch's max timestamp, and the next
      // sync correctly resumes from there. Without sorting, batches would
      // contain randomly-mixed timestamps and the anchor advance would
      // leapfrog over unconfirmed events.
      events.sort((a, b) {
        final ta = (a['start_time'] as String?) ?? '';
        final tb = (b['start_time'] as String?) ?? '';
        return ta.compareTo(tb);
      });

      // Log converted metric breakdown — if fewer events than data points,
      // some were dropped during conversion (sleep dedup, AWAKE filter, or
      // unsupported value types).
      if (events.length < allPoints.length) {
        onLog?.call('${allPoints.length - events.length} data points skipped during conversion.');
      }
      final lpTypeCounts = <String, int>{};
      for (final e in events) {
        final mt = e['metric_type'] as String? ?? '?';
        lpTypeCounts[mt] = (lpTypeCounts[mt] ?? 0) + 1;
      }
      if (lpTypeCounts.isNotEmpty) {
        final lpBreakdown = lpTypeCounts.entries
            .map((e) => '${e.key}: ${e.value}')
            .join(', ');
        onLog?.call('Uploading: $lpBreakdown');
        debugPrint('[Sync] Metric types to upload: $lpBreakdown');
      }

      // ── Step 7: POST in batches of 2000 (handles large first-sync) ────────
      const batchSize = 2000;
      int totalSent = 0;
      Map<String, dynamic>? lastBody;
      // Fold each batch's server response into running totals so
      // `events_accepted` reflects the sum across ALL batches, not just the
      // last one. Without this, any sync > 2000 events had accepted < received
      // and _runWithTelemetry misclassified it as `partial` (Fix C).
      var totals = const SyncTotals();
      DateTime lastTokenRefresh = DateTime.now();

      for (int i = 0; i < events.length; i += batchSize) {
        // Refresh the JWT every 10 minutes during a long batch upload.
        // A first-sync of 180 days can take many minutes; a token that expires
        // mid-upload would cause 401 failures on later batches.
        if (DateTime.now().difference(lastTokenRefresh).inMinutes >= 10) {
          await refreshTokenIfNeeded();
          token = (await _secureStorage.read(key: _keyJwtToken)) ?? token;
          lastTokenRefresh = DateTime.now();
        }
        final batch = events.sublist(i, (i + batchSize).clamp(0, events.length));
        final batchIdx = i ~/ batchSize;
        // Per-batch attempt_id when the parent wrapper supplied a root.
        // Without this, every batch in a >2000-event incremental sync
        // shares one attempt_id and the server's Track D dedup
        // short-circuits batches 2..N — silent data loss the round-5
        // audit caught.  Chunk index is fixed at 0 because the
        // incremental path doesn't slice by time window; only the
        // batchIdx varies.
        final batchAttemptId = (attemptId == null)
            ? null
            : deriveChunkAttemptId(
                root: attemptId,
                chunkIdx: 0,
                batchIdx: batchIdx,
              );
        onLog?.call('Uploading events ${i + 1}–${i + batch.length} of ${events.length}…');

        // Retry each batch up to 3 times with backoff (handles 429 / transient errors).
        http.Response? response;
        for (int attempt = 0; attempt < 3; attempt++) {
          if (attempt > 0) {
            final waitSec = attempt * 3; // 3s, 6s
            onLog?.call('  Retrying batch in ${waitSec}s (attempt ${attempt + 1}/3)…');
            await Future.delayed(Duration(seconds: waitSec));
          }
          try {
            response = await http.post(
              Uri.parse('$lpUrl/api/v1/data/mobile-sync'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $token',
              },
              // Track D idempotency: per-batch attempt_id so a retried
              // POST of THIS batch dedupes (same SyncLog returned), but
              // OTHER batches in the same incremental sync each get
              // their own SyncLog and ingestion job.
              body: jsonEncode({
                'events': batch,
                if (batchAttemptId != null) 'attempt_id': batchAttemptId,
              }),
            ).timeout(const Duration(seconds: 45));
            // Don't retry on success or auth failure
            if (response.statusCode != 429 && response.statusCode != 503) break;
          } catch (e, st) {
            // Network error — will retry. Log the actual exception so
            // diagnostic mode (and post-mortem on real-user reports) can
            // distinguish DNS / TLS / Socket / Timeout failures.
            debugPrint('[Sync] upload batch attempt ${attempt + 1}/3 failed: $e\n$st');
            await _recordLastSyncException(e);
          }
        }

        if (response == null) {
          return SyncResult(
            success: false,
            message: 'Network error during upload. Please try again.',
            errorType: SyncErrorType.network,
          );
        } else if (response.statusCode == 200 || response.statusCode == 202) {
          lastBody = jsonDecode(response.body) as Map<String, dynamic>;
          // Round-6 redesign: 202 = "queued for ingestion", NOT
          // "persisted".  Poll the SyncLog until the server reports
          // ``complete``; only THEN is it safe to advance the upload
          // anchor.  Pre-redesign the anchor moved on 202, so any
          // post-202 ingestion failure (the row.inserted bug class,
          // pool exhaustion, OOM) caused those events to be skipped
          // forever on the next incremental sync — the actual root
          // cause behind "sync 长期修不好".
          final syncLogId = lastBody['sync_log_id'] as int?;
          if (syncLogId == null) {
            // Server returned 202 but no sync_log_id (e.g. the
            // "all events skipped — unknown metric_type" early-return
            // path).  Treat as success because there was nothing to
            // ingest, and advance the anchor so the next sync doesn't
            // resend the same dead batch repeatedly.
            totalSent += batch.length;
            totals = foldBatchResponse(totals, batch.length, lastBody);
            final batchMaxTs = batch.last['start_time'] as String?;
            if (batchMaxTs != null) {
              await prefs.setString(_keyClientUploadAnchor, batchMaxTs);
            }
          } else {
            onLog?.call('  Server queued ($syncLogId) — waiting for confirmation…');
            final pollResult = await _pollSyncLogStatus(
              lpUrl: lpUrl,
              token: token,
              syncLogId: syncLogId,
            );
            if (pollResult.status == 'complete' ||
                pollResult.status == 'skipped') {
              totalSent += batch.length;
              totals = foldBatchResponse(totals, batch.length, lastBody);
              // Anchor moves on EITHER terminal-success state —
              // ``skipped`` means every event in the batch was a
              // duplicate already in canonical_events (server's
              // ingestion_sync_log.py:127).  That's a successful
              // dedup outcome, not a failure: not advancing would
              // cause the same window to upload again next sync and
              // trigger the same dedup loop forever (round-7 audit).
              final batchMaxTs = batch.last['start_time'] as String?;
              if (batchMaxTs != null) {
                await prefs.setString(_keyClientUploadAnchor, batchMaxTs);
              }
            } else if (pollResult.status == 'failed') {
              // Don't advance the anchor: the next sync MUST retry
              // this exact window so no events are lost.
              return SyncResult(
                success: false,
                message:
                    'Server failed to ingest batch: ${pollResult.errorMessage ?? "unknown"}.',
                errorType: SyncErrorType.serverError,
              );
            } else {
              // timeout — also don't advance.  Surface a distinct
              // error so the user gets a "still processing" hint
              // rather than a generic server-error label.
              return SyncResult(
                success: false,
                message:
                    'Server still processing after 90s. Sync will resume on next attempt.',
                errorType: SyncErrorType.serverError,
              );
            }
          }
        } else if (response.statusCode == 401) {
          // Fire sessionExpired so every listening screen redirects to login.
          // Without this, the calling screen only receives errorType but the
          // ValueNotifier listener never triggers the navigation guard.
          sessionExpired.value = true;
          return SyncResult(
            success: false,
            message: 'Session expired. Please sign in again.',
            errorType: SyncErrorType.authExpired,
          );
        } else if (response.statusCode >= 500) {
          return SyncResult(
            success: false,
            message: 'Server error (HTTP ${response.statusCode}). Try again later.',
            errorType: SyncErrorType.serverError,
          );
        } else {
          return SyncResult(
            success: false,
            message: 'Upload failed (HTTP ${response.statusCode}).',
            errorType: SyncErrorType.serverError,
          );
        }
      }

      onLog?.call('✅ Sync complete — $totalSent events uploaded.');
      return SyncResult(
        success: true,
        message: 'Sync complete.',
        data: {
          // Keep any other keys the server body carried (e.g. sync_log_id)
          // that downstream code relies on — but override the accounting
          // fields with the cross-batch totals so `events_accepted` is the
          // sum over ALL batches, not just the last body's spread (Fix C).
          ...?lastBody,
          'events_received': totals.sent,
          'events_accepted': totals.accepted,
          'events_skipped': totals.skipped,
          'skipped_metric_types': totals.skippedMetricTypes.toList(),
          'source_devices': sourceDevices,
        },
      );

    } catch (e, st) {
      // Persist for diagnostics — without this, an `unknown` errorType
      // tells us nothing. With it, the tester's Copy-diagnostic dump shows
      // the real exception (HK plugin error / DNS failure / parse error /
      // assertion / etc).
      debugPrint('[Sync] _doSyncDirect top-level error: $e\n$st');
      await _recordLastSyncException(e);
      final isNetwork = e is SocketException || e is TimeoutException ||
          e.toString().contains('TimeoutException') ||
          e.toString().contains('SocketException');
      return SyncResult(
        success: false,
        message: isNetwork
            ? 'No internet connection. Check your network and try again.'
            : 'Something went wrong. Please try again later.',
        errorType: isNetwork ? SyncErrorType.network : SyncErrorType.unknown,
      );
    }
  }

  // ── Health check ──────────────────────────────────────────────────────────
  static Future<SyncResult> pingVitametric() async {
    final lpUrl = await _baseUrl();
    try {
      final response = await http
          .get(Uri.parse('$lpUrl/api/v1/health'))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        return SyncResult(
          success: true,
          message: 'Vitametric API is online.',
          data: body is Map<String, dynamic> ? body : {},
        );
      }
      return SyncResult(success: false, message: 'Server unavailable (HTTP ${response.statusCode}).');
    } on TimeoutException {
      return SyncResult(success: false, message: 'Connection timed out.');
    } catch (_) {
      return SyncResult(success: false, message: 'Unable to reach server.');
    }
  }

  // ── Chunked historical sync ───────────────────────────────────────────────
  /// Fetches and uploads the last [_historicalSyncDays] days from HealthKit
  /// in 7-day chunks. A cursor in SharedPreferences allows resuming after
  /// interruption — each successful chunk advances the cursor, so failed
  /// chunks are retried on the next call rather than re-doing everything.
  static Future<SyncResult> _runChunkedHistoricalSync({
    required SharedPreferences prefs,
    required String lpUrl,
    required String token,
    void Function(String)? onLog,
    String? attemptId,
  }) async {
    final coreTypes = _platformSyncTypes();
    final allTypes = [...coreTypes, ..._optionalSyncTypes];

    onLog?.call('Requesting HealthKit permissions…');
    final granted = await Health().requestAuthorization(allTypes);
    if (!granted) {
      return SyncResult(
        success: false,
        message: 'Apple Health access is required to re-sync historical data.',
        errorType: SyncErrorType.permissionDenied,
      );
    }

    final now = DateTime.now();
    final fullStart = now.subtract(const Duration(days: _historicalSyncDays));
    final cursorStr = prefs.getString(_keyHistoricalSyncCursor);
    DateTime chunkStart = (cursorStr != null ? DateTime.tryParse(cursorStr) : null) ?? fullStart;

    final totalChunks = (_historicalSyncDays / 7).ceil();
    int chunkIdx = totalChunks - (now.difference(chunkStart).inDays / 7).ceil();

    int totalSent = 0;
    // Cross-batch accounting so the historical return map reports accepted as
    // the sum over every chunk's every batch, not the last body's spread (Fix C).
    var totals = const SyncTotals();
    var currentToken = token;
    DateTime lastTokenRefresh = DateTime.now();

    while (chunkStart.isBefore(now)) {
      final chunkEnd = chunkStart.add(const Duration(days: 7));
      final effectiveEnd = chunkEnd.isBefore(now) ? chunkEnd : now;
      chunkIdx++;

      final label = 'Week $chunkIdx of $totalChunks';
      onLog?.call('Historical sync: $label…');
      historicalSyncProgress.value = label;

      // Refresh token every 10 minutes during long uploads
      if (DateTime.now().difference(lastTokenRefresh).inMinutes >= 10) {
        await refreshTokenIfNeeded();
        currentToken = (await _secureStorage.read(key: _keyJwtToken)) ?? currentToken;
        lastTokenRefresh = DateTime.now();
      }

      try {
        // Single combined query — iOS HealthKit returns empty for individual-type
        // queries but succeeds when all authorized types are fetched together.
        List<HealthDataPoint> rawPoints;
        try {
          rawPoints = await Health().getHealthDataFromTypes(
            types: allTypes,
            startTime: chunkStart,
            endTime: effectiveEnd,
          );
        } catch (e) {
          debugPrint('[HistoricalSync] getHealthDataFromTypes failed at chunk $chunkIdx: $e');
          rawPoints = [];
        }

        final allPoints = Health().removeDuplicates(rawPoints);
        final dedupedPoints = _dedupeOverlappingSleepAsleep(allPoints);
        final events = dedupedPoints
            .map(_convertToMobileSyncEvent)
            .whereType<Map<String, dynamic>>()
            .toList();

        // Append VO2_MAX samples via native HealthKit bridge for this chunk window.
        final vo2Events = await Vo2MaxChannel.readVo2Max(chunkStart, effectiveEnd);
        if (vo2Events.isNotEmpty) events.addAll(vo2Events);

        if (events.isNotEmpty) {
          // Upload in batches of 2000
          for (int i = 0; i < events.length; i += 2000) {
            final batch = events.sublist(i, (i + 2000).clamp(0, events.length));
            // CRITICAL: derive a per-batch attempt_id, not the wrapper's
            // single attempt_id.
            //
            // Why: the server's Track D idempotency layer treats two
            // POSTs with the same (tenant, attempt_id) as the SAME
            // logical sync — the second POST short-circuits and DOES
            // NOT enqueue a background ingestion job.  Historical
            // re-sync sends one POST per weekly chunk × per 2000-event
            // sub-batch — potentially 100+ POSTs across 53 weeks.
            // Sharing one attempt_id across all of them would cause
            // every chunk after the first to be dropped server-side.
            //
            // Per-batch attempt_id keeps idempotency for HTTP-level
            // retries (the inner 3-attempt loop below) while ensuring
            // each chunk gets its own SyncLog and ingestion job.
            final batchAttemptId = attemptId == null
                ? null
                : deriveChunkAttemptId(
                    root: attemptId,
                    chunkIdx: chunkIdx,
                    batchIdx: i ~/ 2000,
                  );
            http.Response? response;
            for (int attempt = 0; attempt < 3; attempt++) {
              if (attempt > 0) await Future.delayed(Duration(seconds: attempt * 3));
              try {
                response = await http.post(
                  Uri.parse('$lpUrl/api/v1/data/mobile-sync'),
                  headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $currentToken'},
                  body: jsonEncode({
                    'events': batch,
                    if (batchAttemptId != null) 'attempt_id': batchAttemptId,
                  }),
                ).timeout(const Duration(seconds: 45));
                if (response.statusCode != 429 && response.statusCode != 503) break;
              } catch (e, st) {
                debugPrint('[HistoricalSync] $label batch attempt ${attempt + 1}/3: $e\n$st');
                await _recordLastSyncException(e);
              }
            }
            // A 401 means the JWT expired mid-backfill. It must fire
            // sessionExpired so the navigation guard routes to login —
            // otherwise it falls into the generic non-2xx branch below,
            // surfaces as `serverError`, and the re-sync retries forever
            // against a dead token.  The incremental path already does
            // this; this leg did not.
            if (response != null && response.statusCode == 401) {
              sessionExpired.value = true;
              historicalSyncProgress.value = null;
              return SyncResult(
                success: false,
                message: 'Session expired. Please sign in again.',
                errorType: SyncErrorType.authExpired,
              );
            }
            if (response == null ||
                (response.statusCode != 200 &&
                    response.statusCode != 201 &&
                    response.statusCode != 202)) {
              // Chunk failed at HTTP level — keep cursor at chunkStart
              // so next run retries this chunk.  /mobile-sync's contract
              // is 202 Accepted (queued); 200 / 201 are tolerated for
              // forward-compat.  Round-6 audit caught this asymmetry:
              // the incremental path already accepted 202, so chunked
              // re-sync was the only place declaring legitimate POSTs
              // failed.
              historicalSyncProgress.value = null;
              return SyncResult(
                success: false,
                message: 'Upload failed at $label. Re-sync will resume from this point.',
                errorType: response == null
                    ? SyncErrorType.network
                    : SyncErrorType.serverError,
              );
            }
            // Round-6 redesign: poll the SyncLog before advancing the
            // chunk cursor.  Without this, the cursor moves on 202
            // (queued, not persisted) and a background ingestion
            // failure permanently strands an entire week of historical
            // data — exactly the silent data-loss path the round-2
            // attempt_id fix was supposed to close but didn't because
            // the closing wasn't at the right layer.
            try {
              final body = jsonDecode(response.body) as Map<String, dynamic>;
              totals = foldBatchResponse(totals, batch.length, body);
              final batchSyncLogId = body['sync_log_id'] as int?;
              if (batchSyncLogId != null) {
                final pollResult = await _pollSyncLogStatus(
                  lpUrl: lpUrl,
                  token: currentToken,
                  syncLogId: batchSyncLogId,
                  // Historical chunks can run longer than incremental;
                  // give the server up to 3 minutes per chunk.
                  totalTimeout: const Duration(minutes: 3),
                );
                // ``skipped`` is also a terminal success — a chunk full
                // of duplicates is the steady state for any historical
                // re-sync. Treating it as failure would loop the chunk
                // cursor forever (round-7 audit).
                if (pollResult.status != 'complete' &&
                    pollResult.status != 'skipped') {
                  historicalSyncProgress.value = null;
                  return SyncResult(
                    success: false,
                    message:
                        'Server ${pollResult.status} at $label: ${pollResult.errorMessage ?? "(no detail)"}. Re-sync will resume from this point.',
                    errorType: SyncErrorType.serverError,
                  );
                }
              }
            } catch (decodeErr) {
              debugPrint(
                  '[HistoricalSync] could not decode/poll status for $label: $decodeErr');
              // Don't advance the cursor on a decode failure — the
              // batch may or may not have persisted.  Conservative
              // fail keeps re-sync correct at the cost of one extra
              // chunk re-upload on next run.
              historicalSyncProgress.value = null;
              return SyncResult(
                success: false,
                message:
                    'Could not confirm server status at $label. Re-sync will retry.',
                errorType: SyncErrorType.serverError,
              );
            }
          }
          totalSent += events.length;
        }
      } catch (e, st) {
        debugPrint('[HistoricalSync] $label fatal: $e\n$st');
        await _recordLastSyncException(e);
        historicalSyncProgress.value = null;
        return SyncResult(
          success: false,
          message: 'Error at $label. Re-sync will resume from this point.',
          errorType: SyncErrorType.unknown,
        );
      }

      // Chunk succeeded AND every batch confirmed persisted — advance
      // cursor.  The server poll above guarantees this is safe; if
      // any batch failed we returned before reaching here.
      await prefs.setString(_keyHistoricalSyncCursor, effectiveEnd.toIso8601String());
      chunkStart = effectiveEnd;
    }

    // All chunks complete
    await prefs.remove(_keyHistoricalSyncCursor);
    historicalSyncProgress.value = null;
    onLog?.call('Historical sync complete: $totalSent events uploaded.');
    return SyncResult(
      success: true,
      message: 'Historical sync complete: $totalSent events uploaded.',
      data: {
        'events_received': totals.sent,
        'events_accepted': totals.accepted,
        'events_skipped': totals.skipped,
        'skipped_metric_types': totals.skippedMetricTypes.toList(),
        'source_devices': <String>[],
      },
    );
  }

  // ── Local HealthKit coverage ───────────────────────────────────────────────
  /// Counts how many distinct calendar days in the last [days] days have at
  /// least one Heart Rate reading in HealthKit. Used by the Trends screen to
  /// show "X analyzed · Y in Apple Health" and surface sync gaps.
  static Future<int> fetchLocalDaysWithData({required int days}) async {
    try {
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day)
          .subtract(Duration(days: days - 1));
      // Query multiple types together — iOS HealthKit can return empty for
      // single-type queries but succeeds with combined multi-type requests.
      // We only care about distinct days, so any health data type counts.
      final results = await Health().getHealthDataFromTypes(
        types: [
          HealthDataType.HEART_RATE,
          HealthDataType.STEPS,
          HealthDataType.BLOOD_OXYGEN,
        ],
        startTime: start,
        endTime: now,
      );
      return results
          .map((p) => DateTime(p.dateFrom.year, p.dateFrom.month, p.dateFrom.day))
          .toSet()
          .length;
    } catch (_) {
      return 0;
    }
  }

  // ── Client error reporting ────────────────────────────────────────────────
  /// Report a persistent client-side error to the backend audit log.
  /// Fire-and-forget: failures are silently swallowed so this never blocks the UI.
  static Future<void> reportClientError(
    String errorCode, {
    String? context,
    int? retryCount,
  }) async {
    try {
      final baseUrl = await _baseUrl();
      final headers = await _authHeaders();
      await http
          .post(
            Uri.parse('$baseUrl/api/v1/client-errors'),
            headers: headers,
            body: jsonEncode({
              'error_code': errorCode,
              if (context != null) 'context': context,
              if (retryCount != null) 'retry_count': retryCount,
              'platform': Platform.operatingSystem,
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Intentionally silent — error reporting must never crash the app.
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  static Map<String, dynamic>? _convertToMobileSyncEvent(HealthDataPoint dp) {
    final lpMetric = _healthTypeToLp(dp.type);
    if (lpMetric == null) return null;

    // Upload drop rules (SLEEP_AWAKE[/_IN_BED] filtered as non-sleep;
    // SLEEP_IN_BED dropped as a whole-night envelope that would overlap and
    // corrupt every real SLEEP_ASLEEP segment's server-side dedup) are
    // moved verbatim to health_mapping.uploadDropReason — see that file's
    // UploadDropReason doc comments for the full rationale.
    if (health_mapping.uploadDropReason(dp.type, isIos: Platform.isIOS) !=
        null) {
      return null;
    }

    double numericValue;
    if (_isSleepType(dp.type)) {
      // Sleep events represent a time range — convert duration to minutes.
      numericValue = dp.dateTo.difference(dp.dateFrom).inSeconds / 60.0;
      if (numericValue <= 0) return null;
    } else if (dp.type == HealthDataType.WORKOUT) {
      // v5 Tier 3a: workout sessions ride as WORKOUT_SESSION events with
      // value=duration_minutes. The backend uses the (start, end) range
      // to mark contained HR/HRV/etc samples as state=WORKOUT — the
      // numeric value itself isn't z-scored.
      numericValue = dp.dateTo.difference(dp.dateFrom).inSeconds / 60.0;
      if (numericValue <= 0) return null;
    } else if (dp.value is NumericHealthValue) {
      numericValue = (dp.value as NumericHealthValue).numericValue.toDouble();
      // HealthKit stores BLOOD_OXYGEN as a ratio (0.0–1.0); backend expects %.
      // iOS ONLY: Health Connect already returns a percentage (0–100), so the
      // unconditional ×100 would send e.g. 9500 — the server divides once,
      // gets 95.0, and rejects it against the (0.50, 1.0) fraction range,
      // voiding every Android SpO2 sample as invalid_physiological.
      if (lpMetric == 'SPO2_INSTANT' && Platform.isIOS) {
        numericValue = numericValue * 100;
      }
      // AFib burden is a percentage (0–100); convert to binary flag for AFIB_FLAG.
      if (lpMetric == 'AFIB_FLAG') {
        numericValue = numericValue > 0 ? 1.0 : 0.0;
      }
    } else {
      return null; // Unsupported value type
    }

    // Build algorithm_metadata for metrics where provenance matters for
    // cross-device scoring. HRV_SDNN from HealthKit is always Apple's algorithm.
    Map<String, dynamic>? algoMeta;
    if (lpMetric == 'HRV_SDNN') {
      algoMeta = {'hrv_method': 'SDNN', 'source_algorithm': 'HealthKit'};
    } else if (lpMetric == 'HRV_RMSSD') {
      algoMeta = {'hrv_method': 'RMSSD', 'source_algorithm': 'HealthConnect'};
    } else if (lpMetric == 'SLEEP_STAGE'
        || lpMetric == 'SLEEP_DEEP'
        || lpMetric == 'SLEEP_REM'
        || lpMetric == 'SLEEP_LIGHT') {
      // Even with granular metric_types in v4.4 we still record the staging
      // algorithm so quality scoring + audit can attribute the value.
      // sleep_stage echoes the metric_type for legibility in the audit log.
      algoMeta = {
        'staging_algorithm': 'watchOS_sleep',
        'sleep_stage': lpMetric == 'SLEEP_STAGE' ? dp.type.name : lpMetric,
      };
    } else if (lpMetric == 'WORKOUT_SESSION' && dp.value is WorkoutHealthValue) {
      // Carry the workout type + energy/distance into algorithm_metadata so
      // Tier 3b analytics (HR recovery, weekly active minutes by category)
      // have what they need without re-querying HealthKit.
      final w = dp.value as WorkoutHealthValue;
      algoMeta = {
        'workout_type': w.workoutActivityType.name,
        if (w.totalEnergyBurned != null) 'kcal': w.totalEnergyBurned,
        if (w.totalDistance != null) 'distance_m': w.totalDistance,
      };
    }

    // Extract source-level metadata from HealthKit MetadataEntry. Three keys
    // matter for our pipeline:
    //
    //   • HKMetadataKeyHeartRateMotionContext  ("0"=not set, "1"=sedentary, "2"=active)
    //     N6 used to consume this for state inference (REST/ACTIVE) — collapsed
    //     in v4.2 but the value is still surfaced for audit / Data Explorer.
    //
    //   • HKMetadataKeyHeartRateContext       ("streaming" | "sample")  iOS 17+
    //     "streaming" = continuous workout-period sampling (1 Hz), "sample" = a
    //     single passive background reading. Used by v4.8 baseline pollution
    //     filter to exclude streaming HR/HRV/etc from baseline math, since
    //     those samples reflect workout physiology not resting state.
    //
    //   • Workout-window membership is captured separately in the upload step
    //     (we annotate ``workout_window: true`` for events whose start_time_utc
    //     falls inside any HKWorkout interval pulled in the same sync). This
    //     is metric-agnostic and catches the post-exercise BP spike, HRV dip,
    //     etc. that no per-sample HK metadata flag covers.
    Map<String, String>? sourceMeta;
    if (dp.metadata != null && dp.metadata!.isNotEmpty) {
      final motionCtx = dp.metadata!['HKMetadataKeyHeartRateMotionContext'];
      final hrCtx     = dp.metadata!['HKMetadataKeyHeartRateContext'];
      sourceMeta = <String, String>{};
      if (motionCtx != null) sourceMeta['heart_rate_motion_context'] = motionCtx.toString();
      if (hrCtx != null)     sourceMeta['heart_rate_context']        = hrCtx.toString();
      if (sourceMeta.isEmpty) sourceMeta = null;
    }

    // Choose the unit that reflects what the backend will actually store after
    // any in-Flutter conversion (above). For AFib we converted % burden -> 0/1
    // flag; for SpO2 we converted fraction -> %.
    final String unitForPayload = switch (lpMetric) {
      'AFIB_FLAG' => 'flag',
      'SPO2_INSTANT' => '%',
      _ => _unitForType(dp.type),
    };

    // Recording method — previously never sent, so the server's Pydantic
    // default recorded EVERY sample as AUTOMATIC. Manually-entered values
    // were indistinguishable from sensor readings, inflating both the N7
    // quality score (+0.25 for AUTOMATIC) and fraud-detector confidence.
    final String recordingMethod = switch (dp.recordingMethod) {
      RecordingMethod.manual => 'MANUAL',
      RecordingMethod.automatic || RecordingMethod.active => 'AUTOMATIC',
      RecordingMethod.unknown => 'UNKNOWN',
    };

    return {
      'metric_type': lpMetric,
      'value': numericValue,
      'unit': unitForPayload,
      'recording_method': recordingMethod,
      'start_time': dp.dateFrom.toUtc().toIso8601String(),
      'end_time': dp.dateTo.toUtc().toIso8601String(),
      // tz_offset_min lets the backend daypart classifier (morning / afternoon /
      // evening / night) bucket events for non-UTC users correctly.
      'tz_offset_min': dp.dateFrom.timeZoneOffset.inMinutes,
      'source_device': dp.sourceName,
      'source_app_id': dp.sourceId,
      'device_model_raw': dp.deviceModel,
      'source_platform': Platform.isIOS ? 'HEALTHKIT' : 'HEALTH_CONNECT',
      if (algoMeta != null) 'algorithm_metadata': algoMeta,
      if (sourceMeta != null) 'source_metadata': sourceMeta,
    };
  }

  // Moved verbatim to lib/services/health_mapping.dart as
  // health_mapping.isSleepType (Phase 1.1 extraction).
  static bool _isSleepType(HealthDataType type) =>
      health_mapping.isSleepType(type);

  /// Drop SLEEP_ASLEEP records that overlap a night where granular
  /// DEEP/REM/LIGHT stages were also recorded — Apple Watch S6+ writes both,
  /// and uploading both inflates the backend sleep total. Two events overlap
  /// when their date ranges intersect. The stage set and interval-overlap
  /// predicate are moved verbatim to health_mapping.dart
  /// (granularSleepStages / sleepIntervalsOverlap) so the rule is testable
  /// on plain DateTime values.
  static List<HealthDataPoint> _dedupeOverlappingSleepAsleep(
    List<HealthDataPoint> points,
  ) {
    final granular = points
        .where((p) => health_mapping.granularSleepStages.contains(p.type))
        .toList();
    if (granular.isEmpty) return points;
    bool overlapsGranular(HealthDataPoint p) {
      for (final g in granular) {
        if (health_mapping.sleepIntervalsOverlap(
            p.dateFrom, p.dateTo, g.dateFrom, g.dateTo)) {
          return true;
        }
      }
      return false;
    }
    return points
        .where((p) =>
            p.type != HealthDataType.SLEEP_ASLEEP || !overlapsGranular(p))
        .toList();
  }

  // Moved verbatim to lib/services/health_mapping.dart as
  // health_mapping.healthTypeToLp (Phase 1.1 extraction).
  static String? _healthTypeToLp(HealthDataType type) =>
      health_mapping.healthTypeToLp(type, isIos: Platform.isIOS);

  // Moved verbatim to lib/services/health_mapping.dart as
  // health_mapping.unitForType (Phase 1.1 extraction).
  static String _unitForType(HealthDataType type) =>
      health_mapping.unitForType(type);

  // ── Retry helper ──────────────────────────────────────────────────────────
  /// Calls [fn] up to [maxAttempts] times with exponential backoff.
  /// Returns the first non-null result, or null if all attempts fail.
  static Future<T?> _withRetry<T>(
    Future<T?> Function() fn, {
    int maxAttempts = 3,
  }) async {
    for (int i = 0; i < maxAttempts; i++) {
      if (i > 0) await Future.delayed(Duration(seconds: i * 2));
      final result = await fn();
      if (result != null) return result;
    }
    return null;
  }

  // ── Token Refresh ─────────────────────────────────────────────────────────
  /// Guards concurrent refresh calls — only the first caller actually refreshes;
  /// subsequent callers await the same Future.
  static Future<void>? _ongoingRefresh;

  static Future<void> refreshTokenIfNeeded() async {
    if (_ongoingRefresh != null) {
      await _ongoingRefresh;
      return;
    }
    _ongoingRefresh = _doRefreshTokenIfNeeded();
    try {
      await _ongoingRefresh;
    } finally {
      _ongoingRefresh = null;
    }
  }

  static Future<void> _doRefreshTokenIfNeeded() async {
    final token = await _secureStorage.read(key: _keyJwtToken);
    if (token == null || token.isEmpty) return;

    // Decode expiry from JWT payload (base64 middle section)
    try {
      final parts = token.split('.');
      if (parts.length != 3) return;
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      ) as Map<String, dynamic>;
      final exp = (payload['exp'] as num?)?.toInt();
      if (exp == null) return;
      final expiresAt = DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
      final timeLeft = expiresAt.difference(DateTime.now().toUtc());
      if (timeLeft.inMinutes > 10) return; // Still fresh, skip
    } catch (e) {
      // JWT decode failed — token may be corrupted/truncated in Keychain.
      // Force a refresh attempt rather than waiting for a 401 at next API call.
      debugPrint('[HealthService.refreshTokenIfNeeded] Token decode failed, forcing refresh: $e');
    }

    // Refresh via API
    final baseUrl = await _baseUrl();
    Future<http.Response> hit() async {
      final oldToken = (await _secureStorage.read(key: _keyJwtToken)) ?? '';
      return http.post(
        Uri.parse('$baseUrl/api/v1/auth/refresh'),
        headers: {'Authorization': 'Bearer $oldToken'},
      ).timeout(const Duration(seconds: 10));
    }

    try {
      var resp = await hit();
      // Retry once on 401 to absorb a transient flake — refresh-token race
      // (two concurrent refreshes cannibalising each other) and CDN/edge
      // hiccups can produce a single false 401 that does NOT mean the user's
      // refresh token is actually dead. Logging them out for that is exactly
      // the bug pattern that strands testers on Today with a mute Retry.
      if (resp.statusCode == 401) {
        await Future.delayed(const Duration(seconds: 1));
        resp = await hit();
      }
      if (resp.statusCode == 200) {
        final decoded = jsonDecode(resp.body);
        final newToken = (decoded is Map) ? decoded['access_token'] as String? : null;
        if (newToken != null && newToken.isNotEmpty) {
          await _secureStorage.write(key: _keyJwtToken, value: newToken);
        }
      } else if (resp.statusCode == 401) {
        // Two consecutive 401s — refresh token is genuinely dead. Clear the
        // stored token and notify any visible screen so the user is taken to
        // /login immediately instead of landing on Today with a mute Retry.
        await _secureStorage.delete(key: _keyJwtToken);
        sessionExpired.value = true;
        debugPrint('[HealthService] Refresh token expired (401×2) — cleared stored token.');
      } else {
        // 5xx / unexpected — leave the old token in place. The next API call
        // either succeeds (server recovered) or hits its own 401 and triggers
        // sessionExpired through that path.
        debugPrint('[HealthService] Token refresh got HTTP ${resp.statusCode} — keeping token.');
      }
    } catch (e, st) {
      // Network error during refresh — leave the old token in place.
      // The splash screen re-checks isLoggedIn() after this call, so if
      // the token was already expired the user will hit 401 on the next API
      // call and sessionExpired will fire. This is acceptable for offline starts.
      debugPrint('[HealthService] Token refresh failed: $e\n$st');
    }
  }

  static Future<String> _baseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getString(_keyLpUrl) ?? kDefaultApiUrl)
        .trimRight()
        .replaceAll(RegExp(r'/+$'), '')
        // Security: force HTTPS — never transmit JWT or health data over HTTP.
        // Applies to all 8 callers: token refresh, daily/range reports,
        // anomalies, user profile, account deletion, and clearMyData.
        .replaceFirst(RegExp(r'^http://'), 'https://');
  }

  static Future<Map<String, String>> _authHeaders() async {
    final token = (await _secureStorage.read(key: _keyJwtToken)) ?? '';
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }

  // ── Daily Report ──────────────────────────────────────────────────────────
  static Future<DailyReport?> fetchDailyReport({String? date, bool forceRegen = false}) async {
    await refreshTokenIfNeeded();
    final userId = (await _secureStorage.read(key: _keyLpUserId)) ?? '';
    if (userId.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();

    final reportDate = date ?? DateTime.now().toIso8601String().substring(0, 10);
    final baseUrl = await _baseUrl();
    final regenParam = forceRegen ? '&force_regen=true' : '';

    DailyReport? result;
    try {
      final resp = await http.get(
        Uri.parse('$baseUrl/api/v1/reports/daily/$userId?report_date=$reportDate$regenParam'),
        headers: await _authHeaders(),
      ).timeout(const Duration(seconds: 15));
      if (resp.statusCode == 401) {
        sessionExpired.value = true;
      } else if (resp.statusCode == 200) {
        result = DailyReport.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
        // Save to offline cache with timestamp
        await prefs.setString(_keyCachedDailyReport, resp.body);
        await prefs.setString(
          _keyCachedDailyReportAt,
          DateTime.now().toIso8601String(),
        );
        await prefs.setBool(_keyCachedDailyReportStale, false);
      }
    } catch (e) {
      debugPrint('[HealthService.fetchDailyReport] $e');
    }

    if (result != null) return result;

    // On failure: try returning cached data
    final cached = prefs.getString(_keyCachedDailyReport);
    if (cached == null) return null;
    try {
      final cachedAt = DateTime.tryParse(
        prefs.getString(_keyCachedDailyReportAt) ?? '',
      );
      final isStale =
          cachedAt == null || DateTime.now().difference(cachedAt).inHours >= 24;
      await prefs.setBool(_keyCachedDailyReportStale, isStale);
      return DailyReport.fromJson(jsonDecode(cached) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Fetch the member's personal baseline median per metric.
  ///
  /// Used by the Risk tab's per-metric Signals panel (v4.6) to compute the
  /// "your usual: X" reference next to each of today's readings. Prefers the
  /// ALL state baseline; falls back to whichever state has the highest sample
  /// count (for state-sensitive metrics like HR_INSTANT where the SLEEP
  /// baseline may be more mature than ALL on a new user).
  ///
  /// Returns an empty map on auth/network failure — UI then shows "no
  /// baseline yet" instead of crashing.
  static Future<Map<String, double>> fetchBaselines() async {
    await refreshTokenIfNeeded();
    final userId = (await _secureStorage.read(key: _keyLpUserId)) ?? '';
    if (userId.isEmpty) return const {};

    final baseUrl = await _baseUrl();
    try {
      final resp = await http.get(
        Uri.parse('$baseUrl/api/v1/baselines?user_id=$userId'),
        headers: await _authHeaders(),
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 401) {
        sessionExpired.value = true;
        return const {};
      }
      if (resp.statusCode != 200) return const {};

      final body = jsonDecode(resp.body);
      final List rows = body is Map
          ? (body['baselines'] as List? ?? const [])
          : (body as List? ?? const []);

      // Pick the best baseline per metric: prefer state == 'ALL', else highest
      // sample_count. (BaselineEngine builds per-state rows; we want one per
      // metric for the tile.)
      final picks = <String, Map<String, dynamic>>{};
      for (final raw in rows) {
        if (raw is! Map) continue;
        final mt = raw['metric_type'] as String?;
        if (mt == null) continue;
        final state = (raw['state'] as String?) ?? 'ALL';
        final count = (raw['sample_count'] as num?)?.toInt() ?? 0;
        final cur = picks[mt];
        if (cur == null) {
          picks[mt] = Map<String, dynamic>.from(raw);
        } else {
          final curState = (cur['state'] as String?) ?? 'ALL';
          final curCount = (cur['sample_count'] as num?)?.toInt() ?? 0;
          if (state == 'ALL' && curState != 'ALL') {
            picks[mt] = Map<String, dynamic>.from(raw);
          } else if (state == curState && count > curCount) {
            picks[mt] = Map<String, dynamic>.from(raw);
          }
        }
      }

      final out = <String, double>{};
      for (final entry in picks.entries) {
        final m = (entry.value['median'] as num?)?.toDouble();
        if (m != null) out[entry.key] = m;
      }
      return out;
    } catch (e) {
      debugPrint('[HealthService.fetchBaselines] $e');
      return const {};
    }
  }

  /// Fetches the backend reconciliation report — per canonical metric, how
  /// many raw events were uploaded vs. accepted / deduped / rejected by the
  /// pipeline over the last [days] days. Pairs with an on-device CensusReport
  /// (see lib/services/census_compare.dart) for end-to-end diagnostics.
  ///
  /// Unlike the cache-backed fetchers above this throws on failure — it backs
  /// a dev/diagnostics screen that surfaces the error directly rather than a
  /// stale value.
  static Future<ReconciliationResponse> fetchReconciliation({int days = 180}) async {
    await refreshTokenIfNeeded();
    final baseUrl = await _baseUrl();
    final resp = await http.get(
      Uri.parse('$baseUrl/api/v1/data/reconciliation?days=$days'),
      headers: await _authHeaders(),
    ).timeout(const Duration(seconds: 15));
    if (resp.statusCode == 401) {
      sessionExpired.value = true;
      throw Exception('Reconciliation fetch failed: session expired (HTTP 401).');
    }
    if (resp.statusCode != 200) {
      throw Exception(
          'Reconciliation fetch failed: HTTP ${resp.statusCode}.');
    }
    return ReconciliationResponse.fromJson(
        jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// Fetches the server's per-metric `latest_event_times` map — the same
  /// anchor endpoint the incremental sync path reads in [_doSyncDirect] — so
  /// the Dev Tools Sync State card can show exactly where the server thinks
  /// each metric stands. Returns canonical `metric_type` → ISO-8601 string.
  ///
  /// Backs a dev/diagnostics screen: throws on HTTP failure so the caller can
  /// surface the error directly rather than a stale value.
  static Future<Map<String, String>> fetchLatestEventTimes() async {
    await refreshTokenIfNeeded();
    final baseUrl = await _baseUrl();
    final resp = await http.get(
      Uri.parse('$baseUrl/api/v1/data/latest-event-time'),
      headers: await _authHeaders(),
    ).timeout(const Duration(seconds: 15));
    if (resp.statusCode == 401) {
      sessionExpired.value = true;
      throw Exception('Latest-event-time fetch failed: session expired (HTTP 401).');
    }
    if (resp.statusCode != 200) {
      throw Exception('Latest-event-time fetch failed: HTTP ${resp.statusCode}.');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final raw = body['latest_event_times'] as Map<String, dynamic>? ?? const {};
    final out = <String, String>{};
    raw.forEach((k, v) {
      if (v is String && v.isNotEmpty) out[k] = v;
    });
    return out;
  }

  /// Returns true if the most recently fetched daily report came from cache
  /// and is older than 24 hours.
  static Future<bool> isDailyReportCacheStale() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyCachedDailyReportStale) ?? false;
  }

  /// Returns the timestamp when the daily report was last successfully cached,
  /// or null if no cache exists.
  static Future<DateTime?> getDailyReportCachedAt() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyCachedDailyReportAt);
    return raw != null ? DateTime.tryParse(raw) : null;
  }

  // ── Range Report (for trends) ─────────────────────────────────────────────
  static Future<RangeReport?> fetchRangeReport({required int days}) async {
    await refreshTokenIfNeeded();
    final userId = (await _secureStorage.read(key: _keyLpUserId)) ?? '';
    if (userId.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();

    final endDate = DateTime.now().toIso8601String().substring(0, 10);
    final startDate = DateTime.now()
        .subtract(Duration(days: days))
        .toIso8601String()
        .substring(0, 10);
    final baseUrl = await _baseUrl();
    final cacheKey = '$_keyCachedRangeReportPrefix$days';
    final cacheAtKey = '${cacheKey}_at';
    final cacheStaleKey = '${cacheKey}_stale';

    RangeReport? result;
    try {
      final resp = await http.get(
        Uri.parse('$baseUrl/api/v1/reports/range/$userId'
            '?start_date=$startDate&end_date=$endDate&aggregate_by=day'),
        headers: await _authHeaders(),
      ).timeout(const Duration(seconds: 20));
      if (resp.statusCode == 401) {
        sessionExpired.value = true;
      } else if (resp.statusCode == 200) {
        result = RangeReport.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
        await prefs.setString(cacheKey, resp.body);
        await prefs.setString(cacheAtKey, DateTime.now().toIso8601String());
        await prefs.setBool(cacheStaleKey, false);
      }
    } catch (e) {
      debugPrint('[HealthService.fetchRangeReport] $e');
    }

    if (result != null) return result;

    // On failure: try returning cached data
    final cached = prefs.getString(cacheKey);
    if (cached == null) return null;
    try {
      final cachedAt = DateTime.tryParse(prefs.getString(cacheAtKey) ?? '');
      final isStale =
          cachedAt == null || DateTime.now().difference(cachedAt).inHours >= 24;
      await prefs.setBool(cacheStaleKey, isStale);
      return RangeReport.fromJson(jsonDecode(cached) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Returns true when the range report for [days] was loaded from stale cache.
  static Future<bool> isRangeReportCacheStale({required int days}) async {
    final prefs = await SharedPreferences.getInstance();
    // ignore: unnecessary_brace_in_string_interps — ${days} braces required: bare $days would parse _stale as part of the identifier
    return prefs.getBool('${_keyCachedRangeReportPrefix}${days}_stale') ?? false;
  }

  /// Returns the timestamp when the range report for [days] was last cached.
  static Future<DateTime?> getRangeReportCachedAt({required int days}) async {
    final prefs = await SharedPreferences.getInstance();
    // ignore: unnecessary_brace_in_string_interps
    final raw = prefs.getString('${_keyCachedRangeReportPrefix}${days}_at');
    return raw != null ? DateTime.tryParse(raw) : null;
  }

  /// Fetches a range report for an explicit date range (used by the custom
  /// date picker in the Trends screen).
  static Future<RangeReport?> fetchRangeReportByDates({
    required DateTime start,
    required DateTime end,
  }) async {
    await refreshTokenIfNeeded();
    final userId = (await _secureStorage.read(key: _keyLpUserId)) ?? '';
    if (userId.isEmpty) return null;

    final startDate = start.toIso8601String().substring(0, 10);
    final endDate = end.toIso8601String().substring(0, 10);
    final baseUrl = await _baseUrl();

    return await _withRetry(() async {
      try {
        final resp = await http.get(
          Uri.parse('$baseUrl/api/v1/reports/range/$userId'
              '?start_date=$startDate&end_date=$endDate&aggregate_by=day'),
          headers: await _authHeaders(),
        ).timeout(const Duration(seconds: 20));
        if (resp.statusCode == 401) {
          sessionExpired.value = true;
          return null;
        }
        if (resp.statusCode == 200) {
          return RangeReport.fromJson(
            jsonDecode(resp.body) as Map<String, dynamic>,
          );
        }
      } catch (e) {
        debugPrint('[HealthService.fetchRangeReportByDates] $e');
      }
      return null;
    });
  }

  // ── Anomalies ─────────────────────────────────────────────────────────────
  static Future<List<AnomalyItem>> fetchAnomalies({int limit = 30}) async {
    await refreshTokenIfNeeded();
    final userId = (await _secureStorage.read(key: _keyLpUserId)) ?? '';
    if (userId.isEmpty) return [];

    final baseUrl = await _baseUrl();

    try {
      final resp = await http.get(
        Uri.parse('$baseUrl/api/v1/anomalies?user_id=$userId&limit=$limit'),
        headers: await _authHeaders(),
      ).timeout(const Duration(seconds: 15));

      if (resp.statusCode == 401) {
        sessionExpired.value = true;
        return [];
      }
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        final items = body['items'] as List<dynamic>? ?? [];
        return items
            .map((e) => AnomalyItem.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      debugPrint('[HealthService.fetchAnomalies] $e');
    }
    return [];
  }

  // ── User Profile ──────────────────────────────────────────────────────────
  static Future<Map<String, dynamic>?> fetchUserProfile() async {
    await refreshTokenIfNeeded();
    final baseUrl = await _baseUrl();
    try {
      final resp = await http.get(
        Uri.parse('$baseUrl/api/v1/auth/me'),
        headers: await _authHeaders(),
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 401) {
        sessionExpired.value = true;
        return null;
      }
      if (resp.statusCode == 200) {
        final decoded = jsonDecode(resp.body);
        if (decoded is! Map<String, dynamic>) {
          debugPrint('[HealthService.fetchUserProfile] Unexpected response type: ${decoded.runtimeType}');
          return null;
        }
        return decoded;
      }
    } catch (e) {
      debugPrint('[HealthService.fetchUserProfile] $e');
    }
    return null;
  }

  // ── Account Deletion ──────────────────────────────────────────────────────
  /// Permanently deletes the current user's account and all associated data.
  /// Required by App Store guidelines for apps that support account creation.
  /// Returns true on success, false on failure.
  static Future<bool> deleteAccount() async {
    await refreshTokenIfNeeded();
    final baseUrl = await _baseUrl();
    try {
      final resp = await http.delete(
        Uri.parse('$baseUrl/api/v1/auth/account'),
        headers: await _authHeaders(),
      ).timeout(const Duration(seconds: 20));
      return resp.statusCode == 200 || resp.statusCode == 204;
    } catch (e) {
      debugPrint('[HealthService.deleteAccount] $e');
      return false;
    }
  }

  // ── Dev/Test: Clear My Data ───────────────────────────────────────────────
  /// DEV ONLY — deletes all health data for the current user.
  /// Used for resetting between test runs with real Apple Watch.
  /// Returns a summary of deleted counts, or null on failure.
  static Future<Map<String, dynamic>?> clearMyData() async {
    // Hard guard: this method must never run in a release build.
    // The UI already hides the button via kDebugMode, but this throws at runtime
    // if clearMyData() is accidentally called from any other code path.
    // (assert is eliminated by the compiler in release mode — throw is not.)
    if (kReleaseMode) {
      throw StateError('clearMyData() must not be called in release builds');
    }
    await refreshTokenIfNeeded();
    final baseUrl = await _baseUrl();
    try {
      final resp = await http.delete(
        Uri.parse('$baseUrl/api/v1/data/my-data'),
        headers: await _authHeaders(),
      ).timeout(const Duration(seconds: 20));
      if (resp.statusCode == 200) {
        return jsonDecode(resp.body) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('[HealthService.clearMyData] $e');
    }
    return null;
  }
}
