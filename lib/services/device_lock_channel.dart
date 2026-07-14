import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Dart-side wrapper for the native protected-data check
/// (ios/Runner/DeviceLockChannel.swift).
///
/// The HealthKit store is file-protected: while the device is locked,
/// queries silently return zero samples instead of throwing. A background
/// sync that runs on a locked device (BGAppRefreshTask fires exactly then —
/// idle, charging, overnight) would otherwise read nothing and report a
/// successful "Already up to date" sync. Callers check this BEFORE reading
/// HealthKit and convert an unreadable store into a retryable failure.
///
/// Fails open: returns true on Android, on simulators, and on any channel
/// error — a broken diagnostic must never block a real sync.
class DeviceLockChannel {
  static const _channel = MethodChannel('com.tikcare.vitametric/devicelock');

  /// Test seam: gate the iOS platform check via an injectable bool so unit
  /// tests on Windows / macOS / Linux CI can drive the MethodChannel mock
  /// through the same locked-device code path a real iPhone uses. Without it
  /// the ``Platform.isIOS`` short-circuit below returns true on every test
  /// host and the mock handler is never reached.
  ///
  /// Production code never overrides this; the default is the real runtime
  /// ``Platform.isIOS`` value.
  @visibleForTesting
  static bool platformIsIosOverride = Platform.isIOS;

  static Future<bool> isProtectedDataAvailable() async {
    if (!platformIsIosOverride) return true;
    try {
      final available =
          await _channel.invokeMethod<bool>('isProtectedDataAvailable');
      return available ?? true;
    } catch (_) {
      // MissingPluginException (older native build), PlatformException, etc.
      return true;
    }
  }
}
