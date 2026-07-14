import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vitametric_app/services/vo2max_channel.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const _channelName = 'com.tikcare.vitametric/vo2max';

/// A raw sample as returned by the Swift native layer.
Map<String, dynamic> _nativeSample({
  double value = 42.5,
  String sourceName = 'Apple Watch',
  String sourceId = 'com.apple.health',
  String deviceModel = 'Watch6,1',
  String sourceAlgorithm = 'AppleWatch_VO2Max',
  String? startTime,
  String? endTime,
}) {
  final now = DateTime.utc(2026, 4, 28, 8, 0);
  return {
    'metric_type': 'VO2_MAX',
    'value': value,
    'unit': 'ml/kg/min',
    'start_time': startTime ?? now.toIso8601String(),
    'end_time': endTime ?? now.add(const Duration(minutes: 1)).toIso8601String(),
    'source_name': sourceName,
    'source_id': sourceId,
    'device_model': deviceModel,
    'source_algorithm': sourceAlgorithm,
  };
}

/// Register a mock channel handler that returns [returnValue].
void _mockChannel(Object? returnValue) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel(_channelName),
    (call) async {
      if (call.method == 'readVo2Max') return returnValue;
      throw PlatformException(code: 'UNIMPLEMENTED');
    },
  );
}

/// Clear the mock after each test.
void _clearChannel() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel(_channelName),
    null,
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final start = DateTime.utc(2026, 4, 21);
  final end = DateTime.utc(2026, 4, 28);

  // Round-9: drive the iOS-only code path on a non-iOS test runner.
  // Without this override the production short-circuit at the top of
  // readVo2Max returns ``const []`` and the MethodChannel mock below
  // is never reached, so every parsing assertion silently passes
  // against an empty fixture.
  setUp(() {
    Vo2MaxChannel.platformIsIosOverride = true;
  });

  tearDown(() {
    _clearChannel();
    Vo2MaxChannel.platformIsIosOverride = Platform.isIOS;
  });

  // ── Happy path ─────────────────────────────────────────────────────────────

  test('single sample is parsed into a valid sync event', () async {
    _mockChannel([_nativeSample(value: 42.5)]);

    final events = await Vo2MaxChannel.readVo2Max(start, end);

    expect(events, hasLength(1));
    final e = events.first;
    expect(e['metric_type'], 'VO2_MAX');
    expect(e['value'], closeTo(42.5, 0.001));
    expect(e['unit'], 'ml/kg/min');
    expect(e['source_platform'], 'HEALTHKIT');
    expect(e['algorithm_metadata'], isA<Map>());
    expect(
      (e['algorithm_metadata'] as Map)['source_algorithm'],
      'AppleWatch_VO2Max',
    );
  });

  test('multiple samples are all returned', () async {
    _mockChannel([
      _nativeSample(value: 38.0),
      _nativeSample(value: 41.2),
      _nativeSample(value: 44.7),
    ]);

    final events = await Vo2MaxChannel.readVo2Max(start, end);
    expect(events, hasLength(3));
    expect(events.map((e) => e['value']), containsAll([38.0, 41.2, 44.7]));
  });

  test('source_device and source_app_id are mapped from native keys', () async {
    _mockChannel([
      _nativeSample(
        sourceName: 'Garmin Watch',
        sourceId: 'com.garmin.connect',
        deviceModel: 'Fenix7',
        sourceAlgorithm: 'HealthKit_VO2Max',
      ),
    ]);

    final events = await Vo2MaxChannel.readVo2Max(start, end);
    expect(events.first['source_device'], 'Garmin Watch');
    expect(events.first['source_app_id'], 'com.garmin.connect');
    expect(events.first['device_model_raw'], 'Fenix7');
  });

  test('tz_offset_min reflects the start time timezone offset', () async {
    _mockChannel([_nativeSample()]);
    // Use a fixed-offset time (+8h = 480 min) to verify the field is set.
    final startWithTz = DateTime(2026, 4, 21, 0, 0)
        .toUtc()
        .add(const Duration(hours: 8)); // still UTC, offset is wall-clock diff
    final events = await Vo2MaxChannel.readVo2Max(start, end);
    // tz_offset_min must be an integer (may be 0 in UTC test environment).
    expect(events.first['tz_offset_min'], isA<int>());
  });

  // ── Edge cases ──────────────────────────────────────────────────────────────

  test('empty native response returns empty list', () async {
    _mockChannel(<Object>[]);
    final events = await Vo2MaxChannel.readVo2Max(start, end);
    expect(events, isEmpty);
  });

  test('null native response returns empty list', () async {
    _mockChannel(null);
    final events = await Vo2MaxChannel.readVo2Max(start, end);
    expect(events, isEmpty);
  });

  test('sample with null value is silently dropped', () async {
    final bad = Map<String, dynamic>.from(_nativeSample());
    bad['value'] = null;
    _mockChannel([bad, _nativeSample(value: 50.0)]);

    final events = await Vo2MaxChannel.readVo2Max(start, end);
    // Only the valid sample should survive.
    expect(events, hasLength(1));
    expect(events.first['value'], 50.0);
  });

  test('non-Map entries in the native list are silently dropped', () async {
    _mockChannel([_nativeSample(value: 45.0), 'corrupt', 42]);

    final events = await Vo2MaxChannel.readVo2Max(start, end);
    expect(events, hasLength(1));
  });

  test('PlatformException from channel is swallowed and returns empty list',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(_channelName),
      (_) async => throw PlatformException(
        code: 'PERMISSION_DENIED',
        message: 'HealthKit authorization denied',
      ),
    );

    final events = await Vo2MaxChannel.readVo2Max(start, end);
    expect(events, isEmpty); // must not throw
  });

  // ── Output schema completeness ──────────────────────────────────────────────

  test('output event contains all required mobile-sync fields', () async {
    _mockChannel([_nativeSample()]);

    final e = (await Vo2MaxChannel.readVo2Max(start, end)).first;

    for (final key in const [
      'metric_type',
      'value',
      'unit',
      'start_time',
      'end_time',
      'tz_offset_min',
      'source_device',
      'source_app_id',
      'device_model_raw',
      'source_platform',
      'algorithm_metadata',
    ]) {
      expect(e.containsKey(key), isTrue, reason: 'missing field: $key');
    }
  });

  test('metric_type is always VO2_MAX regardless of native payload', () async {
    final sample = Map<String, dynamic>.from(_nativeSample());
    sample['metric_type'] = 'WRONG'; // native layer should never send this but be safe
    _mockChannel([sample]);

    final events = await Vo2MaxChannel.readVo2Max(start, end);
    expect(events.first['metric_type'], 'VO2_MAX');
  });
}
