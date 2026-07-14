// Pins locked-device detection.
//
// Two layers, matching the precedent in test/sync_fixes_test.dart:
//
//   1. A MethodChannel test (pattern: test/vo2max_channel_test.dart:39-48):
//      mock the native protected-data check to return false and assert the
//      Dart wrapper reports the store as UNREADABLE (locked). Plus fail-open
//      behaviour (available / channel error / non-iOS all report readable).
//
//   2. A source assertion that _doSyncDirect actually consults
//      isProtectedDataAvailable BEFORE reading HealthKit and converts a locked
//      store into a deviceLocked FAILURE (not a green "up to date" success).
//      The full sync path can't be unit-invoked — the static Health() plugin
//      has no seam — so this guards the wiring the channel test alone can't.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vitametric_app/services/device_lock_channel.dart';

const _channelName = 'com.tikcare.vitametric/devicelock';

void _mockAvailable(Object? returnValue) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel(_channelName),
    (call) async {
      if (call.method == 'isProtectedDataAvailable') return returnValue;
      throw PlatformException(code: 'UNIMPLEMENTED');
    },
  );
}

void _clearChannel() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel(_channelName), null);
}

/// Slice a named method body so an assertion can't drift into a neighbour.
String _methodBody(String src, String signature) {
  final start = src.indexOf(signature);
  expect(start, greaterThan(-1),
      reason: '"$signature" not found — renamed or reformatted.');
  final next = src.indexOf('\n  static ', start + signature.length);
  final end = next == -1 ? src.length : next;
  return src.substring(start, end);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Drive the iOS-only code path on a non-iOS test runner.
  setUp(() {
    DeviceLockChannel.platformIsIosOverride = true;
  });

  tearDown(() {
    _clearChannel();
    DeviceLockChannel.platformIsIosOverride = Platform.isIOS;
  });

  group('DeviceLockChannel.isProtectedDataAvailable', () {
    test('reports LOCKED (false) when native says protected data unavailable',
        () async {
      _mockAvailable(false);
      final available = await DeviceLockChannel.isProtectedDataAvailable();
      expect(available, isFalse,
          reason: 'a locked device must be reported as unreadable so the sync '
              'fails and WorkManager retries, not recorded as up-to-date');
    });

    test('reports readable (true) when native says protected data available',
        () async {
      _mockAvailable(true);
      expect(await DeviceLockChannel.isProtectedDataAvailable(), isTrue);
    });

    test('fails open (true) on a channel error', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(_channelName),
        (_) async => throw PlatformException(code: 'BOOM'),
      );
      expect(await DeviceLockChannel.isProtectedDataAvailable(), isTrue,
          reason: 'a broken diagnostic must never block a real sync');
    });

    test('fails open (true) on a null channel response', () async {
      _mockAvailable(null);
      expect(await DeviceLockChannel.isProtectedDataAvailable(), isTrue);
    });

    test('short-circuits to true on non-iOS without touching the channel',
        () async {
      DeviceLockChannel.platformIsIosOverride = false;
      // No mock registered — a channel call would throw MissingPluginException.
      expect(await DeviceLockChannel.isProtectedDataAvailable(), isTrue);
    });
  });

  group('_doSyncDirect locked-device guard (source pin)', () {
    late String body;

    setUp(() {
      final src =
          File('lib/services/health_service.dart').readAsStringSync();
      body = _methodBody(src, 'static Future<SyncResult> _doSyncDirect({');
    });

    test('consults isProtectedDataAvailable', () {
      expect(body.contains('DeviceLockChannel.isProtectedDataAvailable()'),
          isTrue,
          reason: 'the sync path must check the protected-data flag before '
              'reading HealthKit');
    });

    test('a locked store returns a deviceLocked FAILURE, not success', () {
      // The guard is `if (!await ...isProtectedDataAvailable())` returning a
      // failed SyncResult tagged deviceLocked.
      final guardIdx = body.indexOf('!await DeviceLockChannel.isProtectedDataAvailable()');
      expect(guardIdx, greaterThan(-1),
          reason: 'the guard must negate the availability check');
      final deviceLockedIdx =
          body.indexOf('SyncErrorType.deviceLocked', guardIdx);
      expect(deviceLockedIdx, greaterThan(guardIdx),
          reason: 'the negated guard must return errorType deviceLocked');
      // Prove it is NOT recorded as a success.
      final slice = body.substring(guardIdx, deviceLockedIdx);
      expect(slice.contains('success: false'), isTrue,
          reason: 'a locked device must be a failure so it is retried, never '
              'a green "Already up to date" success');
    });
  });
}
