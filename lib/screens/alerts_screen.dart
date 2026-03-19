import 'package:flutter/material.dart';
import '../services/health_service.dart';
import '../models/anomaly_item.dart';
import 'anomaly_detail_screen.dart';

const _navy = Color(0xFF1B3A6B);
const _navyLight = Color(0xFF2A5298);
const _green = Color(0xFF38A169);
const _amber = Color(0xFFD97706);
const _red = Color(0xFFE53E3E);
const _orange = Color(0xFFDD6B20);
const _bg = Color(0xFFF7F9FC);

class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  List<AnomalyItem>? _anomalies;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final items = await HealthService.fetchAnomalies(limit: 50);
    if (mounted) setState(() { _anomalies = items; _loading = false; });
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
              child: Center(child: CircularProgressIndicator(color: _navy, strokeWidth: 2)),
            )
          else if (_anomalies == null || _anomalies!.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: _green.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.check_circle_outline, color: _green, size: 36),
                    ),
                    const SizedBox(height: 16),
                    const Text('All Clear', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: _navy)),
                    const SizedBox(height: 6),
                    const Text(
                      'No health anomalies detected.\nYour metrics look great!',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 14),
                    ),
                  ],
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    if (index == 0) return _SummaryRow(anomalies: _anomalies!);
                    final anomaly = _anomalies![index - 1];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                AnomalyDetailScreen(anomaly: anomaly),
                          ),
                        ),
                        child: _AnomalyCard(anomaly: anomaly),
                      ),
                    );
                  },
                  childCount: _anomalies!.length + 1,
                ),
              ),
            ),
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
    final severe = anomalies.where((a) => a.severity == 'severe').length;
    final moderate = anomalies.where((a) => a.severity == 'moderate').length;
    final mild = anomalies.where((a) => a.severity == 'mild').length;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          if (severe > 0) ...[_SeverityChip(count: severe, label: 'Severe', color: _red), const SizedBox(width: 8)],
          if (moderate > 0) ...[_SeverityChip(count: moderate, label: 'Moderate', color: _orange), const SizedBox(width: 8)],
          if (mild > 0) _SeverityChip(count: mild, label: 'Mild', color: _amber),
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

  Color get _severityColor => switch (anomaly.severity) {
        'severe' => _red,
        'moderate' => _orange,
        _ => _amber,
      };

  IconData get _metricIcon => switch (anomaly.metricType) {
        'HR_INSTANT' || 'RHR_DAILY' => Icons.favorite,
        'HRV_SDNN' || 'HRV_RMSSD' => Icons.monitor_heart,
        'SPO2_INSTANT' => Icons.water_drop,
        'STEPS_DELTA' => Icons.directions_walk,
        'ENERGY_DELTA' => Icons.local_fire_department,
        'RESP_RATE' => Icons.air,
        _ => Icons.show_chart,
      };

  @override
  Widget build(BuildContext context) {
    final color = _severityColor;
    final dt = anomaly.eventTimestamp;
    final dateStr = '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

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
            child: Icon(_metricIcon, size: 18, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(anomaly.metricLabel, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: _navy)),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        anomaly.severity[0].toUpperCase() + anomaly.severity.substring(1),
                        style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '${anomaly.value.toStringAsFixed(1)} ${anomaly.metricUnit}  ·  z=${anomaly.zScore.toStringAsFixed(1)}σ',
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
