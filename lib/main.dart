import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'screens/splash_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/main_tab_screen.dart';
import 'screens/login_screen.dart';
import 'screens/register_screen.dart';
import 'screens/forgot_password_screen.dart';
import 'services/health_service.dart';

const _bgSyncTask = 'lifepulse.periodicSync';

/// Called by WorkManager in a separate Dart isolate — must be a top-level function.
@pragma('vm:entry-point')
void callbackDispatcher() {
  // Required: initialise platform-channel binding before any plugin (Health,
  // FlutterSecureStorage) is used from this background isolate.
  WidgetsFlutterBinding.ensureInitialized();
  Workmanager().executeTask((task, inputData) async {
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
          await Workmanager().cancelByUniqueName('periodicHealthSync');
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
        // maxDays: 2 — iOS background tasks are killed after ~30 seconds.
        // Capping the sync window to 2 days ensures we always finish in time.
        // Full 180-day first syncs happen in the foreground only.
        await HealthService.syncDirect(maxDays: 2);
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

  // health package v13 requires configure() before any HealthKit/HC call.
  // Use HealthService's guard so the static flag is set, preventing a
  // redundant second configure() when HealthService methods are called later.
  await HealthService.ensureHealthConfigured();

  final prefs = await SharedPreferences.getInstance();

  await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);

  final loggedIn = await HealthService.isLoggedIn();
  if (loggedIn) {
    await Workmanager().registerPeriodicTask(
      'periodicHealthSync',
      _bgSyncTask,
      frequency: const Duration(hours: 6),
      existingWorkPolicy: ExistingWorkPolicy.keep,
      constraints: Constraints(networkType: NetworkType.connected),
    );
  }

  final onboardingDone = prefs.getBool('onboarding_done') ?? false;
  runApp(TikCareLifePulseApp(prefs: prefs, onboardingDone: onboardingDone));
}

class TikCareLifePulseApp extends StatelessWidget {
  final SharedPreferences prefs;
  final bool onboardingDone;
  const TikCareLifePulseApp({
    super.key,
    required this.prefs,
    required this.onboardingDone,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TikCare LifePulse',
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
      },
    );
  }
}
