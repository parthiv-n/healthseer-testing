import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/health_service.dart';
import '../models/anomaly_item.dart';
import 'anomaly_detail_screen.dart';
import '../theme/colors.dart';

class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

enum _FilterPeriod { all, today, week }

const _kDismissedKey = 'dismissed_anomaly_ids';

class _AlertsScreenState extends State<AlertsScreen> {
  List<AnomalyItem>? _anomalies;
  bool _loading = true;
  _FilterPeriod _filter = _FilterPeriod.all;
  Set<String> _dismissed = {};
  bool _hasPreviouslySynced = false;

  /// Compute visible list once — called at the top of build() and cached for the frame.
  List<AnomalyItem> _computeVisible() {
    final all = _anomalies ?? [];
    final now = DateTime.now();
    return all.where((a) {
      if (_dismissed.contains(a.id)) return false;
      return switch (_filter) {
        _FilterPeriod.all => true,
        // "Today" = same calendar day in LOCAL time, not rolling 24h.
        // eventTimestamp is already converted to local in AnomalyItem.fromJson
        // (.toLocal() applied there); DateTime.now() is also local — safe to compare.
        _FilterPeriod.today => a.eventTimestamp.year == now.year &&
            a.eventTimestamp.month == now.month &&
            a.eventTimestamp.day == now.day,
        _FilterPeriod.week => a.eventTimestamp.isAfter(now.subtract(const Duration(days: 7))),
      };
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    _loadDismissed().then((_) => _load());
  }

  Future<void> _loadDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(_kDismissedKey) ?? [];
    final hasSynced = prefs.getBool('last_sync_success') ?? false;
    if (mounted) {
      setState(() {
        _dismissed = ids.toSet();
        _hasPreviouslySynced = hasSynced;
      });
    }
  }

  void _dismiss(String id) {
    // Immutable update: create a new Set instead of mutating in place.
    final updated = {..._dismissed, id};
    setState(() => _dismissed = updated);
    // Persist immediately so backgrounding the app doesn't lose the dismissal.
    _persistDismissedSet(Set<String>.from(updated));
    ScaffoldMessenger.of(context)
        .showSnackBar(
          SnackBar(
            content: const Text('Alert dismissed'),
            duration: const Duration(seconds: 4),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () {
                if (mounted) {
                  // Remove only this specific id — don't overwrite concurrent dismissals.
                  setState(() => _dismissed = Set<String>.from(_dismissed)..remove(id));
                  _persistDismissedSet(Set<String>.from(_dismissed));
                }
              },
            ),
          ),
        );
  }

  Future<void> _persistDismissedSet(Set<String> snapshot) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kDismissedKey, snapshot.toList());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final items = await HealthService.fetchAnomalies(limit: 50);
    if (mounted) setState(() { _anomalies = items; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    // Compute the filtered list ONCE per frame — avoids O(N) getter calls
    // inside the SliverList builder and ensures childCount matches the builder.
    final visible = _loading ? <AnomalyItem>[] : _computeVisible();

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
                      children: [
                        Text('Health Alerts', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700)),
                        SizedBox(height: 2),
                        Text('Anomalies detected by TikCare AI', style: TextStyle(color: Colors.white60, fontSize: 13)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh, color: Colors.white70),
                onPressed: _load,
              ),
            ],
          ),
          if (_loading)
            const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator(color: kNavy, strokeWidth: 2)),
            )
          else ...[
            // ── Filter chips ───────────────────────────────────────────────
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Row(
                  children: [
                    _FilterChip(label: 'All', selected: _filter == _FilterPeriod.all, onTap: () => setState(() => _filter = _FilterPeriod.all)),
                    const SizedBox(width: 8),
                    _FilterChip(label: 'Today', selected: _filter == _FilterPeriod.today, onTap: () => setState(() => _filter = _FilterPeriod.today)),
                    const SizedBox(width: 8),
                    _FilterChip(label: '7 Days', selected: _filter == _FilterPeriod.week, onTap: () => setState(() => _filter = _FilterPeriod.week)),
                  ],
                ),
              ),
            ),
            if (visible.isEmpty)
              SliverFillRemaining(
                child: Center(
                  child: _EmptyAlertsState(
                    filter: _filter,
                    hasAnyAnomalies: (_anomalies?.isNotEmpty ?? false),
                    hasPreviouslySynced: _hasPreviouslySynced,
                    onShowAll: () => setState(() => _filter = _FilterPeriod.all),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                sliver: SliverList(
                  // `visible` is captured once above — childCount and builder are consistent.
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      if (index == 0) return _SummaryRow(anomalies: visible);
                      final anomaly = visible[index - 1];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Dismissible(
                          key: ValueKey(anomaly.id),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 18),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade200,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Icon(Icons.check_circle_outline, color: Colors.grey, size: 24),
                          ),
                          onDismissed: (_) => _dismiss(anomaly.id),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => AnomalyDetailScreen(anomaly: anomaly),
                              ),
                            ),
                            child: _AnomalyCard(anomaly: anomaly),
                          ),
                        ),
                      );
                    },
                    childCount: visible.length + 1,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

// ── Context-aware empty state ──────────────────────────────────────────────────

class _EmptyAlertsState extends StatelessWidget {
  final _FilterPeriod filter;
  final bool hasAnyAnomalies;
  final bool hasPreviouslySynced;
  final VoidCallback onShowAll;
  const _EmptyAlertsState({
    required this.filter,
    required this.hasAnyAnomalies,
    required this.hasPreviouslySynced,
    required this.onShowAll,
  });

  @override
  Widget build(BuildContext context) {
    // True "all clear" — zero anomalies on record (none at all, or none returned
    // by the server). Having anomalies that are all dismissed is NOT "all clear":
    // those alerts exist, the user just acknowledged them.
    final isGenuineClear = !hasAnyAnomalies;

    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: (isGenuineClear && hasPreviouslySynced)
                  ? kGreen.withValues(alpha: 0.1)
                  : Colors.grey.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isGenuineClear
                  ? (hasPreviouslySynced ? Icons.check_circle_outline : Icons.sync)
                  : Icons.filter_list_off,
              color: (isGenuineClear && hasPreviouslySynced) ? kGreen : Colors.grey,
              size: 36,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            isGenuineClear ? 'All Clear' : 'No alerts in this period',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: isGenuineClear ? kNavy : Colors.grey.shade700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            isGenuineClear
                ? (hasPreviouslySynced
                    ? 'No health anomalies detected.\nYour metrics look great!'
                    : 'No alerts yet.\nSync your health data to get started.')
                : 'There are no alerts matching this filter.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey, fontSize: 14),
          ),
          const SizedBox(height: 12),
          if (isGenuineClear && !hasPreviouslySynced)
            const Text(
              'Sync your data on the Home tab\nto check for new alerts.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 12),
            )
          else if (isGenuineClear && hasPreviouslySynced)
            const Text(
              'Keep syncing daily to stay on top\nof your health.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 12),
            )
          else ...[
            // Filter is hiding results — offer to reset.
            TextButton.icon(
              onPressed: onShowAll,
              icon: const Icon(Icons.list_alt_outlined, size: 16),
              label: const Text('Show all alerts'),
              style: TextButton.styleFrom(foregroundColor: kNavy),
            ),
          ],
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final List<AnomalyItem> anomalies;
  const _SummaryRow({required this.anomalies});

  @override
  Widget build(BuildContext context) {
    int severe = 0, moderate = 0, mild = 0;
    for (final a in anomalies) {
      switch (a.severity) {
        case 'severe': severe++;
        case 'moderate': moderate++;
        case 'mild': mild++;
        default: break; // ignore unknown severities
      }
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          if (severe > 0) ...[_SeverityChip(count: severe, label: 'Severe', color: kRed), const SizedBox(width: 8)],
          if (moderate > 0) ...[_SeverityChip(count: moderate, label: 'Moderate', color: kOrange), const SizedBox(width: 8)],
          if (mild > 0) _SeverityChip(count: mild, label: 'Mild', color: kAmber),
          const Spacer(),
          Text('${anomalies.length} total', style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      ),
    );
  }
}

class _SeverityChip extends StatelessWidget {
  final int count;
  final String label;
  final Color color;
  const _SeverityChip({required this.count, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text('$count $label', style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w700)),
    );
  }
}

class _AnomalyCard extends StatelessWidget {
  final AnomalyItem anomaly;
  const _AnomalyCard({required this.anomaly});

  @override
  Widget build(BuildContext context) {
    final color = anomaly.severityColor;
    final dt = anomaly.eventTimestamp;
    final dateStr = '${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2))],
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(anomaly.metricIcon, size: 18, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(anomaly.metricLabel, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: kNavy)),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        anomaly.severityDisplay,
                        style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '${anomaly.value.toStringAsFixed(1)} ${anomaly.metricUnit}  ·  ${anomaly.zScore > 0 ? '↑ Higher' : anomaly.zScore < 0 ? '↓ Lower' : '⚠ Unusual'} than usual',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
                if (anomaly.explanation.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    anomaly.explanation,
                    style: const TextStyle(fontSize: 12, color: Colors.black87, height: 1.4),
                  ),
                ],
                const SizedBox(height: 4),
                Text(dateStr, style: const TextStyle(fontSize: 10, color: Colors.grey)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _FilterChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? kNavy : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? kNavy : Colors.grey.shade300),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : Colors.grey.shade600,
          ),
        ),
      ),
    );
  }
}
