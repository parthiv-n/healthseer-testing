import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Dart-side wrapper for the native VO2_MAX MethodChannel.
///
/// The Flutter `health` package v13.x does not expose HKQuantityTypeIdentifierVO2Max.
/// This wrapper calls the Swift bridge in ios/Runner/Vo2MaxChannel.swift and returns
/// events already formatted as mobile-sync payloads (same shape as
/// HealthService._convertToMobileSyncEvent) so they can be merged directly into the
/// sync batch without further transformation.
///
/// Always returns [] on Android and iOS Simulator — never throws.
class Vo2MaxChannel {
  static const _channel = MethodChannel('com.tikcare.vitametric/vo2max');

  /// Round-9: gate the platform check via an injectable bool so unit
  /// tests on macOS / Linux CI can drive the MethodChannel mock through
  /// the same code path the iOS device uses.  Pre-fix the
  /// ``Platform.isIOS`` short-circuit at line 25 returned ``[]`` on
  /// every test environment, the mock handler was never reached, and
  /// every dart-side mapping assertion silently passed an empty
  /// fixture — so the round-7 audit found a red test that the
  /// "passing" round-6 build had been hiding.
  ///
  /// Production code never overrides this; the default is the real
  /// runtime ``Platform.isIOS`` value.
  @visibleForTesting
  static bool platformIsIosOverride = Platform.isIOS;

  /// Requests HealthKit read authorization for VO2_MAX.
  ///
  /// VO2_MAX is not in the `health` plugin's permission list, so it is NOT
  /// covered by the onboarding permission sheet. Before this method existed
  /// the authorization was only requested lazily inside [readVo2Max] — in the
  /// middle of a sync, and possibly from a headless background isolate where
  /// iOS cannot present the sheet, leaving authorization undetermined and
  /// every read empty forever. Call this from the FOREGROUND permission flow.
  ///
  /// Returns false on Android, simulators, or any channel error — callers
  /// must treat VO2 authorization as additive, never blocking.
  static Future<bool> requestAuthorization() async {
    if (!platformIsIosOverride) return false;
    try {
      final granted = await _channel.invokeMethod<bool>('requestAuthorization');
      return granted ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Returns VO2_MAX samples in [start, end) as ready-to-upload event maps.
  ///
  /// Each map contains: metric_type, value, unit, start_time, end_time,
  /// source_device, source_app_id, device_model_raw, source_platform,
  /// algorithm_metadata — matching the mobile-sync event schema.
  static Future<List<Map<String, dynamic>>> readVo2Max(
    DateTime start,
    DateTime end,
  ) async {
    if (!platformIsIosOverride) return const [];
    try {
      final raw = await _channel.invokeListMethod<Object>('readVo2Max', {
        'startMs': start.millisecondsSinceEpoch,
        'endMs': end.millisecondsSinceEpoch,
      });
      if (raw == null || raw.isEmpty) return const [];

      return raw.whereType<Map>().map((e) {
        final value = (e['value'] as num?)?.toDouble();
        if (value == null) return null;
        return <String, dynamic>{
          'metric_type': 'VO2_MAX',
          'value': value,
          'unit': 'ml/kg/min',
          'start_time': e['start_time'] as String? ?? '',
          'end_time': e['end_time'] as String? ?? '',
          'tz_offset_min': DateTime.now().timeZoneOffset.inMinutes,
          'source_device': e['source_name'] as String? ?? '',
          'source_app_id': e['source_id'] as String? ?? '',
          'device_model_raw': e['device_model'] as String? ?? '',
          'source_platform': 'HEALTHKIT',
          'algorithm_metadata': {
            'source_algorithm': e['source_algorithm'] as String? ?? 'HealthKit_VO2Max',
          },
        };
      }).whereType<Map<String, dynamic>>().toList();
    } on PlatformException catch (e) {
      // Authorization denied, HealthKit unavailable on simulator, etc.
      // Never propagate — VO2_MAX is additive, not blocking.
      assert(() {
        // ignore: avoid_print
        print('[Vo2MaxChannel] PlatformException: ${e.message}');
        return true;
      }());
      return const [];
    } on MissingPluginException {
      // Channel not registered on this engine. The headless background
      // isolate now registers it via the WorkManager registrant callback in
      // AppDelegate, but a Dart build running against an older native build
      // throws here — and MissingPluginException is NOT a PlatformException,
      // so it previously escaped and failed the entire background sync.
      return const [];
    }
  }
}
