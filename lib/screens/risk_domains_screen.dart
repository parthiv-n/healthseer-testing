import 'package:flutter/material.dart';
import '../services/health_service.dart';
import '../models/daily_report.dart';

// ── Color palette (matches app-wide style) ────────────────────────────────────
const _navy = Color(0xFF1B3A6B);
const _navyLight = Color(0xFF2A5298);
const _green = Color(0xFF38A169);
const _amber = Color(0xFFD97706);
const _red = Color(0xFFE53E3E);
const _bg = Color(0xFFF7F9FC);

Color _scoreColor(double score) {
  if (score < 30) return _green;
  if (score < 60) return _amber;
  return _red;
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final report = await HealthService.fetchDailyReport();
    if (mounted) {
      setState(() {
        _report = report;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 100,
            pinned: true,
            backgroundColor: _navy,
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [_navy, _navyLight],
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
          if (_loading)
            const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator(color: _navy)),
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
              style: OutlinedButton.styleFrom(foregroundColor: _navy),
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
    ('cardiovascular', 'Cardiovascular', Icons.favorite),
    ('activity', 'Activity', Icons.directions_run),
    ('sleep', 'Sleep', Icons.bedtime),
    ('recovery', 'Recovery', Icons.refresh),
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
    (String, String, IconData) domain,
    DailyReport report,
  ) {
    final (key, title, icon) = domain;
    final dim = report.dimensions[key];
    return _DomainCard(key: ValueKey(key), title: title, icon: icon, dim: dim);
  }
}

// ── Single domain card ─────────────────────────────────────────────────────────
class _DomainCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final DimensionScore? dim;

  const _DomainCard({
    super.key,
    required this.title,
    required this.icon,
    required this.dim,
  });

  @override
  Widget build(BuildContext context) {
    if (dim == null) {
      return _PlaceholderCard(title: title, icon: icon);
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
          // Header row: icon + title
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
                    color: _navy,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
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
        ],
      ),
    );
  }
}

// ── Placeholder card when dimension data is missing ───────────────────────────
class _PlaceholderCard extends StatelessWidget {
  final String title;
  final IconData icon;
  const _PlaceholderCard({required this.title, required this.icon});

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
                    color: _navy,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
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
                    color: _navy,
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
