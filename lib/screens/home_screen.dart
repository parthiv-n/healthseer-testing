import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/health_service.dart';
import '../models/health_snapshot.dart';
import '../models/risk_insight.dart';

// ── Cache banner helper ────────────────────────────────────────────────────────
String _relativeTime(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 2) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}

// ── Color palette ─────────────────────────────────────────────────────────────
const _navy = Color(0xFF1B3A6B);
const _navyLight = Color(0xFF2A5298);
const _green = Color(0xFF38A169);
const _amber = Color(0xFFD97706);
const _red = Color(0xFFE53E3E);
const _orange = Color(0xFFDD6B20);
const _bg = Color(0xFFF7F9FC);

class HomeScreen extends StatefulWidget {
  final SharedPreferences prefs;
  const HomeScreen({super.key, required this.prefs});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final List<_LogEntry> _logs = [];
  bool _syncing = false;
  bool? _apiOnline;
  bool _logsExpanded = false;

  // ── Local health snapshot ────────────────────────────────────────────────
  HealthSnapshot? _snapshot;
  bool _loadingSnapshot = true;

  // ── Cloud insights ───────────────────────────────────────────────────────
  RiskInsight? _insight;
  bool _loadingInsight = false;

  // ── Last sync summary (persisted) ────────────────────────────────────────
  String? _lastSyncTime;
  int? _lastEventCount;
  bool? _lastSyncSuccess;
  SyncErrorType? _lastSyncErrorType;

  // ── Offline cache state ───────────────────────────────────────────────────
  bool _insightFromCache = false;
  DateTime? _insightCachedAt;

  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
    _loadLastSync();
    _checkApi();
    _loadLocalSnapshot();
    _loadCachedInsight();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pulseCtrl.dispose();
    super.dispose();
  }

  /// Trigger a silent background sync whenever the app comes back to foreground,
  /// but only if it's been more than 30 minutes since the last sync.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_syncing) {
      _maybeSyncOnResume();
    }
  }

  Future<void> _maybeSyncOnResume() async {
    final prefs = await SharedPreferences.getInstance();
    final lastTime = prefs.getString('last_sync_time');
    final lastSuccess = prefs.getBool('last_sync_success') ?? false;
    // Only auto-sync if last sync was successful or never happened
    if (!lastSuccess && lastTime != null) return;

    // Check anchor timestamp to avoid syncing too frequently
    final anchor = prefs.getString('last_sync_anchor_ts');
    if (anchor != null) {
      final last = DateTime.tryParse(anchor);
      if (last != null && DateTime.now().difference(last).inMinutes < 30) return;
    }

    // Silent background sync — no UI disruption
    HealthService.syncDirect().then((result) async {
      if (result.success && mounted) {
        final prefs2 = await SharedPreferences.getInstance();
        await prefs2.setString('last_sync_anchor_ts', DateTime.now().toIso8601String());
        _loadCachedInsight();
      }
    });
  }

  Future<void> _loadLocalSnapshot() async {
    setState(() => _loadingSnapshot = true);
    final snapshot = await HealthService.fetchTodaySnapshot();
    if (mounted) setState(() { _snapshot = snapshot; _loadingSnapshot = false; });
  }

  Future<void> _loadCachedInsight() async {
    final cached = await HealthService.fetchRiskInsight();
    if (mounted && cached != null) {
      final now = DateTime.now();
      final isFromCache = now.difference(cached.fetchedAt).inSeconds > 30;
      setState(() {
        _insight = cached;
        _insightFromCache = isFromCache;
        _insightCachedAt = cached.fetchedAt;
      });
    }
  }

  Future<void> _loadLastSync() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _lastSyncTime = prefs.getString('last_sync_time');
      _lastEventCount = prefs.getInt('last_event_count');
      _lastSyncSuccess = prefs.getBool('last_sync_success');
    });
  }

  Future<void> _saveLastSync(bool success, int eventCount) async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final label =
        '${now.month}/${now.day} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    await prefs.setString('last_sync_time', label);
    await prefs.setInt('last_event_count', eventCount);
    await prefs.setBool('last_sync_success', success);
    setState(() {
      _lastSyncTime = label;
      _lastEventCount = eventCount;
      _lastSyncSuccess = success;
    });
  }

  Future<void> _checkApi() async {
    final result = await HealthService.pingLifePulse();
    if (mounted) {
      setState(() => _apiOnline = result.success);
      _addLog(result.success ? LogLevel.ok : LogLevel.error, result.message);
    }
  }

  void _addLog(LogLevel level, String msg) {
    final ts = TimeOfDay.now();
    final label =
        '${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}';
    setState(() {
      _logs.insert(0, _LogEntry(level: level, message: msg, time: label));
      if (_logs.length > 200) _logs.removeLast();
    });
  }

  Future<void> _runSync() async {
    if (_syncing) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _syncing = true;
      _logs.clear();
    });
    _addLog(LogLevel.info, 'Starting sync…');

    final result = await HealthService.syncDirect(
      onLog: (msg) => _addLog(LogLevel.info, msg),
    );

    final eventCount = (result.data?['events_received'] as int?) ?? 0;
    await _saveLastSync(result.success, eventCount);

    _addLog(result.success ? LogLevel.ok : LogLevel.error, result.message);

    if (mounted) {
      setState(() {
        _syncing = false;
        _logsExpanded = true;
        _lastSyncErrorType = result.errorType;
      });
      if (result.success) {
        HapticFeedback.heavyImpact();
        // Fetch cloud insights shortly after sync (pipeline needs a moment)
        await Future.delayed(const Duration(seconds: 2));
        _fetchInsightsAfterSync();
      }
    }
  }

  Future<void> _fetchInsightsAfterSync() async {
    if (!mounted) return;
    setState(() => _loadingInsight = true);
    final insight = await HealthService.fetchRiskInsight(
      onLog: (msg) => _addLog(LogLevel.info, msg),
    );
    if (mounted) {
      setState(() { _insight = insight; _loadingInsight = false; });
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: CustomScrollView(
        slivers: [
          _buildAppBar(context),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── Section 1: Your Health Today ──────────────────────────
                  _SectionHeader(title: 'Your Health Today', icon: Icons.favorite_border),
                  const SizedBox(height: 8),
                  _HealthTodayGrid(
                    snapshot: _snapshot,
                    loading: _loadingSnapshot,
                    onRefresh: _loadLocalSnapshot,
                  ),

                  const SizedBox(height: 20),

                  // ── Section 2: Risk Insights (cloud) ─────────────────────
                  _SectionHeader(
                    title: 'Risk Insights',
                    icon: Icons.shield_outlined,
                    subtitle: 'from TikCare',
                  ),
                  const SizedBox(height: 8),
                  // Cache banner
                  if (_insightFromCache && _insightCachedAt != null) ...[
                    _CacheBanner(
                      cachedAt: _insightCachedAt!,
                      onTap: _runSync,
                    ),
                    const SizedBox(height: 8),
                  ],
                  // Error banner (when no cached data either)
                  if (!_syncing && _insight == null && _lastSyncErrorType != null) ...[
                    _ErrorBanner(
                      errorType: _lastSyncErrorType!,
                      onSignIn: () => Navigator.pushNamedAndRemoveUntil(
                        context, '/login', (_) => false,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  _RiskInsightsCard(
                    insight: _insight,
                    loading: _loadingInsight,
                    apiOnline: _apiOnline,
                  ),

                  const SizedBox(height: 20),

                  // ── Section 3: Sync ───────────────────────────────────────
                  _SectionHeader(title: 'Sync to TikCare', icon: Icons.sync),
                  const SizedBox(height: 8),
                  _ConnectionBadge(apiOnline: _apiOnline, onRefresh: _checkApi),
                  const SizedBox(height: 8),
                  _SyncButton(
                    syncing: _syncing,
                    pulseAnim: _pulseAnim,
                    onTap: _runSync,
                  ),
                  const SizedBox(height: 8),
                  if (_lastSyncTime != null)
                    _LastSyncRow(
                      time: _lastSyncTime!,
                      eventCount: _lastEventCount,
                      success: _lastSyncSuccess ?? false,
                    ),
                  const SizedBox(height: 8),
                  const _WhatWeSyncChips(),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  SliverAppBar _buildAppBar(BuildContext context) {
    return SliverAppBar(
      expandedHeight: 110,
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
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.favorite, color: Colors.white, size: 20),
                  ),
                  const SizedBox(width: 10),
                  const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'TikCare LifePulse',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                        ),
                      ),
                      Text(
                        'Health Intelligence',
                        style: TextStyle(color: Colors.white60, fontSize: 13),
                      ),
                    ],
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.settings_outlined, color: Colors.white70),
                    onPressed: () async {
                      await Navigator.pushNamed(context, '/config');
                      _checkApi();
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Section Header ────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  final IconData icon;
  final String? subtitle;
  const _SectionHeader({required this.title, required this.icon, this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 15, color: _navy),
        const SizedBox(width: 6),
        Text(
          title,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: _navy,
            letterSpacing: 0.2,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(width: 4),
          Text(
            subtitle!,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ],
    );
  }
}

// ── Health Today Grid ─────────────────────────────────────────────────────────

class _HealthTodayGrid extends StatelessWidget {
  final HealthSnapshot? snapshot;
  final bool loading;
  final VoidCallback onRefresh;
  const _HealthTodayGrid({this.snapshot, required this.loading, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return _Card(
        child: const Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text('Reading HealthKit…', style: TextStyle(color: Colors.grey, fontSize: 13)),
          ),
        ),
      );
    }

    final s = snapshot;
    if (s == null || !s.hasData) {
      return _Card(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Row(
            children: [
              const Icon(Icons.watch_outlined, size: 16, color: Colors.grey),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'No health data yet today.\nWear your device and check back later.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
              GestureDetector(
                onTap: onRefresh,
                child: const Icon(Icons.refresh, size: 18, color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    return _Card(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: _MetricTile(label: 'Avg HR', value: s.avgHr != null ? '${s.avgHr!.toInt()} bpm' : '—', icon: Icons.favorite, iconColor: Colors.red.shade400)),
              const SizedBox(width: 8),
              Expanded(child: _MetricTile(label: 'Steps', value: s.steps != null ? _formatSteps(s.steps!) : '—', icon: Icons.directions_walk, iconColor: _navy)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _MetricTile(label: 'Sleep', value: s.sleepHours != null ? '${s.sleepHours!.toStringAsFixed(1)}h' : '—', icon: Icons.bedtime_outlined, iconColor: Colors.indigo.shade400)),
              const SizedBox(width: 8),
              Expanded(child: _MetricTile(label: 'HRV', value: s.hrv != null ? '${s.hrv!.toInt()} ms' : '—', icon: Icons.monitor_heart_outlined, iconColor: Colors.blue.shade400)),
            ],
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              onTap: onRefresh,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.refresh, size: 12, color: Colors.grey.shade400),
                  const SizedBox(width: 2),
                  Text(
                    'Live from HealthKit',
                    style: TextStyle(fontSize: 10, color: Colors.grey.shade400),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatSteps(int steps) {
    if (steps >= 1000) return '${(steps / 1000).toStringAsFixed(1)}k';
    return '$steps';
  }
}

class _MetricTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color iconColor;
  const _MetricTile({required this.label, required this.value, required this.icon, this.iconColor = _navy});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F4FF),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: iconColor),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: _navy),
          ),
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        ],
      ),
    );
  }
}

// ── Risk Insights Card ────────────────────────────────────────────────────────

class _RiskInsightsCard extends StatelessWidget {
  final RiskInsight? insight;
  final bool loading;
  final bool? apiOnline;
  const _RiskInsightsCard({this.insight, required this.loading, this.apiOnline});

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return _Card(
        child: const Padding(
          padding: EdgeInsets.all(8),
          child: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: _navy),
              ),
              SizedBox(width: 10),
              Text('Fetching insights…', style: TextStyle(fontSize: 13, color: Colors.grey)),
            ],
          ),
        ),
      );
    }

    if (insight == null) {
      return _Card(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'HRI  —',
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.grey),
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Sync your data to receive\npersonalized risk insights.',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                ],
              ),
              if (apiOnline == false) ...[
                const SizedBox(height: 8),
                _AlertBanner(
                  color: Colors.orange,
                  icon: Icons.cloud_off_outlined,
                  message: 'LifePulse API unreachable — configure server URL in Settings.',
                ),
              ],
            ],
          ),
        ),
      );
    }

    final s = insight!;
    final hriColor = _hriColor(s.hriLabel, score: s.hriScore);

    return Column(
      children: [
        // HRI card
        _Card(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              // HRI score circle
              Container(
                width: 66,
                height: 66,
                decoration: BoxDecoration(
                  color: hriColor.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                  border: Border.all(color: hriColor, width: 2),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      s.hriScore > 0 ? '${s.hriScore}' : '--',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: hriColor,
                      ),
                    ),
                    Text(
                      'HRI',
                      style: TextStyle(fontSize: 10, color: hriColor),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Health Risk Index',
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _hriDescription(s.hriLabel, score: s.hriScore),
                      style: TextStyle(fontSize: 12, color: hriColor, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Updated ${_timeAgo(s.fetchedAt)}',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                    if (s.fraudRiskScore != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Fraud signal: ${s.fraudRiskLabel}',
                        style: TextStyle(
                          fontSize: 11,
                          color: s.fraudRiskLabel == 'High' ? _red : Colors.grey,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),

        // Anomaly breakdown row
        if (s.anomalyBreakdown.values.any((v) => v > 0)) ...[
          const SizedBox(height: 6),
          _Card(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                const Text('Anomalies:', style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(width: 8),
                if ((s.anomalyBreakdown['severe'] ?? 0) > 0)
                  _AnomalyBadge(count: s.anomalyBreakdown['severe']!, label: 'severe', color: _red),
                if ((s.anomalyBreakdown['moderate'] ?? 0) > 0) ...[
                  const SizedBox(width: 4),
                  _AnomalyBadge(count: s.anomalyBreakdown['moderate']!, label: 'moderate', color: _orange),
                ],
                if ((s.anomalyBreakdown['mild'] ?? 0) > 0) ...[
                  const SizedBox(width: 4),
                  _AnomalyBadge(count: s.anomalyBreakdown['mild']!, label: 'mild', color: _amber),
                ],
              ],
            ),
          ),
        ],

        // Alert banners for recent anomalies
        ...s.latestAnomalies.take(2).map((a) {
          final sev = a['severity'] as String? ?? 'mild';
          final metric = a['metric_type'] as String? ?? '';
          final explanation = a['explanation'] as String? ?? '';
          final color = sev == 'severe' ? _red : _orange;
          return Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _AlertBanner(
              color: color,
              icon: Icons.warning_amber_rounded,
              message: explanation.isNotEmpty
                  ? explanation
                  : '${_formatMetric(metric)} anomaly detected ($sev)',
            ),
          );
        }),
      ],
    );
  }

  Color _hriColor(String label, {int score = 1}) {
    if (score == 0) return Colors.grey;
    return switch (label) {
      'critical' => _red,
      'high' => _orange,
      'moderate' => _amber,
      _ => _green,
    };
  }

  String _hriDescription(String label, {int score = 1}) {
    if (score == 0) return 'Awaiting sufficient health data';
    return switch (label) {
      'critical' => 'Critical — immediate review recommended',
      'high' => 'Elevated — monitor closely',
      'moderate' => 'Moderate — some anomalies detected',
      _ => 'Low — within normal range',
    };
  }

  String _formatMetric(String m) {
    return switch (m) {
      'HR_INSTANT' => 'Heart rate',
      'HRV_SDNN' => 'HRV',
      'SPO2_INSTANT' => 'Blood oxygen',
      'HR_RESTING' => 'Resting HR',
      'STEPS_DELTA' => 'Steps',
      _ => m,
    };
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 2) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

class _AnomalyBadge extends StatelessWidget {
  final int count;
  final String label;
  final Color color;
  const _AnomalyBadge({required this.count, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        '$count $label',
        style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _AlertBanner extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String message;
  const _AlertBanner({required this.color, required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Connection Badge ──────────────────────────────────────────────────────────

class _ConnectionBadge extends StatelessWidget {
  final bool? apiOnline;
  final VoidCallback onRefresh;
  const _ConnectionBadge({required this.apiOnline, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final isOnline = apiOnline == true;
    final isChecking = apiOnline == null;
    final color = isChecking ? _amber : (isOnline ? _green : _red);
    final label = isChecking
        ? 'Checking server…'
        : isOnline
            ? 'LifePulse API connected'
            : 'Cannot reach server — check Config';

    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ),
        GestureDetector(
          onTap: onRefresh,
          child: const Icon(Icons.refresh, size: 16, color: Colors.grey),
        ),
      ],
    );
  }
}

// ── Last Sync Row ─────────────────────────────────────────────────────────────

class _LastSyncRow extends StatelessWidget {
  final String time;
  final int? eventCount;
  final bool success;
  const _LastSyncRow({required this.time, this.eventCount, required this.success});

  @override
  Widget build(BuildContext context) {
    final color = success ? _green : _red;
    final label = success
        ? 'Last sync: $time${eventCount != null ? ' · $eventCount events' : ''}'
        : 'Last sync failed: $time';
    return Row(
      children: [
        Icon(
          success ? Icons.check_circle_outline : Icons.error_outline,
          size: 14,
          color: color,
        ),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(fontSize: 12, color: color)),
      ],
    );
  }
}

// ── Sync Button ───────────────────────────────────────────────────────────────

class _SyncButton extends StatelessWidget {
  final bool syncing;
  final Animation<double> pulseAnim;
  final VoidCallback onTap;
  const _SyncButton({required this.syncing, required this.pulseAnim, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: syncing ? pulseAnim : const AlwaysStoppedAnimation(1.0),
      child: GestureDetector(
        onTap: syncing ? null : onTap,
        child: Container(
          height: 54,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [_navy, _navyLight],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: _navy.withValues(alpha: 0.25),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (syncing)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              else
                const Icon(Icons.sync, color: Colors.white, size: 20),
              const SizedBox(width: 10),
              Text(
                syncing ? 'Syncing…' : 'Sync to TikCare',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── What We Sync Chips ────────────────────────────────────────────────────────

class _WhatWeSyncChips extends StatelessWidget {
  static const _metrics = [
    (Icons.favorite, 'Heart Rate'),
    (Icons.monitor_heart, 'HRV'),
    (Icons.directions_walk, 'Steps'),
    (Icons.water_drop, 'Blood O₂'),
    (Icons.local_fire_department, 'Active Energy'),
    (Icons.bedtime_outlined, 'Resting HR'),
    (Icons.route_outlined, 'Distance'),
    (Icons.stairs, 'Floors Climbed'),
    (Icons.timer_outlined, 'Exercise Time'),
    (Icons.bolt, 'Basal Energy'),
    (Icons.bedtime, 'Sleep'),
    (Icons.air, 'Resp. Rate*'),
  ];

  const _WhatWeSyncChips();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: _metrics.map((m) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFFEEF2FF),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(m.$1, size: 12, color: _navy),
                const SizedBox(width: 4),
                Text(
                  m.$2,
                  style: const TextStyle(fontSize: 11, color: _navy, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          )).toList(),
        ),
        const SizedBox(height: 4),
        const Text(
          '* Respiratory Rate requires Apple Watch Series 6 or later.',
          style: TextStyle(fontSize: 10, color: Colors.grey),
        ),
      ],
    );
  }
}

// ── Log Section ───────────────────────────────────────────────────────────────

class _LogSection extends StatelessWidget {
  final List<_LogEntry> logs;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onClear;
  const _LogSection({
    required this.logs,
    required this.expanded,
    required this.onToggle,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return _Card(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  const Icon(Icons.terminal, size: 14, color: Colors.grey),
                  const SizedBox(width: 6),
                  const Text(
                    'Sync Log',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.grey),
                  ),
                  if (logs.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${logs.length}',
                        style: const TextStyle(fontSize: 10, color: Colors.grey),
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (expanded && logs.isNotEmpty)
                    GestureDetector(
                      onTap: onClear,
                      child: const Text('Clear', style: TextStyle(fontSize: 11, color: Colors.grey)),
                    ),
                  const SizedBox(width: 6),
                  Icon(
                    expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                    size: 16,
                    color: Colors.grey,
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Container(
              height: logs.isEmpty ? 50 : (logs.length * 22.0).clamp(70.0, 200.0),
              decoration: const BoxDecoration(
                color: Color(0xFF1A1A2E),
                borderRadius: BorderRadius.vertical(bottom: Radius.circular(14)),
              ),
              child: logs.isEmpty
                  ? const Center(
                      child: Text(
                        'Tap "Sync to TikCare" to start',
                        style: TextStyle(color: Colors.white38, fontSize: 11),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      itemCount: logs.length,
                      itemBuilder: (_, i) => _LogLine(entry: logs[i]),
                    ),
            ),
        ],
      ),
    );
  }
}

// ── Shared Widgets ────────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  final Widget child;
  final EdgeInsets? padding;
  const _Card({required this.child, this.padding});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding ?? const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }
}

enum LogLevel { info, ok, error }

class _LogEntry {
  final LogLevel level;
  final String message;
  final String time;
  _LogEntry({required this.level, required this.message, required this.time});
}

class _LogLine extends StatelessWidget {
  final _LogEntry entry;
  const _LogLine({required this.entry});

  @override
  Widget build(BuildContext context) {
    final color = switch (entry.level) {
      LogLevel.ok => const Color(0xFF68D391),
      LogLevel.error => const Color(0xFFFC8181),
      LogLevel.info => const Color(0xFF90CDF4),
    };
    final prefix = switch (entry.level) {
      LogLevel.ok => '✓',
      LogLevel.error => '✗',
      LogLevel.info => '›',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            entry.time,
            style: const TextStyle(fontSize: 9, color: Colors.white30, fontFamily: 'monospace'),
          ),
          const SizedBox(width: 5),
          Text('$prefix ', style: TextStyle(fontSize: 11, color: color, fontFamily: 'monospace')),
          Expanded(
            child: Text(
              entry.message,
              style: TextStyle(fontSize: 10, color: color, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Cache Banner ───────────────────────────────────────────────────────────────

class _CacheBanner extends StatelessWidget {
  final DateTime cachedAt;
  final VoidCallback onTap;
  const _CacheBanner({required this.cachedAt, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: Colors.amber.shade50,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.amber.shade300),
        ),
        child: Row(
          children: [
            Icon(Icons.cloud_off_outlined, size: 15, color: Colors.amber.shade700),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Showing cached data from ${_relativeTime(cachedAt)} — tap to sync',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.amber.shade800,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Icon(Icons.chevron_right, size: 16, color: Colors.amber.shade600),
          ],
        ),
      ),
    );
  }
}

// ── Error Banner ───────────────────────────────────────────────────────────────

class _ErrorBanner extends StatelessWidget {
  final SyncErrorType errorType;
  final VoidCallback onSignIn;
  const _ErrorBanner({required this.errorType, required this.onSignIn});

  @override
  Widget build(BuildContext context) {
    final (msg, icon, color) = switch (errorType) {
      SyncErrorType.network => (
          'No connection. Showing last saved data.',
          Icons.wifi_off_outlined,
          Colors.orange,
        ),
      SyncErrorType.serverError => (
          'Server error. Try again later.',
          Icons.cloud_off_outlined,
          Colors.orange,
        ),
      SyncErrorType.authExpired => (
          'Session expired. Please sign in again.',
          Icons.lock_outline,
          Colors.red,
        ),
      SyncErrorType.noData => (
          'No data available for this period.',
          Icons.inbox_outlined,
          Colors.grey,
        ),
      _ => (
          'An error occurred. Try syncing again.',
          Icons.error_outline,
          Colors.orange,
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              msg,
              style: TextStyle(
                fontSize: 12,
                color: color,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          if (errorType == SyncErrorType.authExpired)
            GestureDetector(
              onTap: onSignIn,
              child: Text(
                'Sign in',
                style: TextStyle(
                  fontSize: 12,
                  color: color,
                  fontWeight: FontWeight.w700,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
