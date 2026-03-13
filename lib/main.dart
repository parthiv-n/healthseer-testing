import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'screens/home_screen.dart';
import 'screens/config_screen.dart';
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
  final loggedIn = await HealthService.isLoggedIn();

  // Initialise background sync (iOS Background Fetch / Android WorkManager).
  // isInDebugMode: false — keeps the OS scheduling unaffected in TestFlight.
  await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);

  if (loggedIn) {
    // Register a periodic task. iOS lets the OS decide exact timing (≥ 15 min).
    // ExistingWorkPolicy.keep means we don't re-queue if one is already pending.
    await Workmanager().registerPeriodicTask(
      'periodicHealthSync',
      _bgSyncTask,
      frequency: const Duration(hours: 6),
      existingWorkPolicy: ExistingWorkPolicy.keep,
      constraints: Constraints(networkType: NetworkType.connected),
    );
  }

  runApp(TikCareLifePulseApp(prefs: prefs, loggedIn: loggedIn));
}

class TikCareLifePulseApp extends StatelessWidget {
  final SharedPreferences prefs;
  final bool loggedIn;
  const TikCareLifePulseApp({super.key, required this.prefs, required this.loggedIn});

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
      initialRoute: loggedIn ? '/home' : '/',
      routes: {
        '/': (ctx) => const LoginScreen(),
        '/register': (ctx) => const RegisterScreen(),
        '/home': (ctx) => HomeScreen(prefs: prefs),
        '/config': (ctx) => ConfigScreen(prefs: prefs),
      },
    );
  }
}
