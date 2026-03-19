import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'screens/splash_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/main_tab_screen.dart';
import 'screens/login_screen.dart';
import 'screens/register_screen.dart';
import 'services/health_service.dart';

const _bgSyncTask = 'lifepulse.periodicSync';

/// Called by WorkManager in a separate Dart isolate — must be a top-level function.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task == _bgSyncTask) {
      await HealthService.syncDirect();
    }
    return true;
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
        ),
        useMaterial3: true,
        fontFamily: 'SF Pro Display',
      ),
      // Show onboarding if first launch; otherwise go to splash → login/home
      home: onboardingDone ? const SplashScreen() : const OnboardingScreen(),
      routes: {
        '/': (ctx) => const SplashScreen(),
        '/onboarding': (ctx) => const OnboardingScreen(),
        '/login': (ctx) => const LoginScreen(),
        '/register': (ctx) => const RegisterScreen(),
        '/home': (ctx) => MainTabScreen(prefs: prefs),
        // Legacy route kept for compat
        '/config': (ctx) => MainTabScreen(prefs: prefs, initialTab: 3),
      },
    );
  }
}
