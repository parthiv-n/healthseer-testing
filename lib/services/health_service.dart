import 'dart:convert';
import 'package:health/health.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/health_snapshot.dart';
import '../models/risk_insight.dart';

// ── Default API config (demo / TestFlight) ───────────────────────────────────
const kDefaultApiUrl = 'https://lifepulse-api-63410932899.us-central1.run.app';
const kTenantSlug = 'tikcare';

/// Connection mode: OW = full chain via Open Wearables (unavailable — SDK removed);
/// Direct = read HealthKit via `health` package, POST to LifePulse Partner API directly.
enum SyncMode { openWearables, direct }

class SyncResult {
  final bool success;
  final String message;
  final Map<String, dynamic>? data;
  SyncResult({required this.success, required this.message, this.data});
}

/// HealthKit data types to read for the 7-day sync upload.
const _syncTypes = [
  HealthDataType.HEART_RATE,
  HealthDataType.HEART_RATE_VARIABILITY_SDNN,
  HealthDataType.STEPS,
  HealthDataType.BLOOD_OXYGEN,
  HealthDataType.ACTIVE_ENERGY_BURNED,
  HealthDataType.RESTING_HEART_RATE,
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
    return await Health().requestAuthorization(_syncTypes);
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
      await Health().requestAuthorization(
        [..._syncTypes, HealthDataType.SLEEP_IN_BED],
      );

      final now = DateTime.now();
      final startOfDay = DateTime(now.year, now.month, now.day);
      // For sleep: look back from midnight last night (18:00 yesterday → now)
      final sleepStart = startOfDay.subtract(const Duration(hours: 6));

      // Fetch HR + HRV + Steps for today
      final dayPoints = await Health().getHealthDataFromTypes(
        types: [
          HealthDataType.HEART_RATE,
          HealthDataType.HEART_RATE_VARIABILITY_SDNN,
          HealthDataType.STEPS,
        ],
        startTime: startOfDay,
        endTime: now,
      );
      final dedupedDay = Health().removeDuplicates(dayPoints);

      // Fetch sleep separately (spans midnight)
      final sleepPoints = await Health().getHealthDataFromTypes(
        types: [HealthDataType.SLEEP_IN_BED],
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

      // Compute latest HRV
      final hrvPoints = dedupedDay
          .where((p) => p.type == HealthDataType.HEART_RATE_VARIABILITY_SDNN)
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

  // ── Direct sync path (JWT auth) ───────────────────────────────────────────
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
      onLog?.call('Requesting HealthKit permissions…');
      final granted = await Health().requestAuthorization(_syncTypes);
      if (!granted) {
        return SyncResult(success: false, message: 'HealthKit permission denied.');
      }

      final endTime = DateTime.now();
      final startTime = endTime.subtract(const Duration(days: 7));

      onLog?.call('Fetching HealthKit data (last 7 days)…');
      final dataPoints = await Health().getHealthDataFromTypes(
        types: _syncTypes,
        startTime: startTime,
        endTime: endTime,
      );
      final deduped = Health().removeDuplicates(dataPoints);
      onLog?.call('Fetched ${deduped.length} data points from HealthKit.');

      if (deduped.isEmpty) {
        onLog?.call('ℹ️  No data points found. Ensure the Health app has data for the last 7 days.');
        return SyncResult(success: false, message: 'No health data found for the last 7 days.');
      }

      final events = deduped
          .map((dp) => _convertToMobileSyncEvent(dp))
          .whereType<Map<String, dynamic>>()
          .toList();

      onLog?.call('POSTing ${events.length} events to LifePulse…');

      final response = await http
          .post(
            Uri.parse('$lpUrl/api/v1/data/mobile-sync'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({'events': events}),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200 || response.statusCode == 202) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final syncId = body['sync_log_id'] ?? 'unknown';
        onLog?.call('✅ Sync accepted. sync_log_id=$syncId');
        onLog?.call('Pipeline processing… fetching insights in a moment.');
        return SyncResult(success: true, message: 'Sync accepted.', data: body);
      } else if (response.statusCode == 401) {
        onLog?.call('❌ Session expired. Please sign in again.');
        return SyncResult(success: false, message: 'Session expired. Please sign in again.');
      } else {
        onLog?.call('❌ HTTP ${response.statusCode}: ${response.body}');
        return SyncResult(
          success: false,
          message: 'HTTP ${response.statusCode}: ${response.body}',
        );
      }
    } catch (e) {
      return SyncResult(success: false, message: 'Error: $e');
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

    if (dp.value is! NumericHealthValue) return null;
    final numericValue = (dp.value as NumericHealthValue).numericValue.toDouble();

    return {
      'metric_type': lpMetric,
      'value': numericValue,
      'unit': _unitForType(dp.type),
      'start_time': dp.dateFrom.toUtc().toIso8601String(),
      'end_time': dp.dateTo.toUtc().toIso8601String(),
      'source_device': dp.sourceName,
      'source_platform': 'HEALTHKIT',
    };
  }

  static String? _healthTypeToLp(HealthDataType type) {
    const map = {
      HealthDataType.HEART_RATE: 'HR_INSTANT',
      HealthDataType.HEART_RATE_VARIABILITY_SDNN: 'HRV_SDNN',
      HealthDataType.STEPS: 'STEPS_DELTA',
      HealthDataType.BLOOD_OXYGEN: 'SPO2_INSTANT',
      HealthDataType.ACTIVE_ENERGY_BURNED: 'ENERGY_DELTA',
      HealthDataType.RESTING_HEART_RATE: 'HR_RESTING',
    };
    return map[type];
  }

  static String _unitForType(HealthDataType type) {
    const map = {
      HealthDataType.HEART_RATE: 'bpm',
      HealthDataType.HEART_RATE_VARIABILITY_SDNN: 'ms',
      HealthDataType.STEPS: 'count',
      HealthDataType.BLOOD_OXYGEN: '%',
      HealthDataType.ACTIVE_ENERGY_BURNED: 'kcal',
      HealthDataType.RESTING_HEART_RATE: 'bpm',
    };
    return map[type] ?? 'unknown';
  }
}
