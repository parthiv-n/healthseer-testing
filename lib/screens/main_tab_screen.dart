import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/health_service.dart';
import 'home_screen.dart';
import 'trends_screen.dart';
import 'alerts_screen.dart';
import 'profile_screen.dart';
import '../theme/colors.dart';

/// Root tab navigator: Today | Trends | Alerts | Profile.
///
/// Round-17 phase 2: dropped the "Risk" (Risk Domains) tab.  Its only
/// non-empty content was the per-metric SignalsPanel, which now lives
/// inline on the Today screen.  The empty state ("Sync your health
/// data + Retry") used to mislead operators after a successful sync
/// because the daily report cache was generated pre-sync and showed
/// up empty in a fresh-data window.  Removing the tab eliminates the
/// confusing affordance entirely.
class MainTabScreen extends StatefulWidget {
  final SharedPreferences prefs;
  final int initialTab;
  const MainTabScreen({super.key, required this.prefs, this.initialTab = 0});

  @override
  State<MainTabScreen> createState() => _MainTabScreenState();
}

class _MainTabScreenState extends State<MainTabScreen> {
  late int _currentIndex;
  late List<Widget> _screens;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialTab;
    _screens = [
      HomeScreen(prefs: widget.prefs),
      const TrendsScreen(),
      const AlertsScreen(),
      ProfileScreen(prefs: widget.prefs),
    ];
    HealthService.sessionExpired.addListener(_onSessionExpired);
  }

  @override
  void dispose() {
    HealthService.sessionExpired.removeListener(_onSessionExpired);
    super.dispose();
  }

  bool _sessionExpiredHandled = false;

  void _onSessionExpired() {
    if (_sessionExpiredHandled || !HealthService.sessionExpired.value || !mounted) return;
    _sessionExpiredHandled = true;
    HealthService.sessionExpired.value = false;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Session expired — please sign in again.'),
        backgroundColor: kOrange,
      ),
    );
    Navigator.pushNamedAndRemoveUntil(context, '/login', (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    final screens = _screens;

    // Round-17 phase 2: 10% global text upscale.  The pre-fix UI used
    // fontSize: 9-12 in many tiles/captions, hugging the lower bound of
    // Apple HIG (12pt minimum for "tertiary info") and reading too small
    // on iPhone Pro Max screens at standard system text size.  Wrapping
    // the entire tab tree in a MediaQuery override applies the scale to
    // every Text widget without touching ~150 fontSize literals.  Users
    // who set Larger Text in iOS Accessibility get a multiplicative bump
    // on top of this — they end up at the higher end where they want to
    // be, not the floor.
    final mq = MediaQuery.of(context);
    final scaledMq = mq.copyWith(
      textScaler: TextScaler.linear(mq.textScaler.scale(1.0) * 1.10),
    );

    return MediaQuery(
      data: scaledMq,
      child: Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: screens,
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: kCardBg,
          border: const Border(top: BorderSide(color: kBorderColor, width: 1)),
          boxShadow: const [
            BoxShadow(
              color: kShadowColor,
              blurRadius: 24,
              offset: Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _NavItem(icon: Icons.favorite_border, activeIcon: Icons.favorite, label: 'Today', index: 0, currentIndex: _currentIndex, onTap: (i) => setState(() => _currentIndex = i)),
                _NavItem(icon: Icons.show_chart_outlined, activeIcon: Icons.show_chart, label: 'Trends', index: 1, currentIndex: _currentIndex, onTap: (i) => setState(() => _currentIndex = i)),
                _NavItem(icon: Icons.notifications_outlined, activeIcon: Icons.notifications, label: 'Alerts', index: 2, currentIndex: _currentIndex, onTap: (i) => setState(() => _currentIndex = i)),
                _NavItem(icon: Icons.person_outline, activeIcon: Icons.person, label: 'Profile', index: 3, currentIndex: _currentIndex, onTap: (i) => setState(() => _currentIndex = i)),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final int index;
  final int currentIndex;
  final ValueChanged<int> onTap;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.index,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isActive = index == currentIndex;
    return GestureDetector(
      onTap: () => onTap(index),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isActive ? activeIcon : icon,
              size: 24,
              color: isActive ? kNavy : Colors.grey.shade400,
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: isActive ? FontWeight.w700 : FontWeight.w400,
                color: isActive ? kNavy : Colors.grey.shade400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
