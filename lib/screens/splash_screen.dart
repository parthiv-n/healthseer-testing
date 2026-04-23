import 'package:flutter/material.dart';
import '../services/health_service.dart';
import '../theme/colors.dart';

/// Branded splash screen shown for ~1.2 seconds while auth state is checked.
/// Navigates to /home if logged in, otherwise /login.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;
  late Animation<double> _fade;
  late Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );

    _scale = Tween<double>(begin: 0.7, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: const Interval(0.0, 0.6, curve: Curves.easeOutBack)),
    );
    _fade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: const Interval(0.0, 0.5, curve: Curves.easeIn)),
    );
    _pulse = Tween<double>(begin: 1.0, end: 1.06).animate(
      CurvedAnimation(parent: _ctrl, curve: const Interval(0.6, 1.0, curve: Curves.easeInOut)),
    );

    _ctrl.forward();
    _navigate();
  }

  Future<void> _navigate() async {
    await Future.delayed(const Duration(milliseconds: 1200));
    if (!mounted) return;
    final loggedIn = await HealthService.isLoggedIn();
    if (!mounted) return;
    if (loggedIn) {
      // Proactively refresh token — if near expiry or expired, attempt renewal
      // before entering the app so the first data fetch doesn't hit 401.
      await HealthService.refreshTokenIfNeeded();
      if (!mounted) return;
      // Re-check after refresh: if the token was expired and the refresh failed
      // (e.g., network offline), the stored token was cleared. Navigate directly
      // to login rather than letting the home screen flicker and then kick out.
      final stillLoggedIn = await HealthService.isLoggedIn();
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, stillLoggedIn ? '/home' : '/login');
    } else {
      Navigator.pushReplacementNamed(context, '/login');
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [kNavy, kNavyLight, Color(0xFF3A6BC4)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Center(
            child: AnimatedBuilder(
              animation: _ctrl,
              builder: (_, __) => FadeTransition(
                opacity: _fade,
                child: ScaleTransition(
                  scale: _scale,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Pulse ring + logo
                      Stack(
                        alignment: Alignment.center,
                        children: [
                          // Outer pulse ring
                          Transform.scale(
                            scale: _pulse.value,
                            child: Container(
                              width: 130,
                              height: 130,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.15),
                                  width: 1.5,
                                ),
                              ),
                            ),
                          ),
                          // Inner circle background
                          Container(
                            width: 108,
                            height: 108,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.12),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.3),
                                width: 1,
                              ),
                            ),
                          ),
                          // Heart icon — landscape jpeg looks cropped in circle
                          const Icon(Icons.favorite, color: Colors.white, size: 48),
                        ],
                      ),

                      const SizedBox(height: 28),

                      // App name
                      const Text(
                        'TikCare LifePulse',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                        ),
                      ),

                      const SizedBox(height: 6),

                      // Tagline
                      Text(
                        'Your health, intelligently understood.',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.75),
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                          letterSpacing: 0.1,
                        ),
                      ),

                      const SizedBox(height: 48),

                      // Heartbeat / loading indicator
                      SizedBox(
                        width: 32,
                        height: 2,
                        child: LinearProgressIndicator(
                          backgroundColor: Colors.white.withValues(alpha: 0.2),
                          valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      ),

                      const SizedBox(height: 80),

                      // Footer
                      Text(
                        'Powered by TikCare AI',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.4),
                          fontSize: 11,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
