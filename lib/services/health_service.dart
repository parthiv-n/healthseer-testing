import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show ValueNotifier, debugPrint, kReleaseMode;
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

// ── Default API config (demo / TestFlight) ───────────────────────────────────
const kDefaultApiUrl = 'https://lifepulse-api-63410932899.us-central1.run.app';
const kTenantSlug = 'tikcare';

/// Connection mode: OW = full chain via Open Wearables (unavailable — SDK removed);
/// Direct = read HealthKit via `health` package, POST to LifePulse Partner API directly.
enum SyncMode { openWearables, direct }

/// Classifies the type of error that occurred during a sync or data fetch.
enum SyncErrorType { network, noData, serverError, authExpired, permissionDenied, unknown }

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
List<HealthDataType> _platformSyncTypes() {
  if (Platform.isIOS) {
    return const [
      HealthDataType.HEART_RATE,
      HealthDataType.HEART_RATE_VARIABILITY_SDNN,
      HealthDataType.STEPS,
      HealthDataType.BLOOD_OXYGEN,
      HealthDataType.ACTIVE_ENERGY_BURNED,
      HealthDataType.RESTING_HEART_RATE,
      HealthDataType.DISTANCE_WALKING_RUNNING,
      HealthDataType.FLIGHTS_CLIMBED,
      HealthDataType.EXERCISE_TIME,
      HealthDataType.BASAL_ENERGY_BURNED,
    ];
  } else {
    return const [
      HealthDataType.HEART_RATE,
      HealthDataType.HEART_RATE_VARIABILITY_RMSSD,
      HealthDataType.STEPS,
      HealthDataType.BLOOD_OXYGEN,
      HealthDataType.ACTIVE_ENERGY_BURNED,
      HealthDataType.RESTING_HEART_RATE,
      HealthDataType.DISTANCE_WALKING_RUNNING,
      HealthDataType.FLIGHTS_CLIMBED,
      HealthDataType.EXERCISE_TIME,
      HealthDataType.BASAL_ENERGY_BURNED,
    ];
  }
}

/// Optional types only available on newer hardware or specific accessories.
/// Fetched separately with null-safe handling — missing data is silently ignored.
///
/// Blood pressure: requires a 3rd-party BP cuff app writing to HealthKit
///   (e.g. Withings, Omron). Apple Watch does NOT measure BP directly.
///
/// VO2MAX: changes very slowly (weeks/months) — collected in the normal batch
///   window just like all other metrics. Works on Apple Watch Series 3+.
///   Note: enum is HealthDataType.VO2MAX (no underscore), maps to ml/kg/min.
///
/// NOT available in health package v12.x (no enum constant):
///   - SLEEP_APNEA_EVENT (HKCategoryTypeIdentifierApneaEvents) — category type,
///     not wrapped by health package. Requires native platform channel or file export.
///   - APPLE_STAND_TIME, WALKING_SPEED — not in HealthDataType enum.
const _optionalSyncTypes = [
  HealthDataType.RESPIRATORY_RATE,
  HealthDataType.BLOOD_PRESSURE_SYSTOLIC,
  HealthDataType.BLOOD_PRESSURE_DIASTOLIC,
  HealthDataType.VO2MAX,
];


class HealthService {
  // ── Secure credential storage (iOS Keychain / Android Keystore) ───────────
  // JWT tokens and API keys are stored here instead of SharedPreferences to
  // prevent exposure via iCloud backups and on jailbroken/rooted devices.
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
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

      if (response.statusCode == 201) {
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
    await Workmanager().cancelByUniqueName('periodicHealthSync');
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
  }

  /// Register a background sync task that fires every 6 hours.
  /// Must be called after login and register so the task persists even when
  /// the user doesn't open the app.
  static Future<void> registerBackgroundSync() async {
    await Workmanager().registerPeriodicTask(
      'periodicHealthSync',
      'lifepulse.periodicSync',
      frequency: const Duration(hours: 6),
      existingWorkPolicy: ExistingWorkPolicy.keep,
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
    // Request ALL types that _doSyncDirect() uses — core + sleep + optional.
    // If we only request core types here, the user would miss granting sleep
    // and respiratory permissions, causing silent data gaps during sync.
    final coreTypes = _platformSyncTypes();
    final sleepType = Platform.isIOS ? HealthDataType.SLEEP_IN_BED : HealthDataType.SLEEP_SESSION;
    final allTypes = [...coreTypes, sleepType, ..._optionalSyncTypes];
    return await Health().requestAuthorization(allTypes);
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

  static Future<SyncResult> syncViaOW({
    void Function(String)? onLog,
  }) async {
    onLog?.call('⚠️  Open Wearables sync path is not available in this build.');
    onLog?.call('   Switch to Direct mode in Config to sync via LifePulse Partner API.');
    return SyncResult(
      success: false,
      message: 'OW sync path unavailable. Use Direct mode.',
    );
  }

  // ── Local HealthKit snapshot (offline, today only) ────────────────────────
  /// Reads today's HealthKit data and returns a local snapshot for immediate
  /// display. Does NOT require the LifePulse server to be reachable.
  static Future<HealthSnapshot> fetchTodaySnapshot() async {
    try {
      await ensureHealthConfigured();
      // Permissions are requested once in syncDirect(). Here we just read
      // whatever the OS allows without showing another authorization dialog.

      final now = DateTime.now();
      final startOfDay = DateTime(now.year, now.month, now.day);
      // For sleep: look back from midnight last night (18:00 yesterday → now)
      final sleepStart = startOfDay.subtract(const Duration(hours: 6));

      // Fetch HR + HRV + Steps for today.
      // iOS uses SDNN; Android Health Connect only supports RMSSD.
      final hrvType = Platform.isIOS
          ? HealthDataType.HEART_RATE_VARIABILITY_SDNN
          : HealthDataType.HEART_RATE_VARIABILITY_RMSSD;
      // Fetch day metrics and sleep in parallel — independent queries.
      // Each wrapped in catchError so a failure in one doesn't discard the other.
      final results = await Future.wait([
        Health().getHealthDataFromTypes(
          types: [HealthDataType.HEART_RATE, hrvType, HealthDataType.STEPS],
          startTime: startOfDay,
          endTime: now,
        ).catchError((_) => <HealthDataPoint>[]),
        Health().getHealthDataFromTypes(
          types: [Platform.isIOS ? HealthDataType.SLEEP_IN_BED : HealthDataType.SLEEP_SESSION],
          startTime: sleepStart,
          endTime: now,
        ).catchError((_) => <HealthDataPoint>[]),
      ]);
      final dedupedDay = Health().removeDuplicates(results[0]);
      final dedupedSleep = Health().removeDuplicates(results[1]);

      // Compute HR average
      final hrValues = dedupedDay
          .where((p) => p.type == HealthDataType.HEART_RATE && p.value is NumericHealthValue)
          .map((p) => (p.value as NumericHealthValue).numericValue.toDouble())
          .toList();
      final avgHr = hrValues.isEmpty
          ? null
          : hrValues.reduce((a, b) => a + b) / hrValues.length;

      // Compute steps total
      final stepValues = dedupedDay
          .where((p) => p.type == HealthDataType.STEPS && p.value is NumericHealthValue)
          .map((p) => (p.value as NumericHealthValue).numericValue.toDouble())
          .toList();
      final totalSteps =
          stepValues.isEmpty ? null : stepValues.reduce((a, b) => a + b).toInt();

      // Compute latest HRV (type is platform-dependent, captured above)
      final hrvPoints = dedupedDay
          .where((p) => p.type == hrvType && p.value is NumericHealthValue)
          .toList()
        ..sort((a, b) => b.dateFrom.compareTo(a.dateFrom));
      final latestHrv = hrvPoints.isEmpty
          ? null
          : (hrvPoints.first.value as NumericHealthValue).numericValue.toDouble();

      // Compute sleep hours
      double sleepSec = 0;
      for (final p in dedupedSleep) {
        sleepSec += p.dateTo.difference(p.dateFrom).inSeconds;
      }
      final sleepHours = dedupedSleep.isEmpty ? null : sleepSec / 3600.0;

      // Determine the primary data source from today's HR readings.
      // The most frequent source wins (e.g. "Apple Watch" vs "Garmin Connect").
      final hrPoints = dedupedDay
          .where((p) => p.type == HealthDataType.HEART_RATE)
          .toList();
      String? primarySource;
      if (hrPoints.isNotEmpty) {
        final sourceCounts = <String, int>{};
        for (final p in hrPoints) {
          sourceCounts[p.sourceName] = (sourceCounts[p.sourceName] ?? 0) + 1;
        }
        primarySource = sourceCounts.entries
            .reduce((a, b) => a.value >= b.value ? a : b)
            .key;
      }

      return HealthSnapshot(
        avgHr: avgHr != null ? double.parse(avgHr.toStringAsFixed(0)) : null,
        steps: totalSteps,
        sleepHours: sleepHours != null
            ? double.parse(sleepHours.toStringAsFixed(1))
            : null,
        hrv: latestHrv != null
            ? double.parse(latestHrv.toStringAsFixed(0))
            : null,
        fetchedAt: now,
        primarySource: primarySource,
      );
    } catch (e) {
      debugPrint('[HealthService.fetchTodaySnapshot] $e');
      return HealthSnapshot(fetchedAt: DateTime.now());
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
      ).timeout(const Duration(seconds: 15));

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

      final latestUpload = body['latest_upload'] as Map? ?? {};
      final fraudScore = (latestUpload['fraud_risk_score'] as num?)?.toDouble();

      final insight = RiskInsight(
        hriScore: (body['hri_score'] as num? ?? 0).toInt(),
        hriLabel: body['hri_label'] as String? ?? 'low',
        anomalyBreakdown: anomalyBreakdown,
        latestAnomalies: latestAnomalies,
        fraudRiskScore: fraudScore,
        fetchedAt: DateTime.now(),
      );

      // Cache for offline use
      await _cacheInsight(insight, body);
      onLog?.call('✅ Risk insights updated (HRI: ${insight.hriScore})');
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
      return RiskInsight(
        hriScore: (body['hri_score'] as num? ?? 0).toInt(),
        hriLabel: body['hri_label'] as String? ?? 'low',
        anomalyBreakdown: anomalyBreakdown,
        latestAnomalies: latestAnomalies,
        // fraudRiskScore is never written to the cache (stripped in _cacheInsight).
        // Always null here — do NOT read it from the unencrypted cache.
        fraudRiskScore: null,
        fetchedAt: DateTime.tryParse(body['_cached_at'] as String? ?? '') ?? DateTime.now(),
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
  }) {
    if (_ongoingSync != null) {
      onLog?.call('ℹ️  Sync already running — waiting for it to complete…');
      return _ongoingSync!;
    }
    _ongoingSync = _doSyncDirect(onLog: onLog, maxDays: maxDays).whenComplete(() {
      _ongoingSync = null;
    });
    return _ongoingSync!;
  }

  /// Smart incremental sync:
  ///   - First sync (no anchor): pulls the last 180 days to build a baseline
  ///   - Subsequent syncs: pulls from (server anchor − 2h) to cover HealthKit write latency
  ///   - Fallback on network error: pulls the last 2 days
  ///
  /// Sleep data uses a separate window (yesterday 18:00 → now) because sleep spans
  /// midnight and needs to be fetched relative to the prior evening.
  static const _keySyncInProgress = 'sync_in_progress_at';

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
      return SyncResult(success: false, message: 'Not logged in. Please sign in first.');
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
            // New user — pull 180 days to build a rich baseline from day one
            startTime = endTime.subtract(const Duration(days: 180));
            onLog?.call('First sync detected — fetching last 180 days to build baseline…');
          } else {
            final anchor = DateTime.tryParse(rawAnchor);
            if (anchor == null) {
              // Malformed anchor from server — fall back to full 180-day re-sync
              startTime = endTime.subtract(const Duration(days: 180));
              onLog?.call('Invalid sync anchor — falling back to full 180-day re-sync…');
            } else {
              startTime = anchor.subtract(const Duration(hours: 2));
              onLog?.call('Incremental sync from ${anchor.toLocal().toString().substring(0, 16)}…');
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
      final coreTypes = _platformSyncTypes();
      final sleepType = Platform.isIOS ? HealthDataType.SLEEP_IN_BED : HealthDataType.SLEEP_SESSION;
      final allTypes = [...coreTypes, sleepType, ..._optionalSyncTypes];

      onLog?.call(Platform.isIOS ? 'Requesting HealthKit permissions…' : 'Requesting Health Connect permissions…');
      final granted = await Health().requestAuthorization(allTypes);
      if (!granted) {
        return SyncResult(
          success: false,
          message: Platform.isIOS
              ? 'Apple Health access is required. Tap "Grant Permission" below, or open the Health app → Sharing → Apps → TikCare LifePulse and enable all categories.'
              : 'Health Connect permission denied. Please grant access and try again.',
          errorType: SyncErrorType.permissionDenied,
        );
      }

      // ── Step 3–5: Fetch core, sleep, optional metrics in parallel ────────
      onLog?.call('Fetching health data…');

      // Sleep spans midnight: always look back to yesterday 18:00 at minimum,
      // but respect the incremental startTime if it's earlier.
      final sleepWindowStart = [
        startTime,
        DateTime(endTime.year, endTime.month, endTime.day)
            .subtract(const Duration(hours: 6)), // yesterday 18:00
      ].reduce((a, b) => a.isBefore(b) ? a : b);

      final fetchResults = await Future.wait([
        Health().getHealthDataFromTypes(
          types: coreTypes,
          startTime: startTime,
          endTime: endTime,
        ),
        Health().getHealthDataFromTypes(
          types: [sleepType],
          startTime: sleepWindowStart,
          endTime: endTime,
        ),
        // Optional types may fail on unsupported devices — catch inline.
        Health().getHealthDataFromTypes(
          types: _optionalSyncTypes,
          startTime: startTime,
          endTime: endTime,
        ).catchError((_) => <HealthDataPoint>[]),
      ]);

      // ── Step 6: Combine, deduplicate, convert ─────────────────────────────
      final allPoints = Health().removeDuplicates([
        ...fetchResults[0],
        ...fetchResults[1],
        ...fetchResults[2],
      ]);
      onLog?.call('Fetched ${allPoints.length} data points.');

      // Collect unique source device names for UI display
      final sourceDevices = allPoints
          .map((p) => p.sourceName)
          .where((n) => n.isNotEmpty)
          .toSet()
          .toList();

      if (allPoints.isEmpty) {
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
            message: 'Apple Health access is required. Tap "Grant Permission" below, or open the Health app → Sharing → Apps → TikCare LifePulse and enable all categories.',
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

      final events = allPoints
          .map(_convertToMobileSyncEvent)
          .whereType<Map<String, dynamic>>()
          .toList();

      // ── Step 7: POST in batches of 2000 (handles large first-sync) ────────
      const batchSize = 2000;
      int totalSent = 0;
      Map<String, dynamic>? lastBody;
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
              body: jsonEncode({'events': batch}),
            ).timeout(const Duration(seconds: 45));
            // Don't retry on success or auth failure
            if (response.statusCode != 429 && response.statusCode != 503) break;
          } catch (_) {
            // Network error — will retry
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
          totalSent += batch.length;
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
          ...?lastBody,
          'events_received': totalSent,
          'source_devices': sourceDevices,
        },
      );

    } catch (e) {
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
  static Future<SyncResult> pingLifePulse() async {
    final lpUrl = await _baseUrl();
    try {
      final response = await http
          .get(Uri.parse('$lpUrl/api/v1/health'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        return SyncResult(
          success: true,
          message: 'LifePulse API is online.',
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

  // ── Helpers ───────────────────────────────────────────────────────────────
  static Map<String, dynamic>? _convertToMobileSyncEvent(HealthDataPoint dp) {
    final lpMetric = _healthTypeToLp(dp.type);
    if (lpMetric == null) return null;

    double numericValue;
    if (dp.type == HealthDataType.SLEEP_IN_BED ||
        dp.type == HealthDataType.SLEEP_SESSION) {
      // Sleep events represent a time range — convert duration to minutes.
      numericValue = dp.dateTo.difference(dp.dateFrom).inSeconds / 60.0;
      if (numericValue <= 0) return null;
    } else if (dp.value is NumericHealthValue) {
      numericValue = (dp.value as NumericHealthValue).numericValue.toDouble();
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
    } else if (lpMetric == 'SLEEP_STAGE') {
      algoMeta = {'staging_algorithm': 'watchOS_sleep'};
    } else if (lpMetric == 'VO2_MAX') {
      algoMeta = {'source_algorithm': 'HealthKit_VO2Max'};
    }

    return {
      'metric_type': lpMetric,
      'value': numericValue,
      'unit': _unitForType(dp.type),
      'start_time': dp.dateFrom.toUtc().toIso8601String(),
      'end_time': dp.dateTo.toUtc().toIso8601String(),
      'source_device': dp.sourceName,
      'source_platform': Platform.isIOS ? 'HEALTHKIT' : 'HEALTH_CONNECT',
      if (algoMeta != null) 'algorithm_metadata': algoMeta,
    };
  }

  static String? _healthTypeToLp(HealthDataType type) {
    const map = {
      // Core metrics
      HealthDataType.HEART_RATE: 'HR_INSTANT',
      HealthDataType.HEART_RATE_VARIABILITY_SDNN: 'HRV_SDNN',    // iOS
      HealthDataType.HEART_RATE_VARIABILITY_RMSSD: 'HRV_RMSSD',  // Android
      HealthDataType.STEPS: 'STEPS_DELTA',
      HealthDataType.BLOOD_OXYGEN: 'SPO2_INSTANT',
      HealthDataType.ACTIVE_ENERGY_BURNED: 'ENERGY_DELTA',
      HealthDataType.RESTING_HEART_RATE: 'RHR_DAILY',
      // Extended metrics (added v2.6)
      HealthDataType.DISTANCE_WALKING_RUNNING: 'DISTANCE_DELTA',
      HealthDataType.FLIGHTS_CLIMBED: 'FLOORS_CLIMBED',
      HealthDataType.EXERCISE_TIME: 'EXERCISE_TIME',
      HealthDataType.BASAL_ENERGY_BURNED: 'ENERGY_BASAL',
      // Sleep (duration computed from time range)
      HealthDataType.SLEEP_IN_BED: 'SLEEP_STAGE',    // iOS
      HealthDataType.SLEEP_SESSION: 'SLEEP_STAGE',   // Android
      // Optional (Apple Watch S6+ / 3rd-party accessories)
      HealthDataType.RESPIRATORY_RATE: 'RESP_RATE',
      HealthDataType.BLOOD_PRESSURE_SYSTOLIC: 'BP_SYSTOLIC',
      HealthDataType.BLOOD_PRESSURE_DIASTOLIC: 'BP_DIASTOLIC',
      HealthDataType.VO2MAX: 'VO2_MAX',
    };
    return map[type];
  }

  static String _unitForType(HealthDataType type) {
    const map = {
      HealthDataType.HEART_RATE: 'bpm',
      HealthDataType.HEART_RATE_VARIABILITY_SDNN: 'ms',
      HealthDataType.HEART_RATE_VARIABILITY_RMSSD: 'ms',
      HealthDataType.STEPS: 'count',
      HealthDataType.BLOOD_OXYGEN: '%',
      HealthDataType.ACTIVE_ENERGY_BURNED: 'kcal',
      HealthDataType.RESTING_HEART_RATE: 'bpm',
      // Extended metrics
      HealthDataType.DISTANCE_WALKING_RUNNING: 'm',
      HealthDataType.FLIGHTS_CLIMBED: 'count',
      HealthDataType.EXERCISE_TIME: 'min',
      HealthDataType.BASAL_ENERGY_BURNED: 'kcal',
      // Sleep
      HealthDataType.SLEEP_IN_BED: 'min',
      HealthDataType.SLEEP_SESSION: 'min',
      // Optional
      HealthDataType.RESPIRATORY_RATE: 'breaths/min',
      HealthDataType.BLOOD_PRESSURE_SYSTOLIC: 'mmHg',
      HealthDataType.BLOOD_PRESSURE_DIASTOLIC: 'mmHg',
      HealthDataType.VO2MAX: 'ml/kg/min',
    };
    return map[type] ?? 'unknown';
  }

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
      // Log for debugging; the next API call will return 401 and trigger sessionExpired.
      debugPrint('[HealthService.refreshTokenIfNeeded] Token decode failed: $e');
      return;
    }

    // Refresh via API
    final baseUrl = await _baseUrl();
    try {
      final oldToken = (await _secureStorage.read(key: _keyJwtToken)) ?? '';
      final resp = await http.post(
        Uri.parse('$baseUrl/api/v1/auth/refresh'),
        headers: {'Authorization': 'Bearer $oldToken'},
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final decoded = jsonDecode(resp.body);
        final newToken = (decoded is Map) ? decoded['access_token'] as String? : null;
        if (newToken != null && newToken.isNotEmpty) {
          await _secureStorage.write(key: _keyJwtToken, value: newToken);
        }
      } else if (resp.statusCode == 401) {
        // Token is fully expired and cannot be refreshed.
        // Clear it so isLoggedIn() returns false and the splash screen routes
        // directly to /login instead of letting the home screen flash with
        // cached data and then forcibly redirect.
        await _secureStorage.delete(key: _keyJwtToken);
        debugPrint('[HealthService] Refresh token expired (401) — cleared stored token.');
      }
    } catch (e) {
      // Network error during refresh — leave the old token in place.
      // The splash screen re-checks isLoggedIn() after this call, so if
      // the token was already expired the user will hit 401 on the next API
      // call and sessionExpired will fire. This is acceptable for offline starts.
      debugPrint('[HealthService] Token refresh failed: $e');
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
  static Future<DailyReport?> fetchDailyReport({String? date}) async {
    await refreshTokenIfNeeded();
    final userId = (await _secureStorage.read(key: _keyLpUserId)) ?? '';
    if (userId.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();

    final reportDate = date ?? DateTime.now().toIso8601String().substring(0, 10);
    final baseUrl = await _baseUrl();

    DailyReport? result;
    try {
      final resp = await http.get(
        Uri.parse('$baseUrl/api/v1/reports/daily/$userId?report_date=$reportDate'),
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
