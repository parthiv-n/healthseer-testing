import 'dart:convert';
import 'dart:io';
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
enum SyncErrorType { network, noData, serverError, authExpired, unknown }

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

/// Optional types only available on newer hardware (Apple Watch S6+ for RESPIRATORY_RATE).
/// Fetched separately with null-safe handling — missing data is silently ignored.
const _optionalSyncTypes = [
  HealthDataType.RESPIRATORY_RATE,
];


class HealthService {
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
  // Anchor for incremental sync: ISO-8601 timestamp of the latest event the
  // backend confirmed it has.  Null means this is a first-time sync.
  static const _keyLastSyncAnchor = 'last_sync_anchor';
  // Offline cache keys for reports
  static const _keyCachedDailyReport = 'cached_daily_report';
  static const _keyCachedDailyReportAt = 'cached_daily_report_at';
  static const _keyCachedDailyReportStale = 'cached_daily_report_stale';
  static const _keyCachedRangeReportPrefix = 'cached_range_report_';

  // ── Auth ──────────────────────────────────────────────────────────────────
  static Future<bool> isLoggedIn() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getString(_keyJwtToken) ?? '').isNotEmpty;
  }

  static Future<String?> getJwtToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyJwtToken);
  }

  static Future<String?> getLoggedInEmail() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyLoggedInEmail);
  }

  static Future<SyncResult> login({
    required String email,
    required String password,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final baseUrl = (prefs.getString(_keyLpUrl) ?? kDefaultApiUrl)
        .trimRight()
        .replaceAll(RegExp(r'/+$'), '');

    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/v1/auth/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'tenant_slug': kTenantSlug,
          'email': email,
          'password': password,
        }),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final token = body['access_token'] as String;
        final userId = body['user_id'] as String;
        await prefs.setString(_keyJwtToken, token);
        await prefs.setString(_keyLpUserId, userId);
        await prefs.setString(_keyLoggedInEmail, email);
        // Ensure the URL is saved as default
        await prefs.setString(_keyLpUrl, baseUrl);
        return SyncResult(success: true, message: 'Logged in successfully.');
      } else if (response.statusCode == 401) {
        return SyncResult(success: false, message: 'Invalid email or password.');
      } else {
        return SyncResult(success: false, message: 'Login failed (HTTP ${response.statusCode}).');
      }
    } catch (e) {
      return SyncResult(success: false, message: 'Cannot reach server: $e');
    }
  }

  static Future<SyncResult> register({
    required String email,
    required String password,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final baseUrl = (prefs.getString(_keyLpUrl) ?? kDefaultApiUrl)
        .trimRight()
        .replaceAll(RegExp(r'/+$'), '');

    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/v1/auth/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'tenant_slug': kTenantSlug,
          'email': email,
          'password': password,
        }),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 201) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final token = body['access_token'] as String;
        final userId = body['user_id'] as String;
        await prefs.setString(_keyJwtToken, token);
        await prefs.setString(_keyLpUserId, userId);
        await prefs.setString(_keyLoggedInEmail, email);
        await prefs.setString(_keyLpUrl, baseUrl);
        return SyncResult(success: true, message: 'Account created successfully.');
      } else if (response.statusCode == 409) {
        return SyncResult(success: false, message: 'Email already registered. Please sign in.');
      } else if (response.statusCode == 400) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        return SyncResult(success: false, message: body['detail'] as String? ?? 'Registration failed.');
      } else {
        return SyncResult(success: false, message: 'Registration failed (HTTP ${response.statusCode}).');
      }
    } catch (e) {
      return SyncResult(success: false, message: 'Cannot reach server: $e');
    }
  }

  static Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyJwtToken);
    await prefs.remove(_keyLpUserId);
    await prefs.remove(_keyLoggedInEmail);
    await prefs.remove(_keyRiskInsightCache);
    await prefs.remove(_keyLastSyncAnchor);
    await Workmanager().cancelByUniqueName('periodicHealthSync');
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
    return {
      'owUrl': prefs.getString(_keyOwUrl) ?? '',
      'owUserId': prefs.getString(_keyOwUserId) ?? '',
      'owToken': prefs.getString(_keyOwToken) ?? '',
      'lpUrl': prefs.getString(_keyLpUrl) ?? '',
      'lpApiKey': prefs.getString(_keyLpApiKey) ?? '',
      'lpUserId': prefs.getString(_keyLpUserId) ?? '',
      'syncMode': prefs.getString(_keySyncMode) ?? 'direct',
    };
  }

  static Future<void> saveConfig(Map<String, String> cfg) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyOwUrl, cfg['owUrl'] ?? '');
    await prefs.setString(_keyOwUserId, cfg['owUserId'] ?? '');
    await prefs.setString(_keyOwToken, cfg['owToken'] ?? '');
    await prefs.setString(_keyLpUrl, cfg['lpUrl'] ?? '');
    await prefs.setString(_keyLpApiKey, cfg['lpApiKey'] ?? '');
    await prefs.setString(_keyLpUserId, cfg['lpUserId'] ?? '');
    await prefs.setString(_keySyncMode, cfg['syncMode'] ?? 'direct');
  }

  // ── Open Wearables path (unavailable) ────────────────────────────────────
  static Future<bool> requestPermissions() async {
    // On Android, Health Connect must be available before requesting permissions.
    if (Platform.isAndroid) {
      final status = await Health().getHealthConnectSdkStatus();
      if (status != HealthConnectSdkStatus.sdkAvailable) {
        return false; // Caller should surface the install prompt to the user.
      }
    }
    return await Health().requestAuthorization(_platformSyncTypes());
  }

  /// Returns true if Health Connect is installed and available on Android.
  /// Always returns true on iOS (HealthKit is always available).
  static Future<bool> isHealthConnectAvailable() async {
    if (!Platform.isAndroid) return true;
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
      // Request read permissions (non-blocking; silently fails if denied)
      final sleepType = Platform.isIOS
          ? HealthDataType.SLEEP_IN_BED
          : HealthDataType.SLEEP_SESSION;
      await Health().requestAuthorization(
        [..._platformSyncTypes(), sleepType],
      );

      final now = DateTime.now();
      final startOfDay = DateTime(now.year, now.month, now.day);
      // For sleep: look back from midnight last night (18:00 yesterday → now)
      final sleepStart = startOfDay.subtract(const Duration(hours: 6));

      // Fetch HR + HRV + Steps for today.
      // iOS uses SDNN; Android Health Connect only supports RMSSD.
      final hrvType = Platform.isIOS
          ? HealthDataType.HEART_RATE_VARIABILITY_SDNN
          : HealthDataType.HEART_RATE_VARIABILITY_RMSSD;
      final dayPoints = await Health().getHealthDataFromTypes(
        types: [
          HealthDataType.HEART_RATE,
          hrvType,
          HealthDataType.STEPS,
        ],
        startTime: startOfDay,
        endTime: now,
      );
      final dedupedDay = Health().removeDuplicates(dayPoints);

      // Fetch sleep separately (spans midnight).
      // iOS: SLEEP_IN_BED; Android Health Connect: SLEEP_SESSION
      final sleepPoints = await Health().getHealthDataFromTypes(
        types: [Platform.isIOS ? HealthDataType.SLEEP_IN_BED : HealthDataType.SLEEP_SESSION],
        startTime: sleepStart,
        endTime: now,
      );
      final dedupedSleep = Health().removeDuplicates(sleepPoints);

      // Compute HR average
      final hrValues = dedupedDay
          .where((p) => p.type == HealthDataType.HEART_RATE)
          .map((p) => (p.value as NumericHealthValue).numericValue.toDouble())
          .toList();
      final avgHr = hrValues.isEmpty
          ? null
          : hrValues.reduce((a, b) => a + b) / hrValues.length;

      // Compute steps total
      final stepValues = dedupedDay
          .where((p) => p.type == HealthDataType.STEPS)
          .map((p) => (p.value as NumericHealthValue).numericValue.toDouble())
          .toList();
      final totalSteps =
          stepValues.isEmpty ? null : stepValues.reduce((a, b) => a + b).toInt();

      // Compute latest HRV (type is platform-dependent, captured above)
      final hrvPoints = dedupedDay
          .where((p) => p.type == hrvType)
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
      );
    } catch (_) {
      return HealthSnapshot(fetchedAt: DateTime.now());
    }
  }

  // ── Cloud risk insights (requires network + JWT) ──────────────────────────
  /// Calls GET /api/v1/reports/summary and parses the HRI + anomalies.
  /// Caches the result in SharedPreferences for offline display on next launch.
  static Future<RiskInsight?> fetchRiskInsight({
    void Function(String)? onLog,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final lpUrl = (prefs.getString(_keyLpUrl) ?? kDefaultApiUrl)
        .trimRight()
        .replaceAll(RegExp(r'/+$'), '');
    final lpUserId = prefs.getString(_keyLpUserId) ?? '';
    final token = prefs.getString(_keyJwtToken) ?? '';

    if (lpUserId.isEmpty || token.isEmpty) return null;

    try {
      onLog?.call('Fetching risk insights from TikCare…');
      final response = await http.get(
        Uri.parse('$lpUrl/api/v1/reports/summary/$lpUserId'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        onLog?.call('⚠️  Insights fetch: HTTP ${response.statusCode}');
        return _loadCachedInsight();
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;

      final anomalyBreakdown = Map<String, int>.from(
        (body['anomaly_breakdown'] as Map? ?? {}).map(
          (k, v) => MapEntry(k as String, (v as num).toInt()),
        ),
      );

      final latestAnomalies = List<Map<String, dynamic>>.from(
        (body['latest_anomalies'] as List? ?? []).map(
          (e) => Map<String, dynamic>.from(e as Map),
        ),
      );

      final latestUpload = body['latest_upload'] as Map? ?? {};
      final fraudScore = latestUpload['fraud_risk_score'] as double?;

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
    await prefs.setString(_keyRiskInsightCache, jsonEncode({
      ...raw,
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
          (k, v) => MapEntry(k as String, (v as num).toInt()),
        ),
      );
      final latestAnomalies = List<Map<String, dynamic>>.from(
        (body['latest_anomalies'] as List? ?? []).map(
          (e) => Map<String, dynamic>.from(e as Map),
        ),
      );
      final latestUpload = body['latest_upload'] as Map? ?? {};
      return RiskInsight(
        hriScore: (body['hri_score'] as num? ?? 0).toInt(),
        hriLabel: body['hri_label'] as String? ?? 'low',
        anomalyBreakdown: anomalyBreakdown,
        latestAnomalies: latestAnomalies,
        fraudRiskScore: latestUpload['fraud_risk_score'] as double?,
        fetchedAt: DateTime.tryParse(body['_cached_at'] as String? ?? '') ?? DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }

  // ── Direct sync path (JWT auth, incremental) ─────────────────────────────
  /// Smart incremental sync:
  ///   - First sync (no anchor): pulls the last 30 days to build an initial baseline
  ///   - Subsequent syncs: pulls from (server anchor − 2h) to cover HealthKit write latency
  ///   - Fallback on network error: pulls the last 2 days
  ///
  /// Sleep data uses a separate window (yesterday 18:00 → now) because sleep spans
  /// midnight and needs to be fetched relative to the prior evening.
  static Future<SyncResult> syncDirect({
    void Function(String)? onLog,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final lpUrl = (prefs.getString(_keyLpUrl) ?? kDefaultApiUrl)
        .trimRight()
        .replaceAll(RegExp(r'/+$'), '');
    final token = prefs.getString(_keyJwtToken) ?? '';

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
            final anchor = DateTime.parse(rawAnchor);
            startTime = anchor.subtract(const Duration(hours: 2));
            onLog?.call('Incremental sync from ${anchor.toLocal().toString().substring(0, 16)}…');
          }
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

      // ── Step 2: Request permissions ───────────────────────────────────────
      final coreTypes = _platformSyncTypes();
      final sleepType = Platform.isIOS ? HealthDataType.SLEEP_IN_BED : HealthDataType.SLEEP_SESSION;
      final allTypes = [...coreTypes, sleepType, ..._optionalSyncTypes];

      onLog?.call(Platform.isIOS ? 'Requesting HealthKit permissions…' : 'Requesting Health Connect permissions…');
      final granted = await Health().requestAuthorization(allTypes);
      if (!granted) {
        return SyncResult(
          success: false,
          message: Platform.isIOS ? 'HealthKit permission denied.' : 'Health Connect permission denied.',
        );
      }

      // ── Step 3: Fetch core metrics ────────────────────────────────────────
      onLog?.call('Fetching health data…');
      final corePoints = await Health().getHealthDataFromTypes(
        types: coreTypes,
        startTime: startTime,
        endTime: endTime,
      );

      // ── Step 4: Fetch sleep with dedicated overnight window ───────────────
      // Sleep spans midnight: always look back to yesterday 18:00 at minimum,
      // but respect the incremental startTime if it's earlier.
      final sleepWindowStart = [
        startTime,
        DateTime(endTime.year, endTime.month, endTime.day)
            .subtract(const Duration(hours: 6)), // yesterday 18:00
      ].reduce((a, b) => a.isBefore(b) ? a : b);

      final sleepPoints = await Health().getHealthDataFromTypes(
        types: [sleepType],
        startTime: sleepWindowStart,
        endTime: endTime,
      );

      // ── Step 5: Fetch optional types (null-safe) ──────────────────────────
      List<HealthDataPoint> optionalPoints = [];
      try {
        optionalPoints = await Health().getHealthDataFromTypes(
          types: _optionalSyncTypes,
          startTime: startTime,
          endTime: endTime,
        );
      } catch (_) {
        // Device doesn't support these types — silently ignore
      }

      // ── Step 6: Combine, deduplicate, convert ─────────────────────────────
      final allPoints = Health().removeDuplicates([
        ...corePoints,
        ...sleepPoints,
        ...optionalPoints,
      ]);
      onLog?.call('Fetched ${allPoints.length} data points.');

      if (allPoints.isEmpty) {
        onLog?.call('ℹ️  No new data found in the sync window.');
        return SyncResult(success: false, message: 'No new health data found.');
      }

      final events = allPoints
          .map(_convertToMobileSyncEvent)
          .whereType<Map<String, dynamic>>()
          .toList();

      // ── Step 7: POST in batches of 2000 (handles large first-sync) ────────
      const batchSize = 2000;
      int totalSent = 0;
      Map<String, dynamic>? lastBody;

      for (int i = 0; i < events.length; i += batchSize) {
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
            errorType: SyncErrorType.noData,
          );
        }
      }

      // ── Step 8: Save sync anchor for next incremental sync ────────────────
      await prefs.setString(_keyLastSyncAnchor, endTime.toUtc().toIso8601String());

      onLog?.call('✅ Sync complete — $totalSent events uploaded.');
      return SyncResult(success: true, message: 'Sync complete.', data: lastBody);

    } catch (e) {
      final isNetwork = e is SocketException ||
          e.toString().contains('TimeoutException') ||
          e.toString().contains('SocketException');
      return SyncResult(
        success: false,
        message: isNetwork ? 'No connection. Check your network and try again.' : 'Error: $e',
        errorType: isNetwork ? SyncErrorType.network : SyncErrorType.unknown,
      );
    }
  }

  // ── Health check ──────────────────────────────────────────────────────────
  static Future<SyncResult> pingLifePulse() async {
    final prefs = await SharedPreferences.getInstance();
    final lpUrl = (prefs.getString(_keyLpUrl) ?? kDefaultApiUrl)
        .trimRight()
        .replaceAll(RegExp(r'/+$'), '');
    try {
      final response = await http
          .get(Uri.parse('$lpUrl/api/v1/health'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        return SyncResult(
          success: true,
          message: 'LifePulse API is online.',
          data: body as Map<String, dynamic>,
        );
      }
      return SyncResult(success: false, message: 'HTTP ${response.statusCode}');
    } catch (e) {
      return SyncResult(success: false, message: 'Cannot reach LifePulse: $e');
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

    return {
      'metric_type': lpMetric,
      'value': numericValue,
      'unit': _unitForType(dp.type),
      'start_time': dp.dateFrom.toUtc().toIso8601String(),
      'end_time': dp.dateTo.toUtc().toIso8601String(),
      'source_device': dp.sourceName,
      'source_platform': Platform.isIOS ? 'HEALTHKIT' : 'HEALTH_CONNECT',
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
      // Optional (Apple Watch S6+ / Garmin)
      HealthDataType.RESPIRATORY_RATE: 'RESP_RATE',
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
    };
    return map[type] ?? 'unknown';
  }

  // ── Retry helper ──────────────────────────────────────────────────────────
  /// Calls [fn] up to [maxAttempts] times with exponential backoff.
  /// Returns the first non-null result, or null if all attempts fail.
  /// Delays: attempt 1 = 0s (immediate), attempt 2 = 2s, attempt 3 = 4s.
  static Future<T?> _withRetry<T>(
    Future<T?> Function() fn, {
    int maxAttempts = 3,
  }) async {
    for (int i = 0; i < maxAttempts; i++) {
      if (i > 0) {
        await Future.delayed(Duration(seconds: i * 2));
      }
      final result = await fn();
      if (result != null) return result;
    }
    return null;
  }

  // ── Token Refresh ─────────────────────────────────────────────────────────
  static Future<void> refreshTokenIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_keyJwtToken);
    if (token == null || token.isEmpty) return;

    // Decode expiry from JWT payload (base64 middle section)
    try {
      final parts = token.split('.');
      if (parts.length != 3) return;
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      ) as Map<String, dynamic>;
      final exp = payload['exp'] as int?;
      if (exp == null) return;
      final expiresAt = DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
      final timeLeft = expiresAt.difference(DateTime.now().toUtc());
      if (timeLeft.inMinutes > 10) return; // Still fresh, skip
    } catch (_) {
      return;
    }

    // Refresh via API
    final baseUrl = await _baseUrl();
    try {
      final prefs2 = await SharedPreferences.getInstance();
      final oldToken = prefs2.getString(_keyJwtToken) ?? '';
      final resp = await http.post(
        Uri.parse('$baseUrl/api/v1/auth/refresh'),
        headers: {'Authorization': 'Bearer $oldToken'},
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        await prefs2.setString(_keyJwtToken, body['access_token'] as String);
      }
    } catch (_) {}
  }

  static Future<String> _baseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getString(_keyLpUrl) ?? kDefaultApiUrl)
        .trimRight()
        .replaceAll(RegExp(r'/+$'), '');
  }

  static Future<Map<String, String>> _authHeaders() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_keyJwtToken) ?? '';
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }

  // ── Daily Report ──────────────────────────────────────────────────────────
  static Future<DailyReport?> fetchDailyReport({String? date}) async {
    await refreshTokenIfNeeded();
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString(_keyLpUserId) ?? '';
    if (userId.isEmpty) return null;

    final reportDate = date ?? DateTime.now().toIso8601String().substring(0, 10);
    final baseUrl = await _baseUrl();

    DailyReport? result;
    try {
      final resp = await http.get(
        Uri.parse('$baseUrl/api/v1/reports/daily/$userId?report_date=$reportDate'),
        headers: await _authHeaders(),
      ).timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        result = DailyReport.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
        // Save to offline cache with timestamp
        await prefs.setString(_keyCachedDailyReport, resp.body);
        await prefs.setString(
          _keyCachedDailyReportAt,
          DateTime.now().toIso8601String(),
        );
        await prefs.setBool(_keyCachedDailyReportStale, false);
      }
    } catch (_) {}

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
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString(_keyLpUserId) ?? '';
    if (userId.isEmpty) return null;

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
      if (resp.statusCode == 200) {
        result = RangeReport.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
        await prefs.setString(cacheKey, resp.body);
        await prefs.setString(cacheAtKey, DateTime.now().toIso8601String());
        await prefs.setBool(cacheStaleKey, false);
      }
    } catch (_) {}

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
    // ignore: unnecessary_brace_in_string_interps
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
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString(_keyLpUserId) ?? '';
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
        if (resp.statusCode == 200) {
          return RangeReport.fromJson(
            jsonDecode(resp.body) as Map<String, dynamic>,
          );
        }
      } catch (_) {}
      return null;
    });
  }

  // ── Anomalies ─────────────────────────────────────────────────────────────
  static Future<List<AnomalyItem>> fetchAnomalies({int limit = 30}) async {
    await refreshTokenIfNeeded();
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString(_keyLpUserId) ?? '';
    if (userId.isEmpty) return [];

    final baseUrl = await _baseUrl();

    try {
      final resp = await http.get(
        Uri.parse('$baseUrl/api/v1/anomalies?user_id=$userId&limit=$limit'),
        headers: await _authHeaders(),
      ).timeout(const Duration(seconds: 15));

      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        final items = body['items'] as List<dynamic>? ?? [];
        return items
            .map((e) => AnomalyItem.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {}
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
      if (resp.statusCode == 200) {
        return jsonDecode(resp.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return null;
  }

  // ── Dev/Test: Clear My Data ───────────────────────────────────────────────
  /// DEV ONLY — deletes all health data for the current user.
  /// Used for resetting between test runs with real Apple Watch.
  /// Returns a summary of deleted counts, or null on failure.
  static Future<Map<String, dynamic>?> clearMyData() async {
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
    } catch (_) {}
    return null;
  }
}
