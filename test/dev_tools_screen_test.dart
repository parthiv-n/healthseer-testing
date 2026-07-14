// Widget tests for the hidden Dev Tools screen.
//
// The screen does no network on open — census / attempt-history / sync-state
// all load from SharedPreferences — so it is pumpable with only mock prefs.
// We assert:
//   1. A stored census (dev_last_census_v1) renders its rows.
//   2. Stored attempt history (sync_attempt_history_v1) renders its rows.
//   3. A seeded FAIL CompareRow renders red — verified against the extracted,
//      network-free DevCompareTable widget (design-for-test seam).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:vitametric_app/models/census_report.dart';
import 'package:vitametric_app/services/census_compare.dart';
import 'package:vitametric_app/services/sync_attempt_history.dart';
import 'package:vitametric_app/services/sync_state.dart';
import 'package:vitametric_app/screens/dev_tools_screen.dart';

CensusReport _seedCensus() => CensusReport(
      windowStart: DateTime.utc(2026, 1, 1),
      windowEnd: DateTime.utc(2026, 6, 30),
      rows: const [
        CensusMetricRow(
          hkType: 'HEART_RATE',
          mappedMetric: 'HR_INSTANT',
          rawCount: 1200,
          afterPluginDedup: 1100,
          uploadable: 1100,
        ),
        CensusMetricRow(
          hkType: 'STEPS',
          mappedMetric: 'STEPS_DELTA',
          rawCount: 300,
          afterPluginDedup: 300,
          uploadable: 300,
        ),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> seedPrefs() async {
    final attempts = [
      SyncAttemptRecord(
        at: DateTime.utc(2026, 6, 1, 9, 0),
        path: 'foreground',
        outcome: 'success',
        eventsSent: 128,
      ),
      SyncAttemptRecord(
        at: DateTime.utc(2026, 6, 2, 9, 0),
        path: 'background',
        outcome: 'partial',
        eventsSent: 777,
        errorClass: null,
      ),
    ];
    SharedPreferences.setMockInitialValues({
      'dev_last_census_v1': jsonEncode(_seedCensus().toJson()),
      SyncAttemptHistory.prefsKey:
          jsonEncode(attempts.map((a) => a.toJson()).toList()),
    });
    SyncStateStore.instance.resetForTest();
  }

  testWidgets('renders stored census rows on open', (tester) async {
    await seedPrefs();
    await tester.pumpWidget(const MaterialApp(home: DevToolsScreen()));
    await tester.pumpAndSettle();

    expect(find.text('HEART_RATE'), findsOneWidget);
    expect(find.text('STEPS'), findsOneWidget);
    // Mapped canonical metric also renders.
    expect(find.text('HR_INSTANT'), findsOneWidget);
    // Totals row.
    expect(find.text('TOTAL'), findsOneWidget);
  });

  testWidgets('renders stored sync-attempt history rows', (tester) async {
    await seedPrefs();
    // Tall viewport so the lazy ListView builds the Sync State card (card d),
    // which sits below the fold in the default 600px test surface.
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: DevToolsScreen()));
    await tester.pumpAndSettle();

    // Distinctive values from the seeded attempts.
    expect(find.text('partial'), findsOneWidget);
    expect(find.text('777'), findsOneWidget);
    expect(find.text('background'), findsOneWidget);
  });

  testWidgets('a seeded fail CompareRow renders red', (tester) async {
    const failRow = CompareRow(
      metric: 'STEPS_DELTA',
      hkUploadable: 100,
      serverRawUploaded: 0,
      serverUsable: 0,
      delta: -100,
      deltaPct: null,
      status: CompareStatus.fail,
      note: 'missing on server',
    );
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: DevCompareTable(rows: [failRow]),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // The status pill text 'fail' must be coloured with the fail colour (red).
    final pill = tester.widget<Text>(find.text('fail'));
    expect(pill.style?.color, compareStatusColor(CompareStatus.fail));
    // And that colour is red, not the ok/warn colours.
    expect(compareStatusColor(CompareStatus.fail),
        isNot(compareStatusColor(CompareStatus.ok)));
    expect(compareStatusColor(CompareStatus.fail),
        isNot(compareStatusColor(CompareStatus.warn)));
  });
}
