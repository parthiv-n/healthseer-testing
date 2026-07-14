import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Dart-side wrapper for the native SLEEP_APNEA_EVENT MethodChannel.
///
/// The Flutter `health` package v13.x does not wrap the HealthKit apnea
/// category type at all — it cannot simply be added to `_platformSyncTypes`.
/// This wrapper calls the Swift bridge in ios/Runner/SleepApneaChannel.swift
/// and returns events already formatted as mobile-sync payloads (same shape
/// as HealthService._convertToMobileSyncEvent) so they can be merged directly
/// into the sync batch, exactly like the VO2_MAX bridge.
///
/// Always returns [] on Android, iOS Simulator, and OS versions that don't
/// expose the type (Apple Watch S9+/watchOS 10+ hardware only) — never throws.
class SleepApneaChannel {
  static const _channel = MethodChannel('com.tikcare.vitametric/sleepapnea');

  /// Same test seam as Vo2MaxChannel: injectable so unit tests on
  /// macOS/Linux CI can drive the MethodChannel mock through the identical
  /// code path an iOS device uses.
  @visibleForTesting
  static bool platformIsIosOverride = Platform.isIOS;

  /// Requests HealthKit read authorization for apnea events. Call from the
  /// FOREGROUND permission flow — a headless background isolate cannot
  /// present the sheet. Additive only: false must never block a sync.
  static Future<bool> requestAuthorization() async {
    if (!platformIsIosOverride) return false;
    try {
      final granted = await _channel.invokeMethod<bool>('requestAuthorization');
      return granted ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Returns apnea events in [start, end) as ready-to-upload event maps.
  /// One event per detected episode, value 1.0 — the backend sums per night
  /// (DAILY_SUM_METRICS) into an AHI proxy.
  static Future<List<Map<String, dynamic>>> readApneaEvents(
    DateTime start,
    DateTime end,
  ) async {
    if (!platformIsIosOverride) return const [];
    try {
      final raw = await _channel.invokeListMethod<Object>('readApneaEvents', {
        'startMs': start.millisecondsSinceEpoch,
        'endMs': end.millisecondsSinceEpoch,
      });
      if (raw == null || raw.isEmpty) return const [];

      return raw.whereType<Map>().map((e) {
        return <String, dynamic>{
          'metric_type': 'SLEEP_APNEA_EVENT',
          'value': (e['value'] as num?)?.toDouble() ?? 1.0,
          'unit': 'count',
          'start_time': e['start_time'] as String? ?? '',
          'end_time': e['end_time'] as String? ?? '',
          'tz_offset_min': DateTime.now().timeZoneOffset.inMinutes,
          'source_device': e['source_name'] as String? ?? '',
          'source_app_id': e['source_id'] as String? ?? '',
          'device_model_raw': e['device_model'] as String? ?? '',
          'source_platform': 'HEALTHKIT',
          'algorithm_metadata': {
            'source_algorithm': e['source_algorithm'] as String? ??
                'watchOS_breathing_disturbances',
          },
        };
      }).toList();
    } on PlatformException {
      // Authorization denied, HealthKit unavailable on simulator, etc.
      return const [];
    } on MissingPluginException {
      // Channel not registered on this engine (older native build).
      return const [];
    }
  }
}
