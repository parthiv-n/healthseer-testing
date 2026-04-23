import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/health_service.dart';
import '../models/health_snapshot.dart';
import '../models/risk_insight.dart';
import '../utils/time_utils.dart';
import '../theme/colors.dart';

class HomeScreen extends StatefulWidget {
  final SharedPreferences prefs;
  const HomeScreen({super.key, required this.prefs});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  bool _syncing = false;
  String? _syncStatusMsg;
  bool? _apiOnline;

  // ── Local health snapshot ────────────────────────────────────────────────
  HealthSnapshot? _snapshot;
  bool _loadingSnapshot = true;

  // ── Cloud insights ───────────────────────────────────────────────────────
  RiskInsight? _insight;
  bool _loadingInsight = false;
  // True after all retry attempts are exhausted with no result.
  // Distinguishes a real fetch failure from a normal cold-start wait.
  bool _insightFetchFailed = false;

  // ── Last sync summary (persisted) ────────────────────────────────────────
  String? _lastSyncTime;
  int? _lastEventCount;
  bool? _lastSyncSuccess;
  SyncErrorType? _lastSyncErrorType;
  List<String> _lastSyncDevices = [];
  DateTime? _lastSyncAt; // machine-readable, for stale-data check

  // ── Offline cache state ───────────────────────────────────────────────────
  bool _insightFromCache = false;
  DateTime? _insightCachedAt;

  // ── Returning user detection ─────────────────────────────────────────────
  // True when the server already has data for this account but _lastSyncTime
  // is null (new device / fresh install for an existing user).
  bool _isReturningUser = false;

  // True when a sync just detected a new device not seen in previous syncs.
  // Triggers a calibration notice ("system needs ~14 days to learn new device").
  bool _newDeviceDetected = false;

  // ── Detected wearable brand (for dynamic metric hints) ──────────────────
  String? _deviceBrand;

  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    // Start stopped — only repeat while _syncing == true to avoid
    // a permanently ticking AnimationController wasting CPU/battery.
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
      value: 1.0,
    );
    _pulseAnim = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
    // Load sync history and cached insight together so _isReturningUser is
    // guaranteed to be set before the auto-sync decision fires.
    Future.wait([_loadLastSync(), _loadCachedInsight()]).then((_) {
      // Auto-trigger sync only for brand-new users (no local sync history).
      // Returning users on a new device will see the "Reconnect" banner and
      // choose when to re-link — we don't force an immediate permission dialog.
      if (mounted && _lastSyncTime == null && !_isReturningUser) {
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted && _lastSyncTime == null && !_isReturningUser) {
            _runSync();
          }
        });
      }
    });
    _checkApi();
    _loadLocalSnapshot();
    _detectDevice();
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
  DateTime? _lastPermissionRetry;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_syncing) {
      // If returning from Health app after a permission error, retry sync
      // so the flow is seamless: user toggles permission, switches back,
      // data syncs automatically. Debounce to once per 10 seconds to avoid
      // rapid re-syncs when the user switches between apps quickly.
      if (_lastSyncErrorType == SyncErrorType.permissionDenied) {
        final now = DateTime.now();
        if (_lastPermissionRetry == null ||
            now.difference(_lastPermissionRetry!).inSeconds >= 10) {
          _lastPermissionRetry = now;
          _runSync();
        }
      } else {
        _maybeSyncOnResume();
      }
    }
  }

  Future<void> _maybeSyncOnResume() async {
    // Skip if manual sync is already running.
    if (_syncing) return;

    final prefs = await SharedPreferences.getInstance();
    final lastSuccess = prefs.getBool('last_sync_success') ?? false;
    final lastTime = prefs.getString('last_sync_time');
    // Only auto-sync if last sync was successful or has never happened.
    if (!lastSuccess && lastTime != null) return;

    // Use last_sync_iso (wall-clock time of last sync) to throttle resume syncs
    // to once per 30 minutes. last_sync_anchor is the health-event timestamp, not
    // the sync time — using it causes the throttle to fire based on data age, not
    // elapsed time since sync.
    final lastSyncIso = prefs.getString('last_sync_iso');
    if (lastSyncIso != null) {
      final last = DateTime.tryParse(lastSyncIso);
      if (last != null && DateTime.now().difference(last).inMinutes < 30) return;
    }

    // Capture the current devices list before the async gap so the .then()
    // closure doesn't reference the instance field after potential disposal.
    final knownDevices = List<String>.from(_lastSyncDevices);

    // Silent sync — no spinner, no UI disruption.
    try {
      final result = await HealthService.syncDirect();
      if (!mounted) return;
      if (result.success) {
        final eventCount = (result.data?['events_received'] as int?) ?? 0;
        final isUpToDate = result.errorType == SyncErrorType.noData;
        final devices = isUpToDate
            ? knownDevices
            : (result.data?['source_devices'] as List?)?.cast<String>() ?? [];
        await _saveLastSync(true, eventCount, null, devices);
        if (mounted) {
          _loadLocalSnapshot();
          _loadCachedInsight();
        }
      } else {
        await _saveLastSync(false, 0, result.errorType, knownDevices);
      }
    } catch (e) {
      debugPrint('[HomeScreen._maybeSyncOnResume] $e');
      if (mounted) {
        await _saveLastSync(false, 0, SyncErrorType.unknown, knownDevices);
      }
    }
  }

  Future<void> _detectDevice() async {
    final brand = await HealthService.detectDeviceBrand();
    if (mounted && brand != _deviceBrand) {
      setState(() => _deviceBrand = brand);
    }
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
        // Server has real data for this account but we've never synced from
        // this device — flag as returning user to show appropriate UX.
        if (_lastSyncTime == null && cached.hriScore > 0) {
          _isReturningUser = true;
        }
      });
    }
  }

  Future<void> _loadLastSync() async {
    final prefs = await SharedPreferences.getInstance();
    final errorName = prefs.getString('last_sync_error_type');
    final errorType = errorName != null
        ? SyncErrorType.values.where((e) => e.name == errorName).firstOrNull
        : null;
    final rawDevices = prefs.getStringList('last_sync_devices') ?? [];
    final newDevice = prefs.getBool('new_device_detected') ?? false;
    final rawIso = prefs.getString('last_sync_iso');
    setState(() {
      _lastSyncTime = prefs.getString('last_sync_time');
      _lastSyncAt = rawIso != null ? DateTime.tryParse(rawIso) : null;
      _lastEventCount = prefs.getInt('last_event_count');
      _lastSyncSuccess = prefs.getBool('last_sync_success');
      _lastSyncErrorType = errorType;
      _lastSyncDevices = rawDevices;
      _newDeviceDetected = newDevice;
    });
  }

  Future<void> _saveLastSync(
    bool success,
    int eventCount,
    SyncErrorType? errorType,
    List<String> devices,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final label =
        '${now.month}/${now.day} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    // Detect if a brand-new device appeared that wasn't in the previous sync.
    final previousDevices = prefs.getStringList('last_sync_devices') ?? [];
    final newDeviceFound = success &&
        previousDevices.isNotEmpty &&
        devices.any((d) => !previousDevices.contains(d));

    await prefs.setString('last_sync_time', label);
    await prefs.setString('last_sync_iso', now.toIso8601String());
    await prefs.setInt('last_event_count', eventCount);
    await prefs.setBool('last_sync_success', success);
    await prefs.setStringList('last_sync_devices', devices);
    await prefs.setBool('new_device_detected', newDeviceFound);
    if (errorType != null) {
      await prefs.setString('last_sync_error_type', errorType.name);
    } else {
      await prefs.remove('last_sync_error_type');
    }
    // Guard: the widget may have been disposed during the prefs awaits above
    // (e.g. user navigates to login mid-sync). Without this check setState
    // throws on a deactivated widget.
    if (!mounted) return;
    setState(() {
      _lastSyncTime = label;
      _lastSyncAt = now;
      _lastEventCount = eventCount;
      _lastSyncSuccess = success;
      _lastSyncErrorType = errorType;
      _lastSyncDevices = devices;
      _newDeviceDetected = newDeviceFound;
    });
  }

  Future<void> _checkApi() async {
    final result = await HealthService.pingLifePulse();
    if (mounted) {
      setState(() => _apiOnline = result.success);
    }
  }

  Future<void> _runSync() async {
    if (_syncing) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _syncing = true;
      _syncStatusMsg = null;
    });
    _pulseCtrl.repeat(reverse: true);

    try {
      final result = await HealthService.syncDirect(
        onLog: (msg) {
          // Surface upload batch progress to the UI
          if (mounted && msg.startsWith('Uploading')) {
            setState(() => _syncStatusMsg = msg);
          }
        },
      );

      final eventCount = (result.data?['events_received'] as int?) ?? 0;
      // Preserve known devices when noData — no events transferred means no source
      // device info available, not that the user has no devices.
      final isUpToDate = result.errorType == SyncErrorType.noData;
      final devices = (result.success && isUpToDate)
          ? _lastSyncDevices
          : (result.data?['source_devices'] as List?)?.cast<String>() ?? [];
      await _saveLastSync(result.success, eventCount, result.errorType, devices);

      if (mounted) {
        // Auth expiry during sync — fire sessionExpired so all screens redirect to login.
        if (result.errorType == SyncErrorType.authExpired) {
          HealthService.sessionExpired.value = true;
          return;
        }
        if (result.success) {
          HapticFeedback.heavyImpact();
          // A successful sync proves the API is reachable — clear the unreachable banner
          // immediately rather than waiting for the next _checkApi() probe.
          setState(() => _apiOnline = true);
          // Refresh the local snapshot and device brand so hints update.
          _loadLocalSnapshot();
          _detectDevice();
          // Fire insight fetch as a separate task so the sync button is
          // released immediately — _fetchInsightsWithRetry() manages its
          // own loading state and runs independently of _syncing.
          _fetchInsightsWithRetry();
        }
      }
    } catch (e) {
      debugPrint('[HomeScreen._runSync] unexpected error: $e');
      // Best-effort persist: don't await so a secondary failure can't compound.
      _saveLastSync(false, 0, SyncErrorType.unknown, _lastSyncDevices);
    } finally {
      // Always stop animation and clear syncing flag — even if an exception occurred.
      // No else needed — a disposed AnimationController stops automatically.
      if (mounted) {
        _pulseCtrl.stop();
        _pulseCtrl.value = 1.0;
        setState(() {
          _syncing = false;
          _syncStatusMsg = null;
        });
      }
    }
  }

  /// Fetches risk insights after a sync with exponential backoff.
  ///
  /// Runs independently of [_runSync] so the sync button is released
  /// immediately. Keeps [_loadingInsight] true for the entire duration so
  /// the HRI card shows a stable "Fetching insights…" spinner rather than
  /// flickering between spinner and "waiting" message between retries.
  ///
  /// Retry schedule: 3 s → 10 s → 20 s (33 s total, each attempt has its
  /// own 30 s HTTP timeout, worst-case ~63 s before giving up).
  Future<void> _fetchInsightsWithRetry() async {
    if (!mounted) return;
    setState(() => _loadingInsight = true);
    const retryDelays = [3, 10, 20];
    try {
      for (final delaySec in retryDelays) {
        await Future.delayed(Duration(seconds: delaySec));
        if (!mounted) return;
        final insight = await HealthService.fetchRiskInsight();
        if (!mounted) return;
        if (insight != null) {
          setState(() {
            _insight = insight;
            _apiOnline = true;
            _insightFetchFailed = false;
          });
          return; // success — stop
        }
      }
      // All attempts exhausted — mark as failed so the UI can distinguish
      // this state from a normal first-sync wait.
      if (mounted) setState(() => _insightFetchFailed = true);
      HealthService.reportClientError(
        'hri_fetch_failed',
        context: 'all retries exhausted',
        retryCount: retryDelays.length,
      );
    } catch (e) {
      debugPrint('[HomeScreen._fetchInsightsWithRetry] $e');
      if (mounted) setState(() => _insightFetchFailed = true);
      HealthService.reportClientError(
        'hri_fetch_exception',
        context: e.runtimeType.toString(),
        retryCount: retryDelays.length,
      );
    } finally {
      if (mounted) setState(() => _loadingInsight = false);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // iPhone-only flag: has steps/sleep data but no HR/HRV (no Apple Watch).
    final isIphoneOnly = !_loadingSnapshot &&
        _lastSyncTime != null &&
        _snapshot != null &&
        _snapshot!.avgHr == null &&
        _snapshot!.hrv == null &&
        (_snapshot!.steps != null || _snapshot!.sleepHours != null);

    return Scaffold(
      backgroundColor: kBg,
      body: CustomScrollView(
        slivers: [
          _buildAppBar(context),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── First-time / new-device welcome banner ───────────────
                  if (_lastSyncTime == null && !_syncing) ...[
                    _FirstSyncBanner(
                      onSync: _runSync,
                      isReturningUser: _isReturningUser,
                    ),
                    const SizedBox(height: 16),
                  ],

                  // ── Section 1: Your Health Today ──────────────────────────
                  _SectionHeader(title: 'Your Health Today', icon: Icons.favorite_border),
                  const SizedBox(height: 8),
                  _HealthTodayGrid(
                    snapshot: _snapshot,
                    loading: _loadingSnapshot,
                    hasSynced: _lastSyncTime != null,
                    deviceBrand: _deviceBrand,
                    onRefresh: _loadLocalSnapshot,
                  ),
                  // iPhone-only notice: has steps/sleep but no HR/HRV
                  if (isIphoneOnly) ...[
                    const SizedBox(height: 8),
                    _IphoneOnlyBanner(),
                  ],

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
                  // Error banner — always show permission errors; others only when no cached data
                  if (!_syncing && _lastSyncErrorType != null &&
                      (_insight == null || _lastSyncErrorType == SyncErrorType.permissionDenied)) ...[
                    _ErrorBanner(
                      errorType: _lastSyncErrorType!,
                      onSignIn: () => Navigator.pushNamedAndRemoveUntil(
                        context, '/login', (_) => false,
                      ),
                      onRetrySync: _runSync,
                    ),
                    const SizedBox(height: 8),
                  ],
                  _RiskInsightsCard(
                    insight: _insight,
                    loading: _loadingInsight,
                    apiOnline: _apiOnline,
                    hasSynced: _lastSyncTime != null,
                    iphoneOnly: isIphoneOnly,
                    fetchFailed: _insightFetchFailed,
                    onRetry: _fetchInsightsWithRetry,
                  ),

                  const SizedBox(height: 20),

                  // ── Section 3: Sync (compact — expandable details) ─────────
                  _CompactSyncSection(
                    syncing: _syncing,
                    syncStatusMsg: _syncStatusMsg,
                    pulseAnim: _pulseAnim,
                    apiOnline: _apiOnline,
                    lastSyncTime: _lastSyncTime,
                    lastEventCount: _lastEventCount,
                    lastSyncSuccess: _lastSyncSuccess,
                    lastSyncErrorType: _lastSyncErrorType,
                    lastSyncDevices: _lastSyncDevices,
                    lastSyncAt: _lastSyncAt,
                    newDeviceDetected: _newDeviceDetected,
                    onSync: _runSync,
                    onCheckApi: _checkApi,
                    onDismissNewDevice: () async {
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setBool('new_device_detected', false);
                      if (mounted) setState(() => _newDeviceDetected = false);
                    },
                  ),
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
        Icon(icon, size: 16, color: kNavy),
        const SizedBox(width: 6),
        Text(
          title,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: kTextPrimary,
            letterSpacing: -0.2,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(width: 4),
          Text(
            subtitle!,
            style: const TextStyle(fontSize: 12, color: kTextSecondary),
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
  final bool hasSynced;
  final String? deviceBrand;
  final VoidCallback onRefresh;
  const _HealthTodayGrid({this.snapshot, required this.loading, required this.hasSynced, this.deviceBrand, required this.onRefresh});

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
      final msg = hasSynced
          ? 'No health readings found today.\nMake sure your device is worn and synced.'
          : 'Tap "Sync" below to pull in your health data.';
      return _Card(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Row(
            children: [
              Icon(hasSynced ? Icons.watch_outlined : Icons.sync, size: 16, color: Colors.grey),
              const SizedBox(width: 8),
              Expanded(
                child: Text(msg, style: const TextStyle(fontSize: 12, color: Colors.grey)),
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

    // Show all supported metrics. Tiles with no data display '—' plus a device
    // hint so users understand what hardware is needed to unlock each metric.
    String h(String metric) => HealthService.metricHint(metric, deviceBrand);
    final tiles = <_MetricTileData>[
      _MetricTileData('Avg HR',     s.avgHr != null ? '${s.avgHr!.toInt()} bpm' : '—',                      Icons.favorite,               Colors.red.shade400,    deviceHint: h('hr')),
      _MetricTileData('Steps',      s.steps != null ? _formatSteps(s.steps!) : '—',                          Icons.directions_walk,         kNavy),
      _MetricTileData('Sleep',      s.sleepHours != null ? '${s.sleepHours!.toStringAsFixed(1)}h' : '—',     Icons.bedtime_outlined,        Colors.indigo.shade400, deviceHint: h('sleep')),
      _MetricTileData('HRV',        s.hrv != null ? '${s.hrv!.toInt()} ms' : '—',                            Icons.monitor_heart_outlined,  Colors.blue.shade400,   deviceHint: h('hrv')),
      _MetricTileData('Resting HR', s.rhr != null ? '${s.rhr!.toInt()} bpm' : '—',                           Icons.favorite_border,         Colors.pink.shade300,   deviceHint: h('rhr')),
      _MetricTileData('Blood O₂',   s.spo2 != null ? '${s.spo2!.toStringAsFixed(1)}%' : '—',                Icons.water_drop_outlined,     Colors.cyan.shade600,   deviceHint: h('spo2')),
      _MetricTileData('Exercise',   s.exerciseMin != null ? '${s.exerciseMin} min' : '—',                    Icons.fitness_center,          Colors.green.shade600,  deviceHint: h('exercise')),
      _MetricTileData('Resp Rate',  s.respRate != null ? '${s.respRate!.toStringAsFixed(1)} br/m' : '—',     Icons.air,                     Colors.teal.shade500,   deviceHint: h('resp')),
      _MetricTileData('BP Sys',     s.bpSystolic != null ? '${s.bpSystolic!.toInt()} mmHg' : '—',           Icons.compress,                Colors.orange.shade400, deviceHint: h('bp')),
      _MetricTileData('BP Dia',     s.bpDiastolic != null ? '${s.bpDiastolic!.toInt()} mmHg' : '—',         Icons.compress,                Colors.orange.shade300, deviceHint: h('bp')),
      _MetricTileData('AFib',       s.afibDetected == null ? '—' : (s.afibDetected! ? 'Detected' : 'None'),  Icons.electrical_services,    s.afibDetected == true ? Colors.red.shade600 : Colors.green.shade600, deviceHint: h('afib')),
    ];

    // Pair tiles into rows of 2.
    final rows = <Widget>[];
    for (int i = 0; i < tiles.length; i += 2) {
      if (rows.isNotEmpty) rows.add(const SizedBox(height: 8));
      rows.add(Row(children: [
        Expanded(child: _MetricTile(label: tiles[i].label, value: tiles[i].value, icon: tiles[i].icon, iconColor: tiles[i].color, deviceHint: tiles[i].deviceHint)),
        const SizedBox(width: 8),
        if (i + 1 < tiles.length)
          Expanded(child: _MetricTile(label: tiles[i+1].label, value: tiles[i+1].value, icon: tiles[i+1].icon, iconColor: tiles[i+1].color, deviceHint: tiles[i+1].deviceHint))
        else
          const Expanded(child: SizedBox()),
      ]));
    }

    return _Card(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          ...rows,
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(Icons.watch_outlined, size: 12, color: kTextSecondary),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  s.primarySource != null ? 'Via ${s.primarySource}' : 'Live from HealthKit',
                  style: const TextStyle(fontSize: 10, color: kTextSecondary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              GestureDetector(
                onTap: onRefresh,
                child: const Icon(Icons.refresh, size: 14, color: kTextSecondary),
              ),
            ],
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

class _MetricTileData {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  /// Shown as a small hint when value is '—', e.g. "Needs Apple Watch S6+".
  final String? deviceHint;
  const _MetricTileData(this.label, this.value, this.icon, this.color, {this.deviceHint});
}

class _MetricTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color iconColor;
  final String? deviceHint;
  const _MetricTile({required this.label, required this.value, required this.icon, this.iconColor = kNavy, this.deviceHint});

  bool get _hasData => value != '—';

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _hasData ? kMetricBg : const Color(0xFFF7F7F7),
        borderRadius: BorderRadius.circular(12),
        border: _hasData ? null : Border.all(color: const Color(0xFFE8E8E8), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              color: _hasData ? kTextPrimary : const Color(0xFFCCCCCC),
              letterSpacing: -0.5,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Icon(icon, size: 13, color: iconColor.withValues(alpha: _hasData ? 0.6 : 0.3)),
              const SizedBox(width: 4),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w400,
                  color: kTextSecondary,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
          if (!_hasData && deviceHint != null) ...[
            const SizedBox(height: 4),
            Text(
              deviceHint!,
              style: const TextStyle(
                fontSize: 9,
                color: Color(0xFFAAAAAA),
                height: 1.3,
              ),
            ),
          ],
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
  final bool hasSynced;
  final bool iphoneOnly;
  final bool fetchFailed;
  final VoidCallback? onRetry;
  const _RiskInsightsCard({
    this.insight,
    required this.loading,
    this.apiOnline,
    this.hasSynced = false,
    this.iphoneOnly = false,
    this.fetchFailed = false,
    this.onRetry,
  });

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
                child: CircularProgressIndicator(strokeWidth: 2, color: kNavy),
              ),
              SizedBox(width: 10),
              Text('Fetching insights…', style: TextStyle(fontSize: 13, color: Colors.grey)),
            ],
          ),
        ),
      );
    }

    if (insight == null) {
      // fetchFailed = all retries exhausted — show a distinct error state
      // so the user knows this is a problem, not a normal wait.
      if (fetchFailed) {
        return _Card(
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
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
                        'Could not load your score — please check your connection and try again.',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh, size: 14),
                    label: const Text('Retry', style: TextStyle(fontSize: 13)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: kNavy,
                      side: const BorderSide(color: kNavy),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }

      // Determine the right "no data" message based on context.
      final String noDataMsg;
      if (iphoneOnly) {
        noDataMsg = 'HRI scoring requires heart rate data from a wearable device '
            '(e.g. Apple Watch Series 5+). Steps and sleep are tracked, '
            'but cannot generate a risk score on their own.';
      } else if (hasSynced) {
        noDataMsg = 'Synced — waiting for TikCare to compute your first score. '
            'This can take a few minutes after your first sync.';
      } else {
        noDataMsg = 'Sync your data to receive\npersonalized risk insights.';
      }

      return _Card(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
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
                  Expanded(
                    child: Text(
                      noDataMsg,
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
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
        // HRI card — hero element (Stripe content-density: large score, small labels)
        _Card(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // HRI score circle — hero at 80px (was 66px)
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: hriColor.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                  border: Border.all(color: hriColor.withValues(alpha: 0.3), width: 2.5),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      s.hriScore > 0 ? '${s.hriScore}' : '--',
                      style: TextStyle(
                        fontSize: 42,
                        fontWeight: FontWeight.w300,  // Stripe: light weight for large numbers
                        color: hriColor,
                        letterSpacing: -1.5,
                        height: 1.0,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    Text(
                      'HRI',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: hriColor.withValues(alpha: 0.7),
                        letterSpacing: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          'Health Risk Index',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            color: kTextPrimary,
                            letterSpacing: -0.2,
                          ),
                        ),
                        const SizedBox(width: 4),
                        GestureDetector(
                          onTap: () => _showHriExplanation(context),
                          child: Icon(Icons.info_outline, size: 15, color: Colors.grey.shade400),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _hriDescription(s),
                      style: TextStyle(fontSize: 12, color: hriColor, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 8),
                    // Score bar: 0 ──[green]──[amber]──[orange]──[red]── 100
                    _HriScaleBar(score: s.hriScore),
                    const SizedBox(height: 5),
                    Text(
                      'Updated ${relativeTime(s.fetchedAt)}',
                      style: const TextStyle(fontSize: 11, color: kTextSecondary),
                    ),
                    // NOTE: fraudRiskScore is an insurer-side actuarial signal;
                    // it must NOT be displayed to the member (legal + UX risk).
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
                  _AnomalyBadge(count: s.anomalyBreakdown['severe']!, label: 'severe', color: kRed),
                if ((s.anomalyBreakdown['moderate'] ?? 0) > 0) ...[
                  const SizedBox(width: 4),
                  _AnomalyBadge(count: s.anomalyBreakdown['moderate']!, label: 'moderate', color: kOrange),
                ],
                if ((s.anomalyBreakdown['mild'] ?? 0) > 0) ...[
                  const SizedBox(width: 4),
                  _AnomalyBadge(count: s.anomalyBreakdown['mild']!, label: 'mild', color: kAmber),
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
          final color = sev == 'severe' ? kRed : kOrange;
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

  void _showHriExplanation(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.shield_outlined, color: kNavy, size: 22),
              const SizedBox(width: 10),
              const Text('What is HRI?',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: kNavy)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => Navigator.pop(context),
              ),
            ]),
            const SizedBox(height: 12),
            const Text(
              'HRI (Health Risk Index) is your personalized health risk score, ranging from 0 to 100. Lower is better.',
              style: TextStyle(fontSize: 14, height: 1.5),
            ),
            const SizedBox(height: 10),
            const Text(
              'It measures how much your recent heart rate, HRV, sleep, and activity deviate from YOUR personal baseline — not a population average.',
              style: TextStyle(fontSize: 13, color: Colors.grey, height: 1.5),
            ),
            const SizedBox(height: 16),
            // Score band table
            _HriBandRow(color: kGreen, range: '0 – 25', label: 'Low Risk', desc: 'Healthy patterns, minimal deviations'),
            const SizedBox(height: 8),
            _HriBandRow(color: kAmber, range: '26 – 50', label: 'Moderate', desc: 'Some anomalies detected, worth monitoring'),
            const SizedBox(height: 8),
            _HriBandRow(color: kOrange, range: '51 – 75', label: 'Elevated', desc: 'Noticeable deviations from your baseline'),
            const SizedBox(height: 8),
            _HriBandRow(color: kRed, range: '76 – 100', label: 'High Risk', desc: 'Significant deviations — consult your doctor'),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text(
                '💡 HRI is statistical, not clinical. It reflects changes in YOUR patterns. A high score does not mean you have a disease — it means your metrics have changed relative to your own history.',
                style: TextStyle(fontSize: 12, color: Colors.blueAccent, height: 1.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _hriColor(String label, {int score = 1}) {
    if (score == 0) return Colors.grey;
    return switch (label) {
      'critical' => kRed,
      'high' => kOrange,
      'moderate' => kAmber,
      _ => kGreen,
    };
  }

  String _hriDescription(RiskInsight s) {
    if (s.hriScore == 0) {
      return switch (s.baselineMaturity) {
        'cold_start' => 'Day ${s.daysWithData} of 14 — keep syncing daily to activate HRI',
        'developing' => 'Day ${s.daysWithData} of 30 — baseline still building',
        _ => 'Activating…',
      };
    }
    return switch (s.hriLabel) {
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
    final color = isChecking ? kAmber : (isOnline ? kGreen : kRed);
    final label = isChecking
        ? 'Checking server…'
        : isOnline
            ? 'LifePulse API connected'
            : 'Cannot reach server — tap ↻ to retry';

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
  final List<String> devices;
  const _LastSyncRow({
    required this.time,
    this.eventCount,
    required this.success,
    this.devices = const [],
  });

  @override
  Widget build(BuildContext context) {
    final color = success ? kGreen : kRed;
    final label = success
        ? 'Last sync: $time${eventCount != null ? ' · $eventCount events' : ''}'
        : 'Last sync failed: $time';

    // Show up to 2 device names, truncated cleanly
    final deviceLabel = devices.isEmpty
        ? null
        : devices.length == 1
            ? devices.first
            : '${devices.first} +${devices.length - 1} more';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              success ? Icons.check_circle_outline : Icons.error_outline,
              size: 14,
              color: color,
            ),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 12, color: color)),
          ],
        ),
        if (deviceLabel != null) ...[
          const SizedBox(height: 2),
          Row(
            children: [
              const Icon(Icons.watch_outlined, size: 12, color: Colors.grey),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  deviceLabel,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

// ── Stale Sync Warning ────────────────────────────────────────────────────────

class _StaleSyncWarning extends StatelessWidget {
  final VoidCallback onSync;
  const _StaleSyncWarning({required this.onSync});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.warning_amber_rounded, size: 14, color: kAmber),
        const SizedBox(width: 5),
        const Expanded(
          child: Text(
            'Data may be outdated — last sync was over 24 hours ago.',
            style: TextStyle(fontSize: 12, color: kAmber),
          ),
        ),
        TextButton(
          onPressed: onSync,
          style: TextButton.styleFrom(
            foregroundColor: kNavy,
            minimumSize: const Size(44, 44),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text(
            'Sync now',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

// ── New Device Setup Guide ────────────────────────────────────────────────────

/// Shown once after a sync detects a new device not seen in previous syncs.
/// Guides the user to confirm the device is properly set as the Health data
/// source, and explains the 14-day calibration period.
class _NewDeviceNotice extends StatelessWidget {
  final List<String> devices;
  final VoidCallback onDismiss;
  const _NewDeviceNotice({required this.devices, required this.onDismiss});

  // Identify the new device name for display
  String get _newDeviceName {
    final known = ['Apple Watch', 'Garmin', 'Samsung', 'Fitbit'];
    for (final d in devices) {
      for (final k in known) {
        if (d.toLowerCase().contains(k.toLowerCase())) return d;
      }
    }
    return devices.isNotEmpty ? devices.last : 'new device';
  }

  bool get _isAppleWatch =>
      _newDeviceName.toLowerCase().contains('apple watch');

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF0F9FF),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF7EC8E3).withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 0),
            child: Row(
              children: [
                const Icon(Icons.watch_outlined, size: 18, color: kNavy),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'New device detected — $_newDeviceName',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: kNavy,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: onDismiss,
                  child: Icon(Icons.close, size: 16, color: Colors.grey.shade400),
                ),
              ],
            ),
          ),

          // Calibration note
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
            child: Text(
              'Your health scores may vary for ~14 days while TikCare builds a baseline for this device. This is expected.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600, height: 1.4),
            ),
          ),

          // Setup steps — shown for Apple Watch (most common switch scenario)
          if (_isAppleWatch) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 10, 14, 4),
              child: Text(
                'Make sure Apple Watch is set as your primary source:',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: kNavy),
              ),
            ),
            _SetupStep(
              number: '1',
              text: 'Open the Health app on your iPhone',
            ),
            _SetupStep(
              number: '2',
              text: 'Tap Browse → Heart Rate → Data Sources & Access',
            ),
            _SetupStep(
              number: '3',
              text: 'Drag Apple Watch to the top of the list',
            ),
          ],

          // Open Health button + dismiss
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
            child: Row(
              children: [
                if (_isAppleWatch) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final uri = Uri.parse('x-apple-health://');
                        if (await canLaunchUrl(uri)) await launchUrl(uri);
                      },
                      icon: const Icon(Icons.open_in_new, size: 14),
                      label: const Text('Open Health App'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: kNavy,
                        side: const BorderSide(color: kNavy),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: OutlinedButton(
                    onPressed: onDismiss,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.grey,
                      side: BorderSide(color: Colors.grey.shade300),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      textStyle: const TextStyle(fontSize: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('Got it'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SetupStep extends StatelessWidget {
  final String number;
  final String text;
  const _SetupStep({required this.number, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 3, 14, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: kNavy.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                number,
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: kNavy),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade700, height: 1.4),
            ),
          ),
        ],
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
    (Icons.favorite_border, 'Resting HR'),
    (Icons.timer_outlined, 'Exercise Time'),
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
                Icon(m.$1, size: 12, color: kNavy),
                const SizedBox(width: 4),
                Text(
                  m.$2,
                  style: const TextStyle(fontSize: 11, color: kNavy, fontWeight: FontWeight.w500),
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

// ── Compact Sync Section (collapsible) ────────────────────────────────────────

class _CompactSyncSection extends StatefulWidget {
  final bool syncing;
  final String? syncStatusMsg;
  final Animation<double> pulseAnim;
  final bool? apiOnline;
  final String? lastSyncTime;
  final int? lastEventCount;
  final bool? lastSyncSuccess;
  final SyncErrorType? lastSyncErrorType;
  final List<String> lastSyncDevices;
  final DateTime? lastSyncAt;
  final bool newDeviceDetected;
  final VoidCallback onSync;
  final VoidCallback onCheckApi;
  final VoidCallback onDismissNewDevice;

  const _CompactSyncSection({
    required this.syncing,
    this.syncStatusMsg,
    required this.pulseAnim,
    this.apiOnline,
    this.lastSyncTime,
    this.lastEventCount,
    this.lastSyncSuccess,
    this.lastSyncErrorType,
    required this.lastSyncDevices,
    this.lastSyncAt,
    required this.newDeviceDetected,
    required this.onSync,
    required this.onCheckApi,
    required this.onDismissNewDevice,
  });

  @override
  State<_CompactSyncSection> createState() => _CompactSyncSectionState();
}

class _CompactSyncSectionState extends State<_CompactSyncSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final isStale = widget.lastSyncAt != null &&
        (widget.lastSyncSuccess ?? false) &&
        !widget.syncing &&
        DateTime.now().difference(widget.lastSyncAt!).inHours >= 24;

    // Compact summary row: always visible
    return _Card(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          // ── Summary row: status + sync button ──
          Row(
            children: [
              // Connection dot
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: widget.apiOnline == null
                      ? kAmber
                      : widget.apiOnline == true
                          ? kGreen
                          : kRed,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              // Last sync info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.lastSyncTime != null
                          ? 'Last sync: ${widget.lastSyncTime}'
                          : 'Not synced yet',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: kTextPrimary,
                      ),
                    ),
                    if (widget.lastSyncDevices.isNotEmpty)
                      Text(
                        widget.lastSyncDevices.length == 1
                            ? widget.lastSyncDevices.first
                            : '${widget.lastSyncDevices.first} +${widget.lastSyncDevices.length - 1}',
                        style: const TextStyle(fontSize: 11, color: kTextSecondary),
                      ),
                  ],
                ),
              ),
              // Expand/collapse chevron
              GestureDetector(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 22,
                  color: kTextSecondary,
                ),
              ),
            ],
          ),

          // Sync progress
          if (widget.syncing && widget.syncStatusMsg != null) ...[
            const SizedBox(height: 6),
            Text(
              widget.syncStatusMsg!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: kTextSecondary),
            ),
          ],

          // Stale warning (always visible — important)
          if (isStale) ...[
            const SizedBox(height: 8),
            _StaleSyncWarning(onSync: widget.onSync),
          ],

          // Retry (always visible when failed)
          if (!widget.syncing && widget.lastSyncSuccess == false &&
              widget.lastSyncErrorType != SyncErrorType.permissionDenied &&
              widget.lastSyncErrorType != SyncErrorType.authExpired) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton.icon(
                  onPressed: widget.onSync,
                  icon: const Icon(Icons.refresh, size: 14),
                  label: const Text('Retry', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(foregroundColor: kNavy),
                ),
              ],
            ),
          ],

          // ── Expanded details ──
          if (_expanded) ...[
            const Divider(height: 20, color: kBorderColor),
            _ConnectionBadge(apiOnline: widget.apiOnline, onRefresh: widget.onCheckApi),
            if (widget.lastSyncTime != null) ...[
              const SizedBox(height: 8),
              _LastSyncRow(
                time: widget.lastSyncTime!,
                eventCount: widget.lastEventCount,
                success: widget.lastSyncSuccess ?? false,
                devices: widget.lastSyncDevices,
              ),
            ],
            if (widget.newDeviceDetected) ...[
              const SizedBox(height: 8),
              _NewDeviceNotice(
                devices: widget.lastSyncDevices,
                onDismiss: widget.onDismissNewDevice,
              ),
            ],
            const SizedBox(height: 10),
            const _WhatWeSyncChips(),
          ],

          // ── Sync button — always visible at the bottom of the card ──
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: GestureDetector(
              onTap: widget.syncing ? null : widget.onSync,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 11),
                decoration: BoxDecoration(
                  gradient: widget.syncing
                      ? null
                      : const LinearGradient(colors: [kNavy, kNavyLight]),
                  color: widget.syncing ? kBorderColor : null,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: widget.syncing
                    ? const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: kTextSecondary,
                            ),
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Syncing…',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: kTextSecondary,
                            ),
                          ),
                        ],
                      )
                    : const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.sync, color: Colors.white, size: 16),
                          SizedBox(width: 6),
                          Text(
                            'Sync Now',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
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
        color: kCardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorderColor, width: 1),
        boxShadow: const [
          // Layer 1: ring shadow (Claude/Notion)
          BoxShadow(color: kBorderColor, blurRadius: 0, spreadRadius: 0),
          // Layer 2: soft ambient shadow
          BoxShadow(color: kShadowColor, blurRadius: 24, offset: Offset(0, 4)),
          // Layer 3: tight contact shadow
          BoxShadow(color: kShadowColor, blurRadius: 6, offset: Offset(0, 1)),
        ],
      ),
      child: child,
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
                'Showing cached data from ${relativeTime(cachedAt)} — tap to sync',
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

class _ErrorBanner extends StatefulWidget {
  final SyncErrorType errorType;
  final VoidCallback onSignIn;
  final VoidCallback? onRetrySync;
  const _ErrorBanner({required this.errorType, required this.onSignIn, this.onRetrySync});

  @override
  State<_ErrorBanner> createState() => _ErrorBannerState();
}

class _ErrorBannerState extends State<_ErrorBanner> {
  bool _requesting = false;
  bool _showManualSteps = false;

  Future<void> _handleGrantPermission() async {
    setState(() => _requesting = true);

    // Call requestPermissions — on first invocation this shows the system
    // permission dialog and registers the app with HealthKit / Health Connect.
    final granted = await HealthService.requestPermissions();
    if (!mounted) return;

    bool verified = granted;
    if (Platform.isIOS && granted) {
      // On iOS, requestAuthorization() ALWAYS returns true (Apple privacy
      // policy — apps cannot know whether the user granted or denied read
      // access). The only reliable check is to attempt an actual data read.
      verified = await HealthService.canReadHealthData();
      if (!mounted) return;
    }

    setState(() => _requesting = false);
    if (verified) {
      widget.onRetrySync?.call();
    } else {
      setState(() => _showManualSteps = true);
    }
  }

  Widget _buildPermissionCard() {
    final isIOS = Platform.isIOS;
    const warn = Color(0xFF856404);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3CD),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFFD700).withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──
          Row(children: [
            const Icon(Icons.health_and_safety_outlined, size: 16, color: warn),
            const SizedBox(width: 6),
            Text(
              isIOS ? 'Apple Health Access Required' : 'Health Connect Access Required',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: warn),
            ),
          ]),
          const SizedBox(height: 8),
          Text(
            isIOS
                ? 'TikCare needs access to your health data to calculate your risk score.'
                : 'TikCare needs access to Health Connect. Tap below to grant permission.',
            style: const TextStyle(fontSize: 12, color: warn, height: 1.4),
          ),
          const SizedBox(height: 12),

          // ── Primary action: Grant Permission ──
          SizedBox(
            width: double.infinity,
            child: GestureDetector(
              onTap: _requesting ? null : _handleGrantPermission,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: _requesting ? warn.withValues(alpha: 0.5) : warn,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_requesting) ...[
                      const SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Text(
                      _requesting ? 'Requesting...' : 'Grant Health Access',
                      style: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ── Progressive: manual steps (shown after first attempt fails) ──
          if (_showManualSteps) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Enable manually:',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: warn),
                  ),
                  const SizedBox(height: 8),
                  if (isIOS) ...[
                    _stepRow('1', 'Open the Health app on your iPhone'),
                    _stepRow('2', 'Tap your profile picture (top right)'),
                    _stepRow('3', 'Tap "Apps" under Privacy'),
                    _stepRow('4', 'Find "TikCare LifePulse" and turn on all categories'),
                    _stepRow('5', 'Come back here — sync starts automatically'),
                  ] else ...[
                    _stepRow('1', 'Open Health Connect'),
                    _stepRow('2', 'Go to "App permissions"'),
                    _stepRow('3', 'Find "TikCare LifePulse"'),
                    _stepRow('4', 'Allow all data categories'),
                    _stepRow('5', 'Come back here — sync starts automatically'),
                  ],
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: GestureDetector(
                      onTap: () async {
                        final uri = isIOS
                            ? Uri.parse('x-apple-health://')
                            : Uri.parse('healthconnect://');
                        if (await canLaunchUrl(uri)) await launchUrl(uri);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 9),
                        decoration: BoxDecoration(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: warn),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.open_in_new, size: 14, color: warn),
                            const SizedBox(width: 6),
                            Text(
                              isIOS ? 'Open Health App' : 'Open Health Connect',
                              style: const TextStyle(fontSize: 12, color: warn, fontWeight: FontWeight.w700),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'When you return, TikCare will detect the change and sync automatically.',
                    style: TextStyle(fontSize: 10, color: Color(0xFF9A8A5A), fontStyle: FontStyle.italic),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _stepRow(String num, String text) {
    const warn = Color(0xFF856404);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 18, height: 18,
            decoration: BoxDecoration(
              color: warn.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Center(
              child: Text(num, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: warn)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: const TextStyle(fontSize: 11.5, color: warn, height: 1.3)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Permission denied gets its own progressive-disclosure card
    if (widget.errorType == SyncErrorType.permissionDenied) {
      return _buildPermissionCard();
    }

    final (msg, icon, color) = switch (widget.errorType) {
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
          if (widget.errorType == SyncErrorType.authExpired)
            GestureDetector(
              onTap: widget.onSignIn,
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

// ── First Sync / New-Device Banner ────────────────────────────────────────────

class _FirstSyncBanner extends StatelessWidget {
  final VoidCallback onSync;
  final bool isReturningUser;
  const _FirstSyncBanner({required this.onSync, this.isReturningUser = false});

  @override
  Widget build(BuildContext context) {
    final title = isReturningUser
        ? 'Welcome back — re-link your health data'
        : 'Connect your Apple Watch / Health app';
    final subtitle = isReturningUser
        ? 'Your health history is safe. Tap to reconnect this device and keep your score up to date.'
        : 'Grant access so TikCare can start building your personalized health risk score.';
    final buttonLabel = isReturningUser ? 'Reconnect' : 'Connect Now';
    final bgColor = isReturningUser
        ? const Color(0xFFF0FFF4)   // green tint — reassuring
        : const Color(0xFFEBF4FF);  // blue tint — onboarding
    final borderColor = isReturningUser
        ? const Color(0xFF9AE6B4)
        : const Color(0xFF90CDF4);
    final iconColor = isReturningUser ? kGreen : kNavy;
    final icon = isReturningUser ? Icons.link : Icons.health_and_safety_outlined;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: iconColor, size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: isReturningUser ? kGreen : kNavy,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: const TextStyle(fontSize: 12, color: Colors.black54, height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          TextButton(
            onPressed: onSync,
            style: TextButton.styleFrom(
              backgroundColor: isReturningUser ? kGreen : kNavy,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: Text(buttonLabel, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

// ── HRI Scale Bar ─────────────────────────────────────────────────────────────

/// Thin 4-segment progress bar showing where the user's HRI score falls
/// across the Low / Moderate / Elevated / High risk bands.
class _HriScaleBar extends StatelessWidget {
  final int score;
  const _HriScaleBar({required this.score});

  @override
  Widget build(BuildContext context) {
    if (score <= 0) return const SizedBox.shrink();
    return LayoutBuilder(builder: (_, constraints) {
      final total = constraints.maxWidth;
      final indicator = (score.clamp(1, 100) / 100.0 * total).clamp(4.0, total - 4.0);
      final dotColor = score < 26 ? kGreen : score < 51 ? kAmber : score < 76 ? kOrange : kRed;
      return Stack(
        children: [
          Row(children: [kGreen, kAmber, kOrange, kRed].map((c) {
            return Expanded(
              child: Container(
                height: 5,
                margin: const EdgeInsets.symmetric(horizontal: 1),
                decoration: BoxDecoration(
                  color: c.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            );
          }).toList()),
          Positioned(
            left: indicator - 4,
            top: 0,
            child: Container(
              width: 8,
              height: 5,
              decoration: BoxDecoration(color: dotColor, borderRadius: BorderRadius.circular(3)),
            ),
          ),
        ],
      );
    });
  }
}

// ── iPhone-Only Mode Banner ───────────────────────────────────────────────────
// Shown when the device has steps/sleep but no HR/HRV (iPhone without a watch).

class _IphoneOnlyBanner extends StatelessWidget {
  const _IphoneOnlyBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3CD),
        border: Border.all(color: const Color(0xFFFFD700), width: 1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.watch_off_outlined, size: 20, color: Color(0xFF8A6D00)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'No heart rate data detected',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF5C4200),
                  ),
                ),
                const SizedBox(height: 3),
                const Text(
                  'HRI scoring requires a wearable device such as Apple Watch Series 5+ or later. '
                  'Steps and sleep are still being tracked from your iPhone.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF6B4F00), height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── HRI Band Row (for BottomSheet) ────────────────────────────────────────────

class _HriBandRow extends StatelessWidget {
  final Color color;
  final String range;
  final String label;
  final String desc;
  const _HriBandRow({required this.color, required this.range, required this.label, required this.desc});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 66,
          child: Text(range, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ),
        Expanded(
          child: Text(
            '$label — $desc',
            style: const TextStyle(fontSize: 12, color: Colors.grey, height: 1.4),
          ),
        ),
      ],
    );
  }
}
