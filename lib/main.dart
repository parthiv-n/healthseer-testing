import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/home_screen.dart';
import 'screens/config_screen.dart';
import 'screens/login_screen.dart';
import 'services/health_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final loggedIn = await HealthService.isLoggedIn();
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
        '/home': (ctx) => HomeScreen(prefs: prefs),
        '/config': (ctx) => ConfigScreen(prefs: prefs),
      },
    );
  }
}
