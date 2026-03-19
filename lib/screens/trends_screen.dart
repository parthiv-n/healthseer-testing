import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../services/health_service.dart';
import '../models/trend_point.dart';

const _navy = Color(0xFF1B3A6B);
const _navyLight = Color(0xFF2A5298);
const _green = Color(0xFF38A169);
const _amber = Color(0xFFD97706);
const _red = Color(0xFFE53E3E);
const _bg = Color(0xFFF7F9FC);

class TrendsScreen extends StatefulWidget {
  const TrendsScreen({super.key});

  @override
  State<TrendsScreen> createState() => _TrendsScreenState();
}

class _TrendsScreenState extends State<TrendsScreen> {
  int _selectedDays = 7;
  // -1 signals "custom" range mode
  static const _customDaysFlag = -1;

  DateTime? _customStart;
  DateTime? _customEnd;

  RangeReport? _report;
  bool _loading = true;
  String? _error;
  bool _fromCache = false;
  DateTime? _cachedAt;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; _fromCache = false; });

    RangeReport? report;
    if (_selectedDays == _customDaysFlag &&
        _customStart != null &&
        _customEnd != null) {
      report = await HealthService.fetchRangeReportByDates(
        start: _customStart!,
        end: _customEnd!,
      );
    } else {
      report = await HealthService.fetchRangeReport(days: _selectedDays);
      if (report != null) {
        final stale = await HealthService.isRangeReportCacheStale(
          days: _selectedDays,
        );
        final cachedAt = await HealthService.getRangeReportCachedAt(
          days: _selectedDays,
        );
        if (mounted) {
          setState(() {
            _fromCache = stale;
            _cachedAt = cachedAt;
          });
        }
      }
    }

    if (mounted) {
      setState(() {
        _report = report;
        _loading = false;
        if (report == null) {
          _error = 'Could not load trends. Sync data first.';
        }
      });
    }
  }

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now,
      initialDateRange: DateTimeRange(
        start: now.subtract(const Duration(days: 30)),
        end: now,
      ),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.light(
            primary: _navy,
            onPrimary: Colors.white,
            surface: Colors.white,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null && mounted) {
      setState(() {
        _selectedDays = _customDaysFlag;
        _customStart = picked.start;
        _customEnd = picked.end;
      });
      _load();
    }
  }

  String get _currentRangeLabel {
    if (_selectedDays == _customDaysFlag &&
        _customStart != null &&
        _customEnd != null) {
      final s = _customStart!;
      final e = _customEnd!;
      return '${s.month}/${s.day} – ${e.month}/${e.day}';
    }
    return '$_selectedDays Days';
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
                        Text('Health Trends', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700)),
                        SizedBox(height: 2),
                        Text('Your health over time', style: TextStyle(color: Colors.white60, fontSize: 13)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              child: Column(
                children: [
                  // Time range selector
                  _TimeRangeSelector(
                    selected: _selectedDays,
                    onChanged: (days) {
                      setState(() {
                        _selectedDays = days;
                        _customStart = null;
                        _customEnd = null;
                      });
                      _load();
                    },
                    onCustomTap: _pickCustomRange,
                    customLabel: _selectedDays == _customDaysFlag
                        ? _currentRangeLabel
                        : null,
                  ),
                  const SizedBox(height: 12),

                  // Cache banner for stale data
                  if (_fromCache && _cachedAt != null) ...[
                    _TrendsCacheBanner(cachedAt: _cachedAt!, onRefresh: _load),
                    const SizedBox(height: 12),
                  ],

                  if (_loading)
                    const _LoadingCard()
                  else if (_error != null)
                    _ErrorCard(error: _error!)
                  else if (_report != null && _report!.daysWithData == 0)
                    const _NoDataCard()
                  else if (_report != null)
                    _TrendsContent(
                      report: _report!,
                      days: _selectedDays == _customDaysFlag
                          ? _customEnd!
                              .difference(_customStart!)
                              .inDays
                              .abs() + 1
                          : _selectedDays,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TimeRangeSelector extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onChanged;
  final VoidCallback onCustomTap;
  /// When non-null, the custom button shows this label (the picked range).
  final String? customLabel;
  const _TimeRangeSelector({
    required this.selected,
    required this.onChanged,
    required this.onCustomTap,
    this.customLabel,
  });

  @override
  Widget build(BuildContext context) {
    const options = [(7, '7d'), (30, '30d'), (90, '90d')];
    final isCustom = selected == -1;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          ...options.map((o) {
            final isSelected = o.$1 == selected;
            return Expanded(
              child: GestureDetector(
                onTap: () => onChanged(o.$1),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: isSelected ? _navy : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    o.$2,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isSelected ? Colors.white : Colors.grey,
                    ),
                  ),
                ),
              ),
            );
          }),
          // Custom button
          Expanded(
            child: GestureDetector(
              onTap: onCustomTap,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                decoration: BoxDecoration(
                  color: isCustom ? _navy : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.date_range_outlined,
                      size: 12,
                      color: isCustom ? Colors.white : Colors.grey,
                    ),
                    const SizedBox(width: 3),
                    Flexible(
                      child: Text(
                        customLabel ?? 'Custom',
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isCustom ? Colors.white : Colors.grey,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TrendsContent extends StatelessWidget {
  final RangeReport report;
  final int days;
  const _TrendsContent({required this.report, required this.days});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Summary stats row
        Row(
          children: [
            Expanded(child: _StatCard(label: 'Avg HRI', value: report.avgHri.toStringAsFixed(1), subtitle: _hriLabel(report.avgHri), color: _hriColor(report.avgHri))),
            const SizedBox(width: 10),
            Expanded(child: _StatCard(label: 'Days w/ Data', value: '${report.daysWithData}', subtitle: 'of $days days', color: _navy)),
            const SizedBox(width: 10),
            Expanded(child: _StatCard(label: 'Anomalies', value: '${report.totalAnomalies}', subtitle: 'detected', color: report.totalAnomalies > 5 ? _amber : _green)),
          ],
        ),

        const SizedBox(height: 16),

        // HRI Trend Chart
        if (report.dailyTrend.isNotEmpty) ...[
          _ChartCard(
            title: 'Health Risk Index',
            subtitle: 'Daily HRI score (lower is better)',
            child: _HriLineChart(points: report.dailyTrend),
          ),
          const SizedBox(height: 16),
          // Coverage chart
          _ChartCard(
            title: 'Data Coverage',
            subtitle: 'How much health data was captured each day',
            child: _CoverageBarChart(points: report.dailyTrend),
          ),
        ] else
          _EmptyChart(),
      ],
    );
  }

  String _hriLabel(double hri) {
    if (hri < 25) return 'Low risk';
    if (hri < 50) return 'Moderate';
    if (hri < 75) return 'Elevated';
    return 'High risk';
  }

  Color _hriColor(double hri) {
    if (hri < 25) return _green;
    if (hri < 50) return _amber;
    return _red;
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final String subtitle;
  final Color color;
  const _StatCard({required this.label, required this.value, required this.subtitle, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.w500)),
          const SizedBox(height: 4),
          Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: color)),
          Text(subtitle, style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ],
      ),
    );
  }
}

class _ChartCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;
  const _ChartCard({required this.title, required this.subtitle, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _navy)),
          const SizedBox(height: 2),
          Text(subtitle, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

class _HriLineChart extends StatelessWidget {
  final List<TrendPoint> points;
  const _HriLineChart({required this.points});

  @override
  Widget build(BuildContext context) {
    final spots = points.asMap().entries.map((e) {
      return FlSpot(e.key.toDouble(), e.value.hri);
    }).toList();

    return SizedBox(
      height: 160,
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: 100,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: 25,
            getDrawingHorizontalLine: (_) => FlLine(color: Colors.grey.shade100, strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: 25,
                reservedSize: 28,
                getTitlesWidget: (v, _) => Text('${v.toInt()}', style: const TextStyle(fontSize: 9, color: Colors.grey)),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: (points.length / 4).ceilToDouble(),
                getTitlesWidget: (v, _) {
                  final i = v.toInt();
                  if (i < 0 || i >= points.length) return const SizedBox.shrink();
                  final d = points[i].date;
                  return Text('${d.month}/${d.day}', style: const TextStyle(fontSize: 9, color: Colors.grey));
                },
              ),
            ),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              curveSmoothness: 0.3,
              color: _navyLight,
              barWidth: 2.5,
              dotData: FlDotData(
                show: true,
                getDotPainter: (spot, _, __, ___) {
                  final color = spot.y < 25 ? _green : spot.y < 50 ? _amber : _red;
                  return FlDotCirclePainter(radius: 3.5, color: color, strokeWidth: 0);
                },
              ),
              belowBarData: BarAreaData(
                show: true,
                gradient: LinearGradient(
                  colors: [_navyLight.withValues(alpha: 0.15), _navyLight.withValues(alpha: 0.0)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CoverageBarChart extends StatelessWidget {
  final List<TrendPoint> points;
  const _CoverageBarChart({required this.points});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 100,
      child: BarChart(
        BarChartData(
          maxY: 1.0,
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          titlesData: const FlTitlesData(
            leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
            topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          barGroups: points.asMap().entries.map((e) {
            final coverage = e.value.coverageScore.clamp(0.0, 1.0);
            final color = coverage > 0.7 ? _green : coverage > 0.4 ? _amber : _red;
            return BarChartGroupData(x: e.key, barRods: [
              BarChartRodData(toY: coverage, color: color.withValues(alpha: 0.8), width: (280 / points.length).clamp(4.0, 20.0), borderRadius: BorderRadius.circular(3)),
            ]);
          }).toList(),
        ),
      ),
    );
  }
}

class _EmptyChart extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 120,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.show_chart, size: 32, color: Colors.grey),
          SizedBox(height: 8),
          Text('No trend data yet.\nSync health data to see your trends.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, fontSize: 13)),
        ],
      ),
    );
  }
}

String _relativeTime(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 2) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}

class _TrendsCacheBanner extends StatelessWidget {
  final DateTime cachedAt;
  final VoidCallback onRefresh;
  const _TrendsCacheBanner({required this.cachedAt, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onRefresh,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: Colors.amber.shade50,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.amber.shade300),
        ),
        child: Row(
          children: [
            Icon(Icons.cloud_off_outlined, size: 14, color: Colors.amber.shade700),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Showing cached data from ${_relativeTime(cachedAt)} — tap to refresh',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.amber.shade800,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Icon(Icons.refresh, size: 14, color: Colors.amber.shade600),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String error;
  const _ErrorCard({required this.error});

  @override
  Widget build(BuildContext context) {
    // Provide a more helpful message based on common error patterns
    final message = error.toLowerCase().contains('network') ||
            error.toLowerCase().contains('connection')
        ? 'Network error — check your connection and try again.'
        : error.toLowerCase().contains('sync') || error.toLowerCase().contains('no ')
            ? 'No trends data yet. Complete a sync first.'
            : error;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.show_chart, size: 28, color: Colors.orange.shade400),
          ),
          const SizedBox(height: 14),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 14,
              color: Colors.black54,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard();
  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 200,
      child: Center(child: CircularProgressIndicator(color: _navy, strokeWidth: 2)),
    );
  }
}

class _NoDataCard extends StatelessWidget {
  const _NoDataCard();
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: const Color(0xFFEEF2FF),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.show_chart, size: 30, color: _navy),
          ),
          const SizedBox(height: 16),
          const Text('No trend data yet', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _navy)),
          const SizedBox(height: 8),
          const Text(
            'Sync your Apple Watch or wearable data\nto see your health trends here.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Colors.grey, height: 1.5),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFEEF2FF),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.info_outline, size: 14, color: _navy),
                SizedBox(width: 6),
                Text('Go to Today tab → Sync to TikCare', style: TextStyle(fontSize: 12, color: _navy, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
