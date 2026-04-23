import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/colors.dart';

/// Three-page onboarding shown once on first app launch.
/// On "Get Started", saves [onboarding_done] = true then navigates to /login.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageCtrl = PageController();
  int _currentPage = 0;

  static const _pages = [
    _OnboardingPage(
      icon: Icons.favorite,
      title: 'Welcome to TikCare',
      subtitle:
          'TikCare LifePulse intelligently analyzes your wearable health data '
          'to help your insurance provider understand and support your wellbeing.',
      iconColor: kRed,
    ),
    _OnboardingPage(
      icon: Icons.sync_rounded,
      title: 'How it works',
      subtitle:
          'Your Apple Watch or wearable syncs health metrics every 6 hours. '
          'TikCare AI analyzes patterns like heart rate, HRV, sleep, and activity '
          'to detect meaningful changes and generate your Health Risk Index.',
      iconColor: kNavyLight,
    ),
    _OnboardingPage(
      icon: Icons.shield_outlined,
      title: 'Your privacy',
      subtitle:
          'Your health data is shared with your insurance provider solely for '
          'risk scoring and wellbeing support. GPS location, contacts, and '
          'photos are never accessed. You may request deletion of your data '
          'at any time.',
      iconColor: kGreen,
    ),
  ];

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  bool _navigating = false;

  Future<void> _onGetStarted() async {
    if (_navigating) return;
    _navigating = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_done', true);
    if (mounted) {
      Navigator.pushReplacementNamed(context, '/login');
    }
  }

  void _nextPage() {
    _pageCtrl.nextPage(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _currentPage == _pages.length - 1;

    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Column(
          children: [
            // Skip button (top-right)
            Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 12, 16, 0),
                child: TextButton(
                  onPressed: _onGetStarted,
                  child: const Text(
                    'Skip',
                    style: TextStyle(color: Colors.grey, fontSize: 14),
                  ),
                ),
              ),
            ),

            // Page content
            Expanded(
              child: PageView.builder(
                controller: _pageCtrl,
                onPageChanged: (i) => setState(() => _currentPage = i),
                itemCount: _pages.length,
                itemBuilder: (_, i) => _PageContent(page: _pages[i]),
              ),
            ),

            // Dot indicator + Next/Get Started button
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
              child: Column(
                children: [
                  _DotIndicator(
                    count: _pages.length,
                    current: _currentPage,
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: isLast ? _onGetStarted : _nextPage,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: kNavy,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        elevation: 0,
                      ),
                      child: Text(
                        isLast ? 'Get Started' : 'Next',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Data class for one onboarding page ────────────────────────────────────────

class _OnboardingPage {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color iconColor;

  const _OnboardingPage({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.iconColor,
  });
}

// ── Page content widget ───────────────────────────────────────────────────────

class _PageContent extends StatelessWidget {
  final _OnboardingPage page;
  const _PageContent({required this.page});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Large icon circle
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: page.iconColor.withValues(alpha: 0.1),
              shape: BoxShape.circle,
              border: Border.all(
                color: page.iconColor.withValues(alpha: 0.25),
                width: 2,
              ),
            ),
            child: Icon(page.icon, size: 54, color: page.iconColor),
          ),

          const SizedBox(height: 40),

          // Title
          Text(
            page.title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: kNavy,
              letterSpacing: -0.4,
              height: 1.2,
            ),
          ),

          const SizedBox(height: 16),

          // Subtitle
          Text(
            page.subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 15,
              color: Colors.black54,
              height: 1.55,
            ),
          ),

          // TikCare branding row
          const SizedBox(height: 40),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [kNavy, kNavyLight],
                  ),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.favorite, color: Colors.white, size: 12),
              ),
              const SizedBox(width: 7),
              const Text(
                'TikCare LifePulse',
                style: TextStyle(
                  fontSize: 13,
                  color: kNavy,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Dot indicator ─────────────────────────────────────────────────────────────

class _DotIndicator extends StatelessWidget {
  final int count;
  final int current;
  const _DotIndicator({required this.count, required this.current});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final isActive = i == current;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: isActive ? 22 : 7,
          height: 7,
          decoration: BoxDecoration(
            color: isActive ? kNavy : Colors.grey.shade300,
            borderRadius: BorderRadius.circular(4),
          ),
        );
      }),
    );
  }
}
