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
  // v3.0: removed ACTIVE_ENERGY_BURNED, DISTANCE_WALKING_RUNNING,
  // FLIGHTS_CLIMBED, BASAL_ENERGY_BURNED (low actuarial value, no backend mapping).
  if (Platform.isIOS) {
    return const [
      HealthDataType.HEART_RATE,
      HealthDataType.HEART_RATE_VARIABILITY_SDNN,
      HealthDataType.STEPS,
      HealthDataType.BLOOD_OXYGEN,
      HealthDataType.RESTING_HEART_RATE,
      HealthDataType.EXERCISE_TIME,
      // Sleep stages (v13+: granular DEEP/REM/LIGHT stages from Apple Watch)
      HealthDataType.SLEEP_IN_BED,
      HealthDataType.SLEEP_ASLEEP,
      HealthDataType.SLEEP_DEEP,
      HealthDataType.SLEEP_REM,
      HealthDataType.SLEEP_LIGHT,
      HealthDataType.SLEEP_AWAKE,
    ];
  } else {
    return const [
      HealthDataType.HEART_RATE,
      HealthDataType.HEART_RATE_VARIABILITY_RMSSD,
      HealthDataType.STEPS,
      HealthDataType.BLOOD_OXYGEN,
      HealthDataType.RESTING_HEART_RATE,
      HealthDataType.EXERCISE_TIME,
      // Sleep stages (Health Connect)
      HealthDataType.SLEEP_SESSION,
      HealthDataType.SLEEP_DEEP,
      HealthDataType.SLEEP_REM,
      HealthDataType.SLEEP_LIGHT,
      HealthDataType.SLEEP_AWAKE,
    ];
  }
}

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
///   - VO2MAX (HKQuantityTypeIdentifierVO2Max) — not wrapped yet; file export only.
///   - SLEEP_APNEA_EVENT (HKCategoryTypeIdentifierApneaEvents) — category type,
///     not wrapped; file export only (Apple Watch S9+, watchOS 10+).
// v3.0: removed WALKING_SPEED and APPLE_STAND_TIME (no backend mapping).
// v3.2: added ATRIAL_FIBRILLATION_BURDEN (iOS 16+, Apple Watch) → AFIB_FLAG.
const _optionalSyncTypes = [
  HealthDataType.RESPIRATORY_RATE,
  HealthDataType.BLOOD_PRESSURE_SYSTOLIC,
  HealthDataType.BLOOD_PRESSURE_DIASTOLIC,
  HealthDataType.ATRIAL_FIBRILLATION_BURDEN,
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
    // Request ALL types that _doSyncDirect() uses — core (includes sleep stages) + optional.
    final coreTypes = _platformSyncTypes();
    final allTypes = [...coreTypes, ..._optionalSyncTypes];
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

  /// Keyword fallback when sourceId is unhelpful.
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
      final data = await Health().getHealthDataFromTypes(
        types: const [HealthDataType.HEART_RATE],
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
        // Keyword fallback on sourceName
        if (brands.isEmpty) {
          final name = p.sourceName.toLowerCase();
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

      // Extended lookback windows for metrics that are NOT generated continuously
      // during the day. Using startOfDay for these would miss data that was
      // measured before midnight (e.g. overnight HRV) or not yet written today
      // (e.g. RHR, which Apple Watch computes and writes once per day, often in
      // the afternoon). We show the most recent value in the window.
      //
      // HRV (36h): covers the full previous sleep period even for early sleepers
      //            (e.g. 10pm–6am sleep → readings from yesterday 10pm are included).
      // RHR (48h): guarantees yesterday's value is always available even if today's
      //            hasn't been written yet (Watch needs daytime samples to compute it).
      // SpO2 / Resp Rate (24h): low-frequency spot measurements; 24h ensures at
      //            least the most recent overnight background reading is visible.
      // HRV: today midnight → now, matching Apple Health's daily AVERAGE window.
      // Apple Watch records HRV during sleep starting at 12 AM local time,
      // so midnight is the correct boundary (verified against Apple Health chart).
      final hrvStart  = DateTime(now.year, now.month, now.day);
      final rhrStart  = now.subtract(const Duration(hours: 48));
      final spo2Start = now.subtract(const Duration(hours: 24));
      final respStart = now.subtract(const Duration(hours: 24));

      // Fetch HR + HRV + Steps for today.
      // iOS uses SDNN; Android Health Connect only supports RMSSD.
      final hrvType = Platform.isIOS
          ? HealthDataType.HEART_RATE_VARIABILITY_SDNN
          : HealthDataType.HEART_RATE_VARIABILITY_RMSSD;
      // Fetch day metrics and sleep in a single parallel batch.
      // Sleep types use extended window (yesterday 18:00 → now).
      final sleepTypes = Platform.isIOS
          ? const [HealthDataType.SLEEP_IN_BED, HealthDataType.SLEEP_ASLEEP,
                   HealthDataType.SLEEP_DEEP, HealthDataType.SLEEP_REM, HealthDataType.SLEEP_LIGHT]
          : const [HealthDataType.SLEEP_SESSION, HealthDataType.SLEEP_DEEP,
                   HealthDataType.SLEEP_REM, HealthDataType.SLEEP_LIGHT];
      // Steps use HKStatisticsQuery (same as Apple Health) — correctly deduplicates
      // across sources (Apple Watch + iPhone). Start this in parallel with the
      // HealthKit sample queries so all three requests are in-flight together.
      final stepsFuture = Health()
          .getTotalStepsInInterval(startOfDay, now)
          .catchError((_) => null as int?);

      final results = await Future.wait([
        // HR: today only (continuous recording — startOfDay is correct).
        // HRV: 36h lookback so overnight readings before midnight are included.
        Future.wait([
          Health().getHealthDataFromTypes(
            types: [HealthDataType.HEART_RATE],
            startTime: startOfDay,
            endTime: now,
          ).catchError((_) => <HealthDataPoint>[]),
          Health().getHealthDataFromTypes(
            types: [hrvType],
            startTime: hrvStart,
            endTime: now,
          ).catchError((_) => <HealthDataPoint>[]),
        ]).then((r) => [...r[0], ...r[1]]),
        Health().getHealthDataFromTypes(
          types: sleepTypes,
          startTime: sleepStart,
          endTime: now,
        ).catchError((_) => <HealthDataPoint>[]),
        // RHR: 48h lookback — Watch writes one value per day, often in the afternoon;
        //      without this, the value is missing all morning.
        // SpO2: 24h lookback — low-frequency spot measurement.
        // Exercise Time: today only (today's workout minutes).
        Future.wait([
          Health().getHealthDataFromTypes(
            types: [HealthDataType.RESTING_HEART_RATE],
            startTime: rhrStart,
            endTime: now,
          ).catchError((_) => <HealthDataPoint>[]),
          Health().getHealthDataFromTypes(
            types: [HealthDataType.BLOOD_OXYGEN],
            startTime: spo2Start,
            endTime: now,
          ).catchError((_) => <HealthDataPoint>[]),
          Health().getHealthDataFromTypes(
            types: [HealthDataType.EXERCISE_TIME],
            startTime: startOfDay,
            endTime: now,
          ).catchError((_) => <HealthDataPoint>[]),
        ]).then((r) => [...r[0], ...r[1], ...r[2]]),
        // Resp Rate: 24h lookback — measured during sleep (Watch S6+ only).
        Health().getHealthDataFromTypes(
          types: const [HealthDataType.RESPIRATORY_RATE],
          startTime: respStart,
          endTime: now,
        ).catchError((_) => <HealthDataPoint>[]),
        // BP + AFib: BP requires a 3rd-party cuff app writing to HealthKit.
        // AFib burden requires iOS 16+ and Apple Watch (any series).
        Health().getHealthDataFromTypes(
          types: const [
            HealthDataType.BLOOD_PRESSURE_SYSTOLIC,
            HealthDataType.BLOOD_PRESSURE_DIASTOLIC,
            HealthDataType.ATRIAL_FIBRILLATION_BURDEN,
          ],
          startTime: startOfDay,
          endTime: now,
        ).catchError((_) => <HealthDataPoint>[]),
      ]);
      final totalSteps = await stepsFuture;

      final dedupedDay = Health().removeDuplicates(results[0]);
      final dedupedSleep = Health().removeDuplicates(results[1]);
      final dedupedExtra = Health().removeDuplicates(results[2]);
      final dedupedResp = Health().removeDuplicates(results[3]);
      final dedupedOptional = Health().removeDuplicates(results[4]);

      // Determine primary HR source first (most readings wins — Apple Watch
      // records continuously so it dominates over sporadic iPhone readings).
      // This must happen before computing avgHr so we can filter by source.
      final allHrPoints = dedupedDay
          .where((p) => p.type == HealthDataType.HEART_RATE)
          .toList();
      String? primarySource;
      if (allHrPoints.isNotEmpty) {
        final sourceCounts = <String, int>{};
        for (final p in allHrPoints) {
          sourceCounts[p.sourceName] = (sourceCounts[p.sourceName] ?? 0) + 1;
        }
        primarySource = sourceCounts.entries
            .reduce((a, b) => a.value >= b.value ? a : b)
            .key;
      }

      // Compute HR average from primary source only.
      // Filtering by source prevents cross-device averaging where iPhone and
      // Apple Watch both contribute readings at different (non-duplicate) times.
      final hrValues = dedupedDay
          .where((p) =>
              p.type == HealthDataType.HEART_RATE &&
              p.value is NumericHealthValue &&
              (primarySource == null || p.sourceName == primarySource))
          .map((p) => (p.value as NumericHealthValue).numericValue.toDouble())
          .toList();
      final avgHr = hrValues.isEmpty
          ? null
          : hrValues.reduce((a, b) => a + b) / hrValues.length;

      // HRV: average of all readings in the 36h window — matches Apple Health's
      // HRV: arithmetic mean of all SDNN readings since midnight, matching
      // Apple Health's daily AVERAGE display exactly.
      final hrvValues = dedupedDay
          .where((p) => p.type == hrvType && p.value is NumericHealthValue)
          .map((p) => (p.value as NumericHealthValue).numericValue.toDouble())
          .toList();
      final latestHrv = hrvValues.isEmpty
          ? null
          : hrvValues.reduce((a, b) => a + b) / hrvValues.length;

      // Compute sleep hours.
      // Priority: sum DEEP + REM + LIGHT stages (most accurate, no overlap).
      // Fallback: SLEEP_ASLEEP if no stage data (older devices / iPhone-only).
      // SLEEP_IN_BED is never used for the total — it spans the full in-bed
      // period (including awake time) and overlaps with every other type.
      const stageTypes = {
        HealthDataType.SLEEP_DEEP,
        HealthDataType.SLEEP_REM,
        HealthDataType.SLEEP_LIGHT,
      };
      final stagePoints = dedupedSleep.where((p) => stageTypes.contains(p.type)).toList();
      final asleepPoints = dedupedSleep.where((p) => p.type == HealthDataType.SLEEP_ASLEEP).toList();
      final sleepPoints = stagePoints.isNotEmpty ? stagePoints : asleepPoints;
      double sleepSec = 0;
      for (final p in sleepPoints) {
        sleepSec += p.dateTo.difference(p.dateFrom).inSeconds;
      }
      final sleepHours = sleepPoints.isEmpty ? null : sleepSec / 3600.0;

      // SpO2: latest Blood Oxygen reading (spot measurement, Watch S6+).
      final spo2Points = dedupedExtra
          .where((p) => p.type == HealthDataType.BLOOD_OXYGEN && p.value is NumericHealthValue)
          .toList()
        ..sort((a, b) => b.dateFrom.compareTo(a.dateFrom));
      // HealthKit stores BLOOD_OXYGEN as a ratio (0.0–1.0); multiply by 100
      // to convert to percentage (e.g. 0.97 → 97.0%).
      final latestSpo2 = spo2Points.isEmpty
          ? null
          : (spo2Points.first.value as NumericHealthValue).numericValue.toDouble() * 100;

      // RHR: Apple Watch writes one resting HR reading per day.
      final rhrPoints = dedupedExtra
          .where((p) => p.type == HealthDataType.RESTING_HEART_RATE && p.value is NumericHealthValue)
          .toList()
        ..sort((a, b) => b.dateFrom.compareTo(a.dateFrom));
      final latestRhr = rhrPoints.isEmpty
          ? null
          : (rhrPoints.first.value as NumericHealthValue).numericValue.toDouble();

      // Exercise Time: sum all intervals recorded today.
      final exerciseSec = dedupedExtra
          .where((p) => p.type == HealthDataType.EXERCISE_TIME && p.value is NumericHealthValue)
          .fold<double>(0, (acc, p) =>
              acc + (p.value as NumericHealthValue).numericValue.toDouble() * 60);
      final exerciseMin = exerciseSec == 0 ? null : (exerciseSec / 60).round();

      // Resp Rate: latest reading (Watch S6+ only — null on unsupported devices).
      final respPoints = dedupedResp
          .where((p) => p.type == HealthDataType.RESPIRATORY_RATE && p.value is NumericHealthValue)
          .toList()
        ..sort((a, b) => b.dateFrom.compareTo(a.dateFrom));
      final latestRespRate = respPoints.isEmpty
          ? null
          : (respPoints.first.value as NumericHealthValue).numericValue.toDouble();

      // Blood Pressure: latest systolic/diastolic readings (3rd-party cuff app required).
      final bpSysPoints = dedupedOptional
          .where((p) => p.type == HealthDataType.BLOOD_PRESSURE_SYSTOLIC && p.value is NumericHealthValue)
          .toList()
        ..sort((a, b) => b.dateFrom.compareTo(a.dateFrom));
      final latestBpSys = bpSysPoints.isEmpty
          ? null
          : (bpSysPoints.first.value as NumericHealthValue).numericValue.toDouble();

      final bpDiaPoints = dedupedOptional
          .where((p) => p.type == HealthDataType.BLOOD_PRESSURE_DIASTOLIC && p.value is NumericHealthValue)
          .toList()
        ..sort((a, b) => b.dateFrom.compareTo(a.dateFrom));
      final latestBpDia = bpDiaPoints.isEmpty
          ? null
          : (bpDiaPoints.first.value as NumericHealthValue).numericValue.toDouble();

      // AFib: ATRIAL_FIBRILLATION_BURDEN is a percentage (0–100).
      // Convert to bool: any burden > 0 means AFib was detected today.
      final afibPoints = dedupedOptional
          .where((p) => p.type == HealthDataType.ATRIAL_FIBRILLATION_BURDEN && p.value is NumericHealthValue)
          .toList()
        ..sort((a, b) => b.dateFrom.compareTo(a.dateFrom));
      final bool? afibDetected = afibPoints.isEmpty
          ? null
          : (afibPoints.first.value as NumericHealthValue).numericValue > 0;

      return HealthSnapshot(
        avgHr: avgHr != null ? double.parse(avgHr.toStringAsFixed(0)) : null,
        steps: totalSteps,
        sleepHours: sleepHours != null ? double.parse(sleepHours.toStringAsFixed(1)) : null,
        hrv: latestHrv != null ? double.parse(latestHrv.toStringAsFixed(0)) : null,
        spo2: latestSpo2 != null ? double.parse(latestSpo2.toStringAsFixed(1)) : null,
        rhr: latestRhr != null ? double.parse(latestRhr.toStringAsFixed(0)) : null,
        exerciseMin: exerciseMin,
        respRate: latestRespRate != null ? double.parse(latestRespRate.toStringAsFixed(1)) : null,
        bpSystolic: latestBpSys != null ? double.parse(latestBpSys.toStringAsFixed(0)) : null,
        bpDiastolic: latestBpDia != null ? double.parse(latestBpDia.toStringAsFixed(0)) : null,
        afibDetected: afibDetected,
        fetchedAt: now,
        primarySource: primarySource,
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

      final results = await Future.wait([
        Health().getHealthDataFromTypes(
          types: [HealthDataType.HEART_RATE, hrvType],
          startTime: startTime,
          endTime: now,
        ).catchError((_) => <HealthDataPoint>[]),
        Health().getHealthDataFromTypes(
          types: [HealthDataType.STEPS],
          startTime: startTime,
          endTime: now,
        ).catchError((_) => <HealthDataPoint>[]),
        Health().getHealthDataFromTypes(
          types: sleepTypes,
          startTime: startTime.subtract(const Duration(hours: 6)),
          endTime: now,
        ).catchError((_) => <HealthDataPoint>[]),
        // Extra metrics: RHR, SpO2, Exercise Time, Resp Rate, AFib burden.
        Health().getHealthDataFromTypes(
          types: [
            HealthDataType.RESTING_HEART_RATE,
            HealthDataType.BLOOD_OXYGEN,
            HealthDataType.EXERCISE_TIME,
            HealthDataType.RESPIRATORY_RATE,
            HealthDataType.ATRIAL_FIBRILLATION_BURDEN,
          ],
          startTime: startTime,
          endTime: now,
        ).catchError((_) => <HealthDataPoint>[]),
      ]);

      final allHrHrv = Health().removeDuplicates(results[0]);
      final allSteps = Health().removeDuplicates(results[1]);
      final allSleep = Health().removeDuplicates(results[2]);
      final allExtra = Health().removeDuplicates(results[3]);

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

        // Exercise Time: sum all intervals for the day.
        final exerciseSec = allExtra
            .where((p) =>
                p.type == HealthDataType.EXERCISE_TIME &&
                p.value is NumericHealthValue &&
                !p.dateFrom.isBefore(dayStart) && p.dateFrom.isBefore(dayEnd))
            .fold<double>(0, (acc, p) =>
                acc + (p.value as NumericHealthValue).numericValue.toDouble() * 60);
        final dayExerciseMin = exerciseSec == 0 ? null : (exerciseSec / 60).round();

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

      final latestUpload = body['latest_upload'] as Map? ?? {};
      final fraudScore = (latestUpload['fraud_risk_score'] as num?)?.toDouble();

      final insight = RiskInsight(
        hriScore: (body['hri_score'] as num? ?? 0).toInt(),
        hriLabel: body['hri_label'] as String? ?? 'low',
        anomalyBreakdown: anomalyBreakdown,
        latestAnomalies: latestAnomalies,
        fraudRiskScore: fraudScore,
        fetchedAt: DateTime.now(),
        baselineMaturity: body['baseline_maturity'] as String? ?? 'cold_start',
        daysWithData: (body['days_with_data'] as num? ?? 0).toInt(),
        estimatedEstablishedDate: body['estimated_established_date'] as String?,
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
        baselineMaturity: body['baseline_maturity'] as String? ?? 'cold_start',
        daysWithData: (body['days_with_data'] as num? ?? 0).toInt(),
        estimatedEstablishedDate: body['estimated_established_date'] as String?,
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
  }) {
    if (_ongoingSync != null) {
      onLog?.call('ℹ️  Sync already running — waiting for it to complete…');
      return _ongoingSync!;
    }
    _ongoingSync = _doSyncDirect(
      onLog: onLog,
      maxDays: maxDays,
      forceFullResync: forceFullResync,
    ).whenComplete(() {
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
  static const _keyHistoricalSyncCursor = 'historical_sync_cursor';
  static const _historicalSyncDays = 365;

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

    if (forceFullResync) {
      return _runChunkedHistoricalSync(
        prefs: prefs, lpUrl: lpUrl, token: token, onLog: onLog,
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
      // Sleep stages are now in coreTypes (added directly to _platformSyncTypes).
      final coreTypes = _platformSyncTypes();
      final allTypes = [...coreTypes, ..._optionalSyncTypes];

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

      // ── Step 3–5: Fetch core (includes sleep stages), optional in parallel ─
      onLog?.call('Fetching health data…');

      // Sleep spans midnight: always look back to yesterday 18:00 at minimum,
      // but respect the incremental startTime if it's earlier. Sleep stage types
      // are now in coreTypes, so the same extended window applies to all core data.
      final sleepWindowStart = [
        startTime,
        DateTime(endTime.year, endTime.month, endTime.day)
            .subtract(const Duration(hours: 6)), // yesterday 18:00
      ].reduce((a, b) => a.isBefore(b) ? a : b);

      final fetchResults = await Future.wait([
        Health().getHealthDataFromTypes(
          types: coreTypes,
          startTime: sleepWindowStart, // use extended window for all (covers sleep)
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
          .timeout(const Duration(seconds: 15));
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
        final fetchResults = await Future.wait([
          Health().getHealthDataFromTypes(
            types: coreTypes,
            startTime: chunkStart,
            endTime: effectiveEnd,
          ).catchError((_) => <HealthDataPoint>[]),
          Health().getHealthDataFromTypes(
            types: _optionalSyncTypes,
            startTime: chunkStart,
            endTime: effectiveEnd,
          ).catchError((_) => <HealthDataPoint>[]),
        ]);

        final allPoints = Health().removeDuplicates([...fetchResults[0], ...fetchResults[1]]);
        final events = allPoints
            .map(_convertToMobileSyncEvent)
            .whereType<Map<String, dynamic>>()
            .toList();

        if (events.isNotEmpty) {
          // Upload in batches of 2000
          for (int i = 0; i < events.length; i += 2000) {
            final batch = events.sublist(i, (i + 2000).clamp(0, events.length));
            http.Response? response;
            for (int attempt = 0; attempt < 3; attempt++) {
              if (attempt > 0) await Future.delayed(Duration(seconds: attempt * 3));
              try {
                response = await http.post(
                  Uri.parse('$lpUrl/api/v1/data/mobile-sync'),
                  headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $currentToken'},
                  body: jsonEncode({'events': batch}),
                ).timeout(const Duration(seconds: 45));
                if (response.statusCode != 429 && response.statusCode != 503) break;
              } catch (_) { /* retry */ }
            }
            if (response == null || (response.statusCode != 200 && response.statusCode != 201)) {
              // Chunk failed — keep cursor at chunkStart so next run retries this chunk
              historicalSyncProgress.value = null;
              return SyncResult(
                success: false,
                message: 'Upload failed at $label. Re-sync will resume from this point.',
              );
            }
          }
          totalSent += events.length;
        }
      } catch (_) {
        historicalSyncProgress.value = null;
        return SyncResult(success: false, message: 'Error at $label. Re-sync will resume from this point.');
      }

      // Chunk succeeded — advance cursor
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
      data: {'events_received': totalSent, 'source_devices': <String>[]},
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
      final results = await Health().getHealthDataFromTypes(
        types: [HealthDataType.HEART_RATE],
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

    double numericValue;
    if (_isSleepType(dp.type)) {
      // Sleep events represent a time range — convert duration to minutes.
      numericValue = dp.dateTo.difference(dp.dateFrom).inSeconds / 60.0;
      if (numericValue <= 0) return null;
    } else if (dp.value is NumericHealthValue) {
      numericValue = (dp.value as NumericHealthValue).numericValue.toDouble();
      // HealthKit stores BLOOD_OXYGEN as a ratio (0.0–1.0); backend expects %.
      if (lpMetric == 'SPO2_INSTANT') {
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
    } else if (lpMetric == 'SLEEP_STAGE') {
      // Encode the specific sleep stage type so backend can do granular analysis
      final stageName = dp.type.name; // e.g. "SLEEP_DEEP", "SLEEP_REM"
      algoMeta = {'staging_algorithm': 'watchOS_sleep', 'sleep_stage': stageName};
    }

    return {
      'metric_type': lpMetric,
      'value': numericValue,
      'unit': _unitForType(dp.type),
      'start_time': dp.dateFrom.toUtc().toIso8601String(),
      'end_time': dp.dateTo.toUtc().toIso8601String(),
      'source_device': dp.sourceName,
      'source_app_id': dp.sourceId,
      'device_model_raw': dp.deviceModel,
      'source_platform': Platform.isIOS ? 'HEALTHKIT' : 'HEALTH_CONNECT',
      if (algoMeta != null) 'algorithm_metadata': algoMeta,
    };
  }

  static bool _isSleepType(HealthDataType type) => const {
    HealthDataType.SLEEP_IN_BED,
    HealthDataType.SLEEP_ASLEEP,
    HealthDataType.SLEEP_DEEP,
    HealthDataType.SLEEP_REM,
    HealthDataType.SLEEP_LIGHT,
    HealthDataType.SLEEP_AWAKE,
    HealthDataType.SLEEP_AWAKE_IN_BED,
    HealthDataType.SLEEP_SESSION,
  }.contains(type);

  static String? _healthTypeToLp(HealthDataType type) {
    // All sleep stage types map to SLEEP_STAGE — duration in minutes.
    if (_isSleepType(type)) return 'SLEEP_STAGE';

    const map = {
      // Core metrics
      HealthDataType.HEART_RATE: 'HR_INSTANT',
      HealthDataType.HEART_RATE_VARIABILITY_SDNN: 'HRV_SDNN',    // iOS
      HealthDataType.HEART_RATE_VARIABILITY_RMSSD: 'HRV_RMSSD',  // Android
      HealthDataType.STEPS: 'STEPS_DELTA',
      HealthDataType.BLOOD_OXYGEN: 'SPO2_INSTANT',
      HealthDataType.RESTING_HEART_RATE: 'RHR_DAILY',
      HealthDataType.EXERCISE_TIME: 'EXERCISE_TIME',
      // Optional (Apple Watch S6+ / v13 new types)
      HealthDataType.RESPIRATORY_RATE: 'RESP_RATE',
      HealthDataType.BLOOD_PRESSURE_SYSTOLIC: 'BP_SYSTOLIC',
      HealthDataType.BLOOD_PRESSURE_DIASTOLIC: 'BP_DIASTOLIC',
      // v3.2: AFib burden (iOS 16+, Apple Watch) → binary 0/1 flag
      HealthDataType.ATRIAL_FIBRILLATION_BURDEN: 'AFIB_FLAG',
      // v3.0 removed: ENERGY_DELTA, ENERGY_BASAL, DISTANCE_DELTA,
      // FLOORS_CLIMBED, STAND_TIME, WALKING_SPEED (low actuarial value)
    };
    return map[type];
  }

  static String _unitForType(HealthDataType type) {
    if (_isSleepType(type)) return 'min';
    const map = {
      HealthDataType.HEART_RATE: 'bpm',
      HealthDataType.HEART_RATE_VARIABILITY_SDNN: 'ms',
      HealthDataType.HEART_RATE_VARIABILITY_RMSSD: 'ms',
      HealthDataType.STEPS: 'count',
      HealthDataType.BLOOD_OXYGEN: '%',
      HealthDataType.RESTING_HEART_RATE: 'bpm',
      HealthDataType.EXERCISE_TIME: 'min',
      // Optional
      HealthDataType.RESPIRATORY_RATE: 'breaths/min',
      HealthDataType.BLOOD_PRESSURE_SYSTOLIC: 'mmHg',
      HealthDataType.BLOOD_PRESSURE_DIASTOLIC: 'mmHg',
      HealthDataType.ATRIAL_FIBRILLATION_BURDEN: '%',
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
      // Force a refresh attempt rather than waiting for a 401 at next API call.
      debugPrint('[HealthService.refreshTokenIfNeeded] Token decode failed, forcing refresh: $e');
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
