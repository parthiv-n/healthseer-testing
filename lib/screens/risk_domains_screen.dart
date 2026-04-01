import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/health_service.dart';
import '../models/daily_report.dart';
import '../theme/colors.dart';

// ── HRV Unified Score card ─────────────────────────────────────────────────────
class _HrvUnifiedCard extends StatelessWidget {
  final HrvUnifiedScore score;
  const _HrvUnifiedCard({required this.score});

  Color get _color {
    if (score.score >= 75) return kGreen;
    if (score.score >= 60) return const Color(0xFF4CAF50);
    if (score.score >= 40) return kAmber;
    if (score.score >= 25) return Colors.orange;
    return kRed;
  }

  String get _trendIcon => switch (score.trendDirection) {
        'improving' => '↑',
        'declining' => '↓',
        _ => '→',
      };

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: _color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.monitor_heart_outlined, size: 18, color: _color),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'HRV Intelligence',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: kNavy),
                ),
              ),
              Text(
                '$_trendIcon ${score.trendDirection}',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                score.score.toStringAsFixed(0),
                style: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.w800,
                  color: _color,
                  height: 1,
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  score.label,
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade600, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: score.score / 100,
              backgroundColor: Colors.grey.shade100,
              valueColor: AlwaysStoppedAnimation<Color>(_color),
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'Confidence: ${(score.confidence * 100).toStringAsFixed(0)}%',
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  score.methodUsed,
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                ),
              ),
            ],
          ),
          if (score.explanation.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              score.explanation,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500, height: 1.4),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

Color _scoreColor(double score) {
  if (score < 30) return kGreen;
  if (score < 60) return kAmber;
  return kRed;
}

/// Maps a risk label string to a display-friendly string.
String _labelDisplay(String label) => switch (label.toLowerCase()) {
      'low' => 'Low Risk',
      'moderate' => 'Moderate',
      'high' => 'High Risk',
      'critical' => 'Critical',
      _ => label,
    };

/// Shows the 4 risk domain cards (cardiovascular, activity, sleep, recovery)
/// sourced from the latest cached DailyReport.
class RiskDomainsScreen extends StatefulWidget {
  const RiskDomainsScreen({super.key});

  @override
  State<RiskDomainsScreen> createState() => _RiskDomainsScreenState();
}

class _RiskDomainsScreenState extends State<RiskDomainsScreen> {
  DailyReport? _report;
  bool _loading = true;
  bool _autoSyncing = false;
  // Guard: auto-sync runs at most once per screen lifetime, not on every tab tap.
  bool _autoSyncAttempted = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _autoSyncing = false; });
    final report = await HealthService.fetchDailyReport();
    if (!mounted) return;

    if (report == null || report.dimensions.isEmpty) {
      if (!_autoSyncAttempted) {
        _autoSyncAttempted = true;
        // Only auto-sync if the user has previously completed a sync.
        // If they haven't, HomeScreen manages the first-sync flow with the
        // HealthKit permission dialog. Triggering it here (before the user
        // explicitly taps "Sync") would show the iOS permission sheet without
        // user intent and can cause App Review rejection.
        final prefs = await SharedPreferences.getInstance();
        final hasPrevSync = prefs.getBool('last_sync_success') ?? false;
        if (!mounted) return;
        if (!hasPrevSync) {
          setState(() { _report = null; _loading = false; });
          return;
        }
        // Has synced before — join any ongoing sync or start a background one.
        setState(() { _loading = false; _autoSyncing = true; });
        await HealthService.syncDirect(); // returns immediately if sync is running
        if (!mounted) return;
        setState(() { _autoSyncing = false; _loading = true; });
        if (!mounted) return;
        final refreshed = await HealthService.fetchDailyReport();
        if (mounted) setState(() { _report = refreshed; _loading = false; });
      } else {
        // Already tried once — show empty state without re-triggering.
        if (mounted) setState(() { _report = null; _loading = false; });
      }
    } else {
      setState(() { _report = report; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 100,
            pinned: true,
            backgroundColor: kNavy,
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [kNavy, kNavyLight],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: const SafeArea(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          'Risk Domains',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Today\'s health risk breakdown',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_loading || _autoSyncing)
            SliverFillRemaining(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(color: kNavy, strokeWidth: 2),
                    const SizedBox(height: 16),
                    Text(
                      _autoSyncing ? 'Syncing your health data…' : 'Loading…',
                      style: const TextStyle(fontSize: 13, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            )
          else if (_report == null || _report!.dimensions.isEmpty)
            SliverFillRemaining(
              child: _EmptyState(onRefresh: _load),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  _DomainGrid(report: _report!),
                  const SizedBox(height: 16),
                  _OverallBanner(report: _report!),
                  if (_report!.healthScores?.hrvUnified != null) ...[
                    const SizedBox(height: 16),
                    _HrvUnifiedCard(score: _report!.healthScores!.hrvUnified!),
                  ],
                  const SizedBox(height: 24),
                ]),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Empty / no-data state ──────────────────────────────────────────────────────
class _EmptyState extends StatelessWidget {
  final VoidCallback onRefresh;
  const _EmptyState({required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.analytics_outlined, size: 64, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            Text(
              'Sync your health data to see risk scores',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey.shade600,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Risk domain scores are computed from your daily health metrics.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
              style: OutlinedButton.styleFrom(foregroundColor: kNavy),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 2-column domain grid ───────────────────────────────────────────────────────
class _DomainGrid extends StatelessWidget {
  final DailyReport report;
  const _DomainGrid({required this.report});

  static const _domains = [
    (
      'cardiovascular',
      'Cardiovascular',
      Icons.favorite,
      'Tracks heart rate, HRV, blood oxygen, and resting HR.\n\nA high score means unusual cardiac patterns were detected relative to your personal baseline. Score < 30 is optimal.',
    ),
    (
      'activity',
      'Activity',
      Icons.directions_run,
      'Tracks daily steps, active energy, and movement patterns.\n\nA high score means your activity is significantly lower or more erratic than your usual baseline. Score < 30 is optimal.',
    ),
    (
      'sleep',
      'Sleep',
      Icons.bedtime,
      'Tracks sleep duration and quality.\n\nA high score means disrupted or insufficient sleep compared to your baseline. Consistent 7–9 hours targets score < 30.',
    ),
    (
      'recovery',
      'Recovery',
      Icons.refresh,
      'Tracks HRV trends and physiological recovery indicators.\n\nA high score means your body is showing signs of inadequate recovery — often linked to stress, illness, or overtraining.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: _domainCard(_domains[0], report)),
            const SizedBox(width: 12),
            Expanded(child: _domainCard(_domains[1], report)),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: _domainCard(_domains[2], report)),
            const SizedBox(width: 12),
            Expanded(child: _domainCard(_domains[3], report)),
          ],
        ),
      ],
    );
  }

  Widget _domainCard(
    (String, String, IconData, String) domain,
    DailyReport report,
  ) {
    final (key, title, icon, tooltip) = domain;
    final dim = report.dimensions[key];
    return _DomainCard(key: ValueKey(key), title: title, icon: icon, dim: dim, tooltip: tooltip);
  }
}

// ── Single domain card ─────────────────────────────────────────────────────────
class _DomainCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final DimensionScore? dim;
  final String tooltip;

  const _DomainCard({
    super.key,
    required this.title,
    required this.icon,
    required this.dim,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    if (dim == null) {
      return _PlaceholderCard(title: title, icon: icon, tooltip: tooltip);
    }

    final score = dim!.score;
    final color = _scoreColor(score);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row: icon + title + info button
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 18, color: color),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: kNavy,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              GestureDetector(
                onTap: () => _showTooltip(context),
                child: Icon(Icons.info_outline, size: 15, color: Colors.grey.shade400),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Large score number
          Text(
            score.toStringAsFixed(0),
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w800,
              color: color,
              height: 1,
            ),
          ),
          const SizedBox(height: 4),
          // Score bar
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: score / 100,
              backgroundColor: Colors.grey.shade100,
              valueColor: AlwaysStoppedAnimation<Color>(color),
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 8),
          // Confidence chip
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              'Confidence: ${(dim!.confidence * 100).toStringAsFixed(0)}%',
              style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
            ),
          ),
          // Drivers list (only if non-empty)
          if (dim!.drivers.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...dim!.drivers.map(
              (d) => Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '\u2022 $d',
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade700),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
          // High-score CTA
          if (score >= 60) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: kRed.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'Consider discussing this with your doctor.',
                style: TextStyle(fontSize: 10, color: kRed, height: 1.3),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _showTooltip(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: kNavy),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: kNavy),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              tooltip,
              style: const TextStyle(fontSize: 14, color: Colors.black87, height: 1.5),
            ),
            const SizedBox(height: 12),
            const Text(
              'Score range:  0–29 Low · 30–59 Moderate · 60–100 High',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Placeholder card when dimension data is missing ───────────────────────────
class _PlaceholderCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final String tooltip;
  const _PlaceholderCard({
    required this.title,
    required this.icon,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 18, color: Colors.grey.shade400),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: kNavy,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              GestureDetector(
                onTap: () => _showTooltip(context),
                child: Icon(Icons.info_outline, size: 15, color: Colors.grey.shade400),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'Computing...',
            style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
          ),
        ],
      ),
    );
  }

  void _showTooltip(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, size: 20, color: kNavy),
              const SizedBox(width: 8),
              Text(title,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: kNavy)),
            ]),
            const SizedBox(height: 14),
            Text(tooltip,
                style: const TextStyle(fontSize: 14, color: Colors.black87, height: 1.5)),
            const SizedBox(height: 12),
            const Text(
              'Score range:  0–29 Low · 30–59 Moderate · 60–100 High',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Overall composite banner ──────────────────────────────────────────────────
class _OverallBanner extends StatelessWidget {
  final DailyReport report;
  const _OverallBanner({required this.report});

  @override
  Widget build(BuildContext context) {
    final composite = report.compositeScore;
    final label = report.compositeLabel ?? report.hriLabel;
    final score = composite ?? report.hri;
    final color = _scoreColor(score);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.shield_outlined, size: 26, color: color),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Overall Risk',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: kNavy,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _labelDisplay(label),
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ),
          Text(
            score.toStringAsFixed(0),
            style: TextStyle(
              fontSize: 36,
              fontWeight: FontWeight.w800,
              color: color,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}
