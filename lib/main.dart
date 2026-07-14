import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'screens/splash_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/main_tab_screen.dart';
import 'screens/login_screen.dart';
import 'screens/register_screen.dart';
import 'screens/forgot_password_screen.dart';
import 'screens/dev_tools_screen.dart';
import 'services/health_service.dart';
import 'services/sync_state.dart';
import 'services/sync_telemetry.dart';

const _bgSyncTask = 'vitametric.periodicSync';

/// Called by WorkManager in a separate Dart isolate — must be a top-level function.
@pragma('vm:entry-point')
void callbackDispatcher() {
  // Required: initialise platform-channel binding before any plugin (Health,
  // FlutterSecureStorage) is used from this background isolate.
  WidgetsFlutterBinding.ensureInitialized();
  Workmanager().executeTask((task, inputData) async {
    // Static fields don't share across Dart isolates.  Re-wire telemetry
    // here so the background sync's SyncTelemetry.record() calls have a
    // resolver and can flush; otherwise events accumulate in the
    // background isolate's SharedPreferences buffer and only drain on
    // the next foreground launch.
    SyncTelemetry.wire(resolver: HealthService.telemetryAuthResolver);

    // health package v13 requires configure() before any HealthKit/HC call.
    await HealthService.ensureHealthConfigured();

    if (task == _bgSyncTask) {
      // If the user logged out, stop scheduling background syncs rather than
      // retrying indefinitely with no credentials (wastes battery + backoff slots).
      // Wrapped in try/catch: Keychain reads can fail in background isolates
      // if the device has not been unlocked since reboot.
      try {
        final loggedIn = await HealthService.isLoggedIn();
        if (!loggedIn) {
          await Workmanager().cancelByUniqueName(_bgSyncTask);
          return true; // success = no retry
        }
      } catch (_) {
        return false; // retry later when device is unlocked
      }
      // Skip if a foreground sync completed recently (static fields don't
      // share across Dart isolates, so we use a SharedPreferences timestamp).
      if (await HealthService.isSyncRecentlyActive(minutes: 5)) {
        return true; // no-op — foreground already synced
      }
      try {
        // maxDays: 7 — iOS background tasks are killed after ~30 seconds, so
        // the window must stay bounded, but the old 2-day cap meant any gap
        // older than 2 days (user didn't open the app for a long weekend)
        // could never be repaired by a background run. 7 days of HR+steps is
        // a few thousand events ≈ 1-2 upload batches — still comfortably
        // inside the BGTask budget. Full 180-day first syncs remain
        // foreground-only.
        await HealthService.syncDirect(
          maxDays: 7,
          syncPath: SyncPath.background,
        );
      } catch (_) {
        // Swallow exceptions so WorkManager marks the task failed (not crashed)
        // and schedules a retry instead of terminating the background process.
        return false;
      }
    }
    return true;
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Track A: telemetry resolver wired FIRST — before migrate().  If
  // SharedPreferences is corrupt and migrate() throws, main() still
  // exits with a partially-initialised app, but at least SyncTelemetry
  // has a resolver registered so any queued events from a prior launch
  // can flush on the next successful sync.  Reversing this order (the
  // build-24 bug audit round 5 caught) meant a single migrate() throw
  // permanently stranded the offline telemetry queue.
  SyncTelemetry.wire(
    resolver: HealthService.telemetryAuthResolver,
  );

  // Track B: self-heal migration — runs after telemetry wire so a
  // throw here doesn't strand the queue.  Migrate evicts the dead
  // `lifepulse-api-…run.app` URL that build 22 baked into
  // SharedPreferences for users who logged in before the rename.
  // Migration is idempotent: subsequent launches skip the body.
  // Wrapped so a corrupt-prefs throw doesn't crash the app entirely;
  // the rest of init can still run against in-memory defaults.
  MigrationReport? migrationReport;
  try {
    migrationReport = await SyncStateStore.instance.migrate();
  } catch (e, st) {
    debugPrint('[main] SyncStateStore.migrate() failed (non-fatal): $e\n$st');
  }
  if (migrationReport?.staleUrlCleared != null) {
    debugPrint(
      '[main] cleared stale API URL: ${migrationReport!.staleUrlCleared}',
    );
  }

  // Round-8: load CFBundleShortVersionString / CFBundleVersion into the
  // BuildMetadata cache before SyncTelemetry can fire its first event.
  // Without this, the first sync_attempt would carry app_version='loading'
  // and portal Sync Health would briefly mis-attribute the rollout.
  // Wrapped because package_info_plus throws on a desktop test
  // environment with no platform channel — non-fatal there.
  try {
    await BuildMetadata.ensureLoaded();
  } catch (e, st) {
    debugPrint('[main] BuildMetadata.ensureLoaded() failed (non-fatal): $e\n$st');
  }

  // health package v13 requires configure() before any HealthKit/HC call.
  // Use HealthService's guard so the static flag is set, preventing a
  // redundant second configure() when HealthService methods are called later.
  await HealthService.ensureHealthConfigured();

  final prefs = await SharedPreferences.getInstance();

  await Workmanager().initialize(callbackDispatcher);

  final loggedIn = await HealthService.isLoggedIn();
  if (loggedIn) {
    // uniqueName MUST equal the BGTask identifier from Info.plist
    // (BGTaskSchedulerPermittedIdentifiers): on iOS workmanager submits
    // BGAppRefreshTaskRequest(identifier: uniqueName), so the old
    // 'periodicHealthSync' uniqueName was rejected by BGTaskScheduler on
    // every submit and the background sync was never scheduled.
    await Workmanager().registerPeriodicTask(
      _bgSyncTask,
      _bgSyncTask,
      frequency: const Duration(hours: 6),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      constraints: Constraints(networkType: NetworkType.connected),
    );
  }

  final onboardingDone = prefs.getBool('onboarding_done') ?? false;
  runApp(TikCareVitametricApp(prefs: prefs, onboardingDone: onboardingDone));
}

class TikCareVitametricApp extends StatelessWidget {
  final SharedPreferences prefs;
  final bool onboardingDone;
  const TikCareVitametricApp({
    super.key,
    required this.prefs,
    required this.onboardingDone,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TikCare Vitametric',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1B3A6B),
          brightness: Brightness.light,
          surface: const Color(0xFFF4F3F0),
        ),
        scaffoldBackgroundColor: const Color(0xFFF4F3F0),
        useMaterial3: true,
        fontFamily: 'SF Pro Display',
      ),
      // Show onboarding if first launch; otherwise go to splash → login/home
      home: onboardingDone ? const SplashScreen() : const OnboardingScreen(),
      routes: {
        '/onboarding': (ctx) => const OnboardingScreen(),
        '/login': (ctx) => const LoginScreen(),
        '/register': (ctx) => const RegisterScreen(),
        '/forgot-password': (ctx) => const ForgotPasswordScreen(),
        '/home': (ctx) => MainTabScreen(prefs: prefs),
        // Legacy route: redirect to Profile tab
        '/config': (ctx) => MainTabScreen(prefs: prefs, initialTab: 4),
        // Hidden on-device sync-verification screen (long-press the version
        // label on Profile, or the debug-only "Developer Tools" tile).
        '/dev-tools': (ctx) => const DevToolsScreen(),
      },
    );
  }
}
