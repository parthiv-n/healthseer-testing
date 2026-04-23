import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../services/health_service.dart';
import '../models/trend_point.dart';
import '../models/daily_report.dart';
import '../utils/time_utils.dart';
import '../theme/colors.dart';

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
  List<DailyMetricPoint> _metricHistory = [];
  int? _localDays;

  @override
  void initState() {
    super.initState();
    _load();
    _loadMetricHistory();
  }

  Future<void> _loadMetricHistory() async {
    final days = _selectedDays == _customDaysFlag
        ? (_customEnd != null && _customStart != null
            ? _customEnd!.difference(_customStart!).inDays.abs() + 1
            : 7)
        : _selectedDays;
    final history = await HealthService.fetchMetricHistory(days: days);
    if (mounted) {
      setState(() {
        _metricHistory = history;
      });
    }
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; _fromCache = false; });
    _loadMetricHistory();

    final days = _selectedDays == _customDaysFlag
        ? (_customEnd != null && _customStart != null
            ? _customEnd!.difference(_customStart!).inDays.abs() + 1
            : 7)
        : _selectedDays;
    HealthService.fetchLocalDaysWithData(days: days).then((count) {
      if (mounted) setState(() => _localDays = count);
    });

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
        final cachedAt = await HealthService.getRangeReportCachedAt(
          days: _selectedDays,
        );
        if (mounted) {
          setState(() {
            // fromCache = true when the cache timestamp is > 30s old.
            // A network fetch always writes a fresh timestamp, so data
            // freshly fetched from the server will have cachedAt within
            // the last second. Data served from an existing cache will
            // have an older timestamp.
            _fromCache = cachedAt != null &&
                DateTime.now().difference(cachedAt).inSeconds > 30;
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
            primary: kNavy,
            onPrimary: Colors.white,
            surface: Colors.white,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null && mounted) {
      final days = picked.end.difference(picked.start).inDays;
      if (days > 365) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Date range capped at 365 days.'),
            duration: Duration(seconds: 3),
          ),
        );
        final capped = picked.start.add(const Duration(days: 365));
        setState(() {
          _selectedDays = _customDaysFlag;
          _customStart = picked.start;
          _customEnd = capped;
        });
      } else {
        setState(() {
          _selectedDays = _customDaysFlag;
          _customStart = picked.start;
          _customEnd = picked.end;
        });
      }
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
                      metricHistory: _metricHistory,
                      localDays: _localDays,
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
    final isCustom = selected == _TrendsScreenState._customDaysFlag;

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
                    color: isSelected ? kNavy : Colors.transparent,
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
                  color: isCustom ? kNavy : Colors.transparent,
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
  final List<DailyMetricPoint> metricHistory;
  final int? localDays;
  const _TrendsContent({required this.report, required this.days, required this.metricHistory, this.localDays});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Summary stats row
        Row(
          children: [
            Expanded(child: _StatCard(label: 'Avg HRI', value: report.avgHri.toStringAsFixed(1), subtitle: _hriLabel(report.avgHri), color: _hriColor(report.avgHri))),
            const SizedBox(width: 10),
            Expanded(child: _StatCard(label: 'Analyzed', value: '${report.daysWithData}', subtitle: localDays != null ? 'of $localDays in Health' : 'of $days days', color: kNavy)),
            const SizedBox(width: 10),
            Expanded(child: _StatCard(label: 'Anomalies', value: '${report.totalAnomalies}', subtitle: 'detected', color: report.totalAnomalies > 5 ? kAmber : kGreen)),
          ],
        ),

        // Gap banner: shown when Apple Health has more days than TikCare analyzed
        if (localDays != null && localDays! > report.daysWithData) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFEFF6FF),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFBFDBFE)),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline, size: 16, color: Color(0xFF3B82F6)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${localDays! - report.daysWithData} days in Apple Health haven\'t been analyzed yet. Go to Profile → Re-sync Historical Data to fill the gap.',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF1E40AF), height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ],

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

        // Per-metric charts section
        if (metricHistory.isNotEmpty && metricHistory.any((p) => p.hasAnyData)) ...[
          const SizedBox(height: 24),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('Metric Details', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: kNavy)),
          ),
          const SizedBox(height: 12),
          _MetricChartSection(points: metricHistory),
        ],
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
    if (hri < 26) return kGreen;
    if (hri < 51) return kAmber;
    if (hri < 76) return kOrange;
    return kRed;
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
          Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: kNavy)),
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
    if (points.length < 2) {
      return const SizedBox(
        height: 160,
        child: Center(
          child: Text('Not enough data to display trend', style: TextStyle(fontSize: 12, color: Colors.grey)),
        ),
      );
    }

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
              color: kNavyLight,
              barWidth: 2.5,
              dotData: FlDotData(
                show: true,
                getDotPainter: (spot, _, __, ___) {
                  final color = spot.y < 25 ? kGreen : spot.y < 50 ? kAmber : kRed;
                  return FlDotCirclePainter(radius: 3.5, color: color, strokeWidth: 0);
                },
              ),
              belowBarData: BarAreaData(
                show: true,
                gradient: LinearGradient(
                  colors: [kNavyLight.withValues(alpha: 0.15), kNavyLight.withValues(alpha: 0.0)],
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
            final color = coverage > 0.7 ? kGreen : coverage > 0.4 ? kAmber : kRed;
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

// relativeTime() moved to lib/utils/time_utils.dart (shared with home_screen)

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
                'Showing cached data from ${relativeTime(cachedAt)} — tap to refresh',
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
      child: Center(child: CircularProgressIndicator(color: kNavy, strokeWidth: 2)),
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
            child: const Icon(Icons.show_chart, size: 30, color: kNavy),
          ),
          const SizedBox(height: 16),
          const Text('No trend data yet', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: kNavy)),
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
                Icon(Icons.info_outline, size: 14, color: kNavy),
                SizedBox(width: 6),
                Text('Go to Today tab → Data Upload', style: TextStyle(fontSize: 12, color: kNavy, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Per-metric chart section ──────────────────────────────────────────────────

class _MetricChartSection extends StatefulWidget {
  final List<DailyMetricPoint> points;
  const _MetricChartSection({required this.points});

  @override
  State<_MetricChartSection> createState() => _MetricChartSectionState();
}

// Tab definition for metric charts.
typedef _TabDef = ({IconData icon, String label, Color color});

class _MetricChartSectionState extends State<_MetricChartSection> {
  int _tab = 0;

  static const List<_TabDef> _tabs = [
    (icon: Icons.favorite,               label: 'HR',       color: Colors.red),
    (icon: Icons.monitor_heart_outlined, label: 'HRV',      color: Colors.blue),
    (icon: Icons.directions_walk,        label: 'Steps',    color: kNavy),
    (icon: Icons.bedtime_outlined,       label: 'Sleep',    color: Colors.indigo),
    (icon: Icons.favorite_border,        label: 'RHR',      color: Colors.pink),
    (icon: Icons.water_drop_outlined,    label: 'SpO2',     color: Colors.cyan),
    (icon: Icons.fitness_center,         label: 'Exercise', color: Colors.green),
    (icon: Icons.air,                    label: 'Resp',     color: Colors.teal),
    (icon: Icons.electrical_services,   label: 'AFib',     color: Colors.orange),
  ];

  @override
  Widget build(BuildContext context) {
    final availability = [
      widget.points.any((p) => p.avgHr != null),
      widget.points.any((p) => p.hrv != null),
      widget.points.any((p) => p.steps != null),
      widget.points.any((p) => p.sleepHours != null),
      widget.points.any((p) => p.rhr != null),
      widget.points.any((p) => p.spo2 != null),
      widget.points.any((p) => p.exerciseMin != null),
      widget.points.any((p) => p.respRate != null),
      widget.points.any((p) => p.afibDetected != null),
    ];

    // Fall back to first available tab if current has no data.
    final effectiveTab = availability[_tab] ? _tab : availability.indexWhere((a) => a);
    if (effectiveTab < 0) return const SizedBox.shrink();

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Scrollable tab row — can exceed screen width with 9 tabs.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: List.generate(_tabs.length, (i) {
                  if (!availability[i]) return const SizedBox.shrink();
                  final tab = _tabs[i];
                  final selected = effectiveTab == i;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () => setState(() => _tab = i),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: selected ? tab.color.withValues(alpha: 0.12) : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(20),
                          border: selected ? Border.all(color: tab.color.withValues(alpha: 0.4)) : null,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(tab.icon, size: 13, color: selected ? tab.color : Colors.grey),
                            const SizedBox(width: 4),
                            Text(tab.label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: selected ? tab.color : Colors.grey)),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: switch (effectiveTab) {
              0 => _MetricLineChart(points: widget.points, getValue: (p) => p.avgHr,          color: Colors.red,    unit: 'bpm', label: 'Avg Heart Rate'),
              1 => _MetricLineChart(points: widget.points, getValue: (p) => p.hrv,            color: Colors.blue,   unit: 'ms',  label: 'HRV'),
              2 => _MetricBarChart( points: widget.points, getValue: (p) => p.steps?.toDouble(), color: kNavy,      unit: 'steps', label: 'Daily Steps'),
              3 => _MetricBarChart( points: widget.points, getValue: (p) => p.sleepHours,     color: Colors.indigo, unit: 'h',   label: 'Sleep'),
              4 => _MetricLineChart(points: widget.points, getValue: (p) => p.rhr,            color: Colors.pink,   unit: 'bpm', label: 'Resting Heart Rate'),
              5 => _MetricLineChart(points: widget.points, getValue: (p) => p.spo2,           color: Colors.cyan,   unit: '%',   label: 'Blood Oxygen (SpO2)'),
              6 => _MetricBarChart( points: widget.points, getValue: (p) => p.exerciseMin?.toDouble(), color: Colors.green, unit: 'min', label: 'Exercise Time'),
              7 => _MetricLineChart(points: widget.points, getValue: (p) => p.respRate,       color: Colors.teal,   unit: 'br/m', label: 'Respiratory Rate'),
              _ => _AfibBarChart(points: widget.points),
            },
          ),
        ],
      ),
    );
  }
}

// AFib: binary bar chart — red = detected, green = not detected, grey = no data.
class _AfibBarChart extends StatelessWidget {
  final List<DailyMetricPoint> points;
  const _AfibBarChart({required this.points});

  @override
  Widget build(BuildContext context) {
    final hasAny = points.any((p) => p.afibDetected != null);
    if (!hasAny) {
      return const SizedBox(height: 140, child: Center(child: Text('No AFib data\nRequires Apple Watch (iOS 16+)', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, fontSize: 12))));
    }
    return SizedBox(
      height: 140,
      child: BarChart(
        BarChartData(
          maxY: 1.2,
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: (points.length / 4).ceilToDouble().clamp(1, 30),
                getTitlesWidget: (val, _) {
                  final idx = val.toInt();
                  if (idx < 0 || idx >= points.length) return const SizedBox.shrink();
                  final d = points[idx].date;
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('${d.month}/${d.day}', style: const TextStyle(fontSize: 9, color: Colors.grey)),
                  );
                },
              ),
            ),
          ),
          barGroups: points.asMap().entries.map((e) {
            final afib = e.value.afibDetected;
            final color = afib == null
                ? Colors.grey.shade200
                : afib ? Colors.red.shade400 : Colors.green.shade400;
            return BarChartGroupData(
              x: e.key,
              barRods: [
                BarChartRodData(
                  toY: 1.0,
                  color: color,
                  width: (280.0 / points.length).clamp(4.0, 20.0),
                  borderRadius: BorderRadius.circular(3),
                ),
              ],
            );
          }).toList(),
        ),
      ),
    );
  }
}

class _MetricLineChart extends StatelessWidget {
  final List<DailyMetricPoint> points;
  final double? Function(DailyMetricPoint) getValue;
  final Color color;
  final String unit;
  final String label;

  const _MetricLineChart({
    required this.points,
    required this.getValue,
    required this.color,
    required this.unit,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final validPoints = points
        .asMap()
        .entries
        .where((e) => getValue(e.value) != null)
        .toList();

    if (validPoints.isEmpty) {
      return const SizedBox(height: 140, child: Center(child: Text('No data', style: TextStyle(color: Colors.grey))));
    }

    final vals = validPoints.map((e) => getValue(e.value)!).toList();
    final minVal = vals.reduce((a, b) => a < b ? a : b);
    final maxVal = vals.reduce((a, b) => a > b ? a : b);
    final padding = (maxVal - minVal) * 0.2 + 1;

    final spots = validPoints
        .map((e) => FlSpot(e.key.toDouble(), getValue(e.value)!))
        .toList();

    return SizedBox(
      height: 140,
      child: LineChart(
        LineChartData(
          minY: minVal - padding,
          maxY: maxVal + padding,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (_) => FlLine(color: Colors.grey.withValues(alpha: 0.15), strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 40,
                getTitlesWidget: (val, _) => Text(val.toStringAsFixed(0), style: const TextStyle(fontSize: 9, color: Colors.grey)),
              ),
            ),
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: (points.length / 4).ceilToDouble().clamp(1, 30),
                getTitlesWidget: (val, _) {
                  final idx = val.toInt();
                  if (idx < 0 || idx >= points.length) return const SizedBox.shrink();
                  final d = points[idx].date;
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('${d.month}/${d.day}', style: const TextStyle(fontSize: 9, color: Colors.grey)),
                  );
                },
              ),
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              curveSmoothness: 0.3,
              color: color,
              barWidth: 2.5,
              dotData: FlDotData(
                show: points.length <= 14,
                getDotPainter: (_, __, ___, ____) => FlDotCirclePainter(radius: 3, color: color, strokeWidth: 0),
              ),
              belowBarData: BarAreaData(
                show: true,
                color: color.withValues(alpha: 0.08),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricBarChart extends StatelessWidget {
  final List<DailyMetricPoint> points;
  final double? Function(DailyMetricPoint) getValue;
  final Color color;
  final String unit;
  final String label;

  const _MetricBarChart({
    required this.points,
    required this.getValue,
    required this.color,
    required this.unit,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final hasAny = points.any((p) => getValue(p) != null);
    if (!hasAny) {
      return const SizedBox(height: 140, child: Center(child: Text('No data', style: TextStyle(color: Colors.grey))));
    }

    final maxVal = points
        .where((p) => getValue(p) != null)
        .map((p) => getValue(p)!)
        .reduce((a, b) => a > b ? a : b);

    return SizedBox(
      height: 140,
      child: BarChart(
        BarChartData(
          maxY: maxVal * 1.2 + 1,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (_) => FlLine(color: Colors.grey.withValues(alpha: 0.15), strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 40,
                getTitlesWidget: (val, _) {
                  final s = val >= 1000
                      ? '${(val / 1000).toStringAsFixed(1)}k'
                      : val.toStringAsFixed(val < 10 ? 1 : 0);
                  return Text(s, style: const TextStyle(fontSize: 9, color: Colors.grey));
                },
              ),
            ),
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: (points.length / 4).ceilToDouble().clamp(1, 30),
                getTitlesWidget: (val, _) {
                  final idx = val.toInt();
                  if (idx < 0 || idx >= points.length) return const SizedBox.shrink();
                  final d = points[idx].date;
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('${d.month}/${d.day}', style: const TextStyle(fontSize: 9, color: Colors.grey)),
                  );
                },
              ),
            ),
          ),
          barGroups: points.asMap().entries.map((e) {
            final val = getValue(e.value) ?? 0;
            return BarChartGroupData(
              x: e.key,
              barRods: [
                BarChartRodData(
                  toY: val,
                  color: val > 0 ? color.withValues(alpha: 0.8) : Colors.transparent,
                  width: (280.0 / points.length).clamp(4.0, 20.0),
                  borderRadius: BorderRadius.circular(3),
                ),
              ],
            );
          }).toList(),
        ),
      ),
    );
  }
}
