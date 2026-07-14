import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/health_service.dart';
import '../services/sync_state.dart';
import '../services/sync_telemetry.dart';
import '../models/health_snapshot.dart';
import '../models/risk_insight.dart';
import '../utils/time_utils.dart';
import '../utils/metric_display.dart';
import '../utils/historical_gap_filler.dart';
import '../widgets/historical_gap_banner.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import 'widgets/unified_metric_tile.dart';

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

  // ── Historical-gap detection (matches Trends screen behaviour) ───────────
  // localDays = days with data in Apple Health for the recent window;
  // analyzedDays = days the backend has actually processed. When local >
  // analyzed by ≥3 days we render the tappable gap banner, and silently
  // auto-trigger a chunked re-sync (throttled to once per 12h).
  int? _localGapDays;
  bool _gapResyncing = false;

  // ── Cloud insights ───────────────────────────────────────────────────────
  RiskInsight? _insight;
  bool _loadingInsight = false;
  // True after all retry attempts are exhausted with no result.
  // Distinguishes a real fetch failure from a normal cold-start wait.
  bool _insightFetchFailed = false;

  // ── Round-18 — per-metric baselines (drives UnifiedMetricTile) ─────────
  // Replaces the round-17 phase-2 SignalsPanel state (dropped DailyReport
  // since the unified section now reads `currentValue` straight from the
  // HealthSnapshot, not the server-side daily report). Kept in parallel
  // with the sync + insight fetches; tiles render a per-metric "no
  // baseline yet" affordance when this map is empty.
  Map<String, double> _baselineByMetric = const {};
  bool _signalsLoading = true;

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
    _loadSignals();
    WidgetsBinding.instance.addObserver(this);
  }

  /// Round-18: load per-metric 90-day baselines used by UnifiedMetricTile.
  /// Independent of sync: if the fetch fails, individual tiles render a
  /// "No baseline yet" affordance and the rest of Today still works.
  Future<void> _loadSignals({bool silent = false}) async {
    if (!silent) setState(() => _signalsLoading = true);
    try {
      final baselines = await HealthService.fetchBaselines();
      if (!mounted) return;
      setState(() {
        _baselineByMetric = baselines;
        _signalsLoading = false;
      });
    } catch (e) {
      debugPrint('[HomeScreen._loadSignals] $e');
      if (mounted) setState(() => _signalsLoading = false);
    }
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

    // Track B: SyncStateStore is the source of truth.  The previous
    // implementation read four legacy SharedPrefs keys that the v5.0
    // migration deletes — the throttle would then think the user had
    // never synced and silently fire on every resume forever.
    await SyncStateStore.instance.load();
    final state = SyncStateStore.instance.value;
    final lastSuccess = state.lastSuccessAtIso != null;
    final lastErrName = state.lastErrorClass;
    final lastErr = lastErrName != null
        ? SyncErrorType.values.where((e) => e.name == lastErrName).firstOrNull
        : null;
    final lastAttempt = state.lastAttemptAtIso != null
        ? DateTime.tryParse(state.lastAttemptAtIso!)
        : null;

    // Resume policy:
    //   * never synced (no attempt recorded) → let the first-sync banner
    //     drive — don't auto-fire
    //   * last attempt succeeded → throttle to once per 30 min
    //   * last attempt was a transient failure (network / unknown /
    //     serverError) → auto-retry on resume so a flaky-Wi-Fi tap
    //     doesn't leave the user stuck on a stale tile.  Throttle to
    //     once per 5 min so we don't hammer a backend that's actually
    //     down.
    //   * permission / auth errors → user must act (open Health app,
    //     sign in) — auto-retry would just bounce off the same wall.
    const transient = {
      SyncErrorType.network,
      SyncErrorType.serverError,
      SyncErrorType.unknown,
    };
    final isTransientFailure =
        state.lastAttemptFailed && transient.contains(lastErr);
    // Brand-new install / no attempt yet — let the onboarding banner
    // drive the first sync.
    if (lastAttempt == null) return;
    // Last attempt failed for a non-transient reason — don't auto-retry.
    if (state.lastAttemptFailed && !isTransientFailure) return;

    // Throttle: 30 min for normal cadence, 5 min for transient-failure retry.
    final throttleMin = isTransientFailure ? 5 : 30;
    final last = lastSuccess
        ? DateTime.tryParse(state.lastSuccessAtIso!)
        : lastAttempt;
    if (last != null &&
        DateTime.now().difference(last).inMinutes < throttleMin) {
      return;
    }

    // Capture the current devices list before the async gap so the .then()
    // closure doesn't reference the instance field after potential disposal.
    final knownDevices = List<String>.from(_lastSyncDevices);

    // Silent sync — no spinner, no UI disruption.  Tag this as
    // "background" so the portal's failure-rate dashboard doesn't
    // attribute auto-resume failures to manual user-initiated taps.
    try {
      final result = await HealthService.syncDirect(
        syncPath: SyncPath.background,
      );
      if (!mounted) return;
      if (result.success) {
        final eventCount = (result.data?['events_received'] as int?) ?? 0;
        final isUpToDate = result.errorType == SyncErrorType.noData;
        final devices = isUpToDate
            ? knownDevices
            : (result.data?['source_devices'] as List?)?.cast<String>() ?? [];
        await _saveLastSync(true, eventCount, null, devices);
        if (mounted) {
          _loadLocalSnapshot(silent: true);
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

  // Recompute the Apple-Health-vs-analyzed gap and trigger an auto re-sync
  // when warranted. Call this whenever ``_insight`` changes (cache load,
  // retry success, manual sync) so the banner reflects current state.
  Future<void> _recomputeHistoricalGap() async {
    final insight = _insight;
    if (insight == null) return;
    // Fetch local Apple Health day-count over the same 30-day window the
    // insight is summarising. fetchLocalDaysWithData is HKHealth-only and
    // returns 0 on Android — banner stays hidden by the `> 0` check below.
    final local = await HealthService.fetchLocalDaysWithData(days: 30);
    if (!mounted) return;
    final gap = local - insight.daysWithData;
    setState(() => _localGapDays = gap > 0 ? gap : null);
    if (gap > 0) {
      final fut = await HistoricalGapFiller.maybeAutoFill(gap);
      if (fut != null && mounted) {
        setState(() => _gapResyncing = true);
        // Subscribe to completion — same fix as the Trends screen. The
        // previous code set _gapResyncing=true with no follow-up to
        // clear it, so the "Filling the gap…" banner would render
        // forever after one auto-trigger.
        // ignore: unawaited_futures
        fut.then((result) async {
          if (!mounted) return;
          if (result.success) {
            await HistoricalGapFiller.markComplete();
          }
          setState(() {
            _gapResyncing = false;
            // Re-evaluate gap after the backfill — the banner should
            // shrink or disappear entirely.
            _localGapDays = null;
          });
          // Refresh the underlying snapshot + insight so the user sees
          // the freshly-backfilled days reflected in the tiles.
          if (result.success) {
            _loadLocalSnapshot(silent: true);
            _fetchInsightsWithRetry();
          }
        });
        // Defensive 3-minute cap.
        Future.delayed(const Duration(minutes: 3), () {
          if (mounted && _gapResyncing) {
            setState(() => _gapResyncing = false);
          }
        });
      }
    }
  }

  Future<void> _runManualGapResync(int gapDays) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Fill historical gap?', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        content: Text(
          'Re-uploads up to ${HealthService.kHistoricalSyncDays} days from Apple Health to backfill the '
          '$gapDays missing days. Runs in weekly chunks — safe to interrupt; '
          'duplicates are filtered automatically.',
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Re-sync', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _gapResyncing = true);
    final result = await HealthService.syncDirect(
      forceFullResync: true,
      syncPath: SyncPath.historical,
    );
    if (result.success) await HistoricalGapFiller.markComplete();
    if (!mounted) return;
    setState(() => _gapResyncing = false);
    messenger.showSnackBar(SnackBar(
      content: Text(result.success
          ? 'Re-sync complete. Data is updating…'
          : 'Re-sync failed: ${result.message}'),
      backgroundColor: result.success ? Colors.green : Colors.red,
    ));
    if (result.success) {
      _loadLocalSnapshot();
      _recomputeHistoricalGap();
    }
  }

  Future<void> _loadLocalSnapshot({bool silent = false}) async {
    // silent = true: background refresh — don't flash loading spinner,
    // just update the data when ready.
    if (!silent) setState(() => _loadingSnapshot = true);
    var snapshot = await HealthService.fetchTodaySnapshot();
    // Round-17 phase 2: when the FIRST snapshot read after app cold-start
    // returns nothing (no data + no devices), wait 1s and retry once.
    // iOS HealthKit can take a beat to "warm up" right after app launch
    // — the Apple Watch needs to wake, sources need to be queried.  A
    // single retry handles the init-race without blocking the UI.
    if (snapshot.primarySource == null && !snapshot.hasData && mounted) {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return;
      final retry = await HealthService.fetchTodaySnapshot();
      if (retry.hasData || retry.primarySource != null) {
        snapshot = retry;
      }
    }
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
    // Track B: SyncStateStore is the source of truth for sync timestamps
    // and outcomes.  Pre-fix this method read five legacy SharedPrefs
    // keys (last_sync_iso, last_sync_time, last_event_count,
    // last_sync_success, last_sync_error_type) — but migrate() deletes
    // them on app start.  Result: every upgraded user saw "never
    // synced" on the home screen even though their sync history was
    // intact in syncstate_v1_*.  This was the same UX failure mode
    // Track B was designed to eliminate.  Now migrated.
    await SyncStateStore.instance.load();
    final state = SyncStateStore.instance.value;

    final errorType = state.lastErrorClass != null
        ? SyncErrorType.values
            .where((e) => e.name == state.lastErrorClass)
            .firstOrNull
        : null;

    // Devices list and new-device flag remain in SharedPreferences for
    // now (not part of SyncState); these were never deleted by
    // migrate() and the existing UX depends on them.
    final prefs = await SharedPreferences.getInstance();
    final rawDevices = prefs.getStringList('last_sync_devices') ?? [];
    final newDevice = prefs.getBool('new_device_detected') ?? false;

    DateTime? successAt;
    String? successLabel;
    if (state.lastSuccessAtIso != null) {
      successAt = DateTime.tryParse(state.lastSuccessAtIso!);
      if (successAt != null) {
        // Render the same "M/D HH:MM" label format the legacy code used
        // so downstream widget consumers don't need to change.
        final m = successAt.month;
        final d = successAt.day;
        final hh = successAt.hour.toString().padLeft(2, '0');
        final mm = successAt.minute.toString().padLeft(2, '0');
        successLabel = '$m/$d $hh:$mm';
      }
    }

    setState(() {
      _lastSyncTime = successLabel;
      _lastSyncAt = successAt;
      _lastEventCount = state.lastEventCount;
      // _lastSyncSuccess reflects the LATEST attempt's outcome, not
      // whether a success has ever happened.  state.lastAttemptFailed
      // is true iff the last attempt failed; invert for "succeeded".
      // null when no attempt has ever happened.
      _lastSyncSuccess = state.lastAttemptAtIso == null
          ? null
          : !state.lastAttemptFailed;
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

    // CRITICAL (Track B fix for v4.5 outage UX):
    //   `last_sync_time` and `last_sync_iso` represent "when was the most
    //   recent SUCCESSFUL sync".  Pre-fix the code wrote them on every
    //   attempt — success or failure — so the Profile top row read
    //   "Last synced now" while the expanded body said "Last sync failed
    //   now".  Only update on success.
    if (success) {
      await prefs.setString('last_sync_time', label);
      await prefs.setString('last_sync_iso', now.toIso8601String());
      await prefs.setInt('last_event_count', eventCount);
    }
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
      if (success) {
        _lastSyncTime = label;
        _lastSyncAt = now;
        _lastEventCount = eventCount;
      }
      _lastSyncSuccess = success;
      _lastSyncErrorType = errorType;
      _lastSyncDevices = devices;
      _newDeviceDetected = newDeviceFound;
    });
  }

  Future<void> _checkApi() async {
    final result = await HealthService.pingVitametric();
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
      // Round-17 phase 2: hard 3-minute timeout on the WHOLE sync flow.
      // Round-7 already added per-step polling timeouts (90s incremental,
      // 3min historical) inside HealthService.syncDirect, but if any
      // upstream stage hangs (HK read stuck, JWT refresh hung, native
      // VO2 bridge wedged) the spinner could in principle stay on
      // forever.  This outer ceiling guarantees the user always gets a
      // result — success OR a clear failure — within 3 minutes.
      final result = await HealthService.syncDirect(
        onLog: (msg) {
          // Surface upload batch progress to the UI
          if (mounted && msg.startsWith('Uploading')) {
            setState(() => _syncStatusMsg = msg);
          }
        },
      ).timeout(
        const Duration(minutes: 3),
        onTimeout: () => SyncResult(
          success: false,
          message: 'Sync took too long (>3 min). Please try again.',
          errorType: SyncErrorType.unknown,
        ),
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
          // Round-17 phase 2: refresh the SignalsPanel data after a
          // successful sync so the per-metric tiles reflect today's
          // values, not the pre-sync cached report.
          _loadSignals(silent: true);
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
  /// Retry schedule: 5 s → 10 s → 15 s → 20 s → 25 s (75 s total).
  /// The backend processes events asynchronously (202 Accepted), so the
  /// first fetch often arrives before baselines are computed. We keep
  /// retrying if the result looks stale (cold_start with 0 days despite
  /// a successful upload).
  Future<void> _fetchInsightsWithRetry() async {
    if (!mounted) return;
    setState(() => _loadingInsight = true);
    const retryDelays = [5, 10, 15, 20, 25];
    RiskInsight? lastInsight;
    try {
      for (final delaySec in retryDelays) {
        await Future.delayed(Duration(seconds: delaySec));
        if (!mounted) return;
        final insight = await HealthService.fetchRiskInsight();
        if (!mounted) return;
        if (insight != null) {
          lastInsight = insight;
          // Backend returns 200 even while still processing. If baselines
          // haven't been computed yet the response looks like cold_start with
          // 0 days — keep retrying so the user sees the real score.
          final looksReady = insight.hriScore > 0 ||
              insight.daysWithData > 0 ||
              insight.baselineMaturity != 'cold_start';
          if (looksReady) {
            setState(() {
              _insight = insight;
              _apiOnline = true;
              _insightFetchFailed = false;
            });
            // Surface gap banner if Apple Health has more days than the
            // backend has analyzed; auto-trigger re-sync (throttled).
            _recomputeHistoricalGap();
            return; // success — stop
          }
        }
      }
      // Retries exhausted — show whatever we got (may still be cold_start
      // if the backend genuinely has no data yet, which is fine).
      if (lastInsight != null) {
        setState(() {
          _insight = lastInsight;
          _apiOnline = true;
          _insightFetchFailed = false;
        });
        return;
      }
      // All attempts exhausted. Only mark as failed if we have NO insight
      // at all (neither from retries nor from a previous cache load).
      // If _insight already holds cached data, keep showing it rather than
      // replacing it with a "Could not load" error.
      if (mounted && _insight == null) {
        setState(() => _insightFetchFailed = true);
      }
      HealthService.reportClientError(
        'hri_fetch_failed',
        context: 'all retries exhausted',
        retryCount: retryDelays.length,
      );
    } catch (e) {
      debugPrint('[HomeScreen._fetchInsightsWithRetry] $e');
      if (mounted && _insight == null) {
        setState(() => _insightFetchFailed = true);
      }
      HealthService.reportClientError(
        'hri_fetch_exception',
        context: e.runtimeType.toString(),
        retryCount: retryDelays.length,
      );
    } finally {
      if (mounted) setState(() => _loadingInsight = false);
    }
  }

  // Keys must match `_WhatWeSyncChips._metrics[i].$3`. A metric is "active"
  // when the latest snapshot has a non-null value for it — i.e. data was
  // ingested. Drives blue (active) vs grey (no data) chip rendering.
  Set<String> _activeMetricsFromSnapshot() {
    final s = _snapshot;
    if (s == null) return const <String>{};
    return <String>{
      if (s.latestHr != null) 'hr',
      if (s.hrv != null) 'hrv',
      if (s.steps != null) 'steps',
      if (s.spo2 != null) 'spo2',
      if (s.rhr != null) 'rhr',
      if (s.exerciseMin != null) 'exercise',
      if (s.sleepHours != null) 'sleep',
      if (s.respRate != null) 'resp',
    };
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // iPhone-only flag: nothing from a Watch in the last 7 days, but iPhone
    // is still recording steps/sleep. The previous test ("no HR in last 24h")
    // mis-fired any time a user took the watch off overnight to charge — the
    // banner accused them of having no Watch when in fact they wore one
    // yesterday. `noHrLast7Days` is computed in fetchTodaySnapshot() and only
    // turns true when there's truly no HR sample in the past week.
    final isIphoneOnly = !_loadingSnapshot &&
        _lastSyncTime != null &&
        _snapshot != null &&
        _snapshot!.noHrLast7Days &&
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
                  // Round-11: removed the _FirstSyncBanner ("Connect Now" /
                  // "Reconnect") top card.  The bottom "Sync Now" button is
                  // visible from the same screen and the banner duplicated
                  // its purpose — and worse, the gating condition
                  // (_lastSyncTime == null) lingered on every failed first
                  // sync, surfacing two competing call-to-action buttons.

                  // ── Historical-gap banner (when Apple Health > analyzed) ──
                  if (_localGapDays != null && _localGapDays! > 0) ...[
                    HistoricalGapBanner(
                      gapDays: _localGapDays!,
                      resyncing: _gapResyncing,
                      onTap: () => _runManualGapResync(_localGapDays!),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // ── Section 1: Your Health Today ──────────────────────────
                  // Round-18: single unified per-metric section. Each tile
                  // shows the latest HK reading + sample age + comparison
                  // against the member's personal 90-day baseline (delta% +
                  // status pill: Normal / Above usual / Below usual).
                  // Replaces the pre-round-18 split between _HealthTodayGrid
                  // (HK current values) and SignalsPanel (baseline comparison)
                  // — the duplicate sections both rendered the same metrics
                  // and operators reported it as "cluttered, redundant".
                  _SectionHeader(title: 'Your Health Today', icon: Icons.favorite_border),
                  const SizedBox(height: AppSpacing.sm),
                  _UnifiedHealthSection(
                    snapshot: _snapshot,
                    snapshotLoading: _loadingSnapshot,
                    signalsLoading: _signalsLoading,
                    baselines: _baselineByMetric,
                    hasSynced: _lastSyncTime != null,
                    deviceBrand: _deviceBrand,
                  ),
                  // iPhone-only notice: has steps/sleep but no HR/HRV
                  if (isIphoneOnly) ...[
                    const SizedBox(height: AppSpacing.sm),
                    _IphoneOnlyBanner(),
                  ],

                  const SizedBox(height: AppSpacing.xl),

                  // ── Section 2: Risk Insights (cloud) ─────────────────────
                  _SectionHeader(
                    title: 'Risk Insights',
                    icon: Icons.shield_outlined,
                    subtitle: 'from TikCare',
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  // Cache banner — suppressed while a historical-gap
                  // backfill is in flight. The gap banner already says
                  // "Backfilling N days …" so showing a second "Showing
                  // cached data from yesterday" line at the same time
                  // was redundant and read as a panic stack to the user.
                  if (_insightFromCache && _insightCachedAt != null && !_gapResyncing) ...[
                    _CacheBanner(cachedAt: _insightCachedAt!),
                    const SizedBox(height: 8),
                  ],
                  // Error banner — always show permission errors; others only when no cached data
                  // Error banner — show whenever sync truly failed, regardless of
                  // whether we have a cached insight. Hiding the banner when cache
                  // existed left users with a mute Retry button and no clue why
                  // sync was failing (most often: token cleared by 401 refresh).
                  if (!_syncing &&
                      _lastSyncSuccess == false &&
                      _lastSyncErrorType != null &&
                      _lastSyncErrorType != SyncErrorType.noData) ...[
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

                  const SizedBox(height: AppSpacing.xl),

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
                    activeMetrics: _activeMetricsFromSnapshot(),
                    onSync: _runSync,
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
                        'TikCare Vitametric',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
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
        Text(title, style: AppText.sectionHeader),
        if (subtitle != null) ...[
          const SizedBox(width: 4),
          Text(subtitle!, style: AppText.caption),
        ],
      ],
    );
  }
}

// ── Unified Health Section ────────────────────────────────────────────────────
//
// Round-18: replaces both the pre-round-18 ``_HealthTodayGrid`` (HK current
// values in a 2-col grid) and the ``SignalsPanel`` (baseline comparison
// list) which used to live as two separate sections with the same metrics.
// Operators reported the duplication as cluttered and confusing.
//
// Each metric now renders as one full-width ``UnifiedMetricTile``:
//   ┌──────────────────────────────────────────────────┐
//   │ ❤  Heart Rate                            72.3 bpm │
//   │                                          (2h ago) │
//   │     Your usual: 70.1 bpm     +3.2%       [Normal] │
//   └──────────────────────────────────────────────────┘
//
// Sleep keeps its dedicated breakdown card (full-width, multi-stage). AFib
// is inline only when ``afibDetected == true`` because a binary "None" tile
// for every member who's never had an episode adds no value.
class _UnifiedHealthSection extends StatelessWidget {
  final HealthSnapshot? snapshot;
  final bool snapshotLoading;
  final bool signalsLoading;
  final Map<String, double> baselines;
  final bool hasSynced;
  final String? deviceBrand;

  const _UnifiedHealthSection({
    required this.snapshot,
    required this.snapshotLoading,
    required this.signalsLoading,
    required this.baselines,
    required this.hasSynced,
    this.deviceBrand,
  });

  // Convert a HealthSnapshot field (display-form) back to backend stored-form
  // for routing through MetricDisplay.formatWithUnit. SpO2 is the only metric
  // whose Flutter snapshot pre-multiplies (×100 for %); everything else round
  // -trips 1:1.
  double? _toStored(String metricType, num? snapshotValue) {
    if (snapshotValue == null) return null;
    final scale = MetricDisplay.scale(metricType);
    if (scale == 1.0) return snapshotValue.toDouble();
    return snapshotValue.toDouble() / scale;
  }

  @override
  Widget build(BuildContext context) {
    if (snapshotLoading) {
      return _Card(
        child: const Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text('Reading HealthKit…',
                style: TextStyle(color: Colors.grey, fontSize: 13)),
          ),
        ),
      );
    }

    final s = snapshot;
    if (s == null || !s.hasData) {
      final msg = hasSynced
          ? 'No health readings found today.\nMake sure your device is worn and synced.'
          : 'Tap "Sync Now" below to pull in your health data.';
      return _Card(
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Row(
            children: [
              Icon(hasSynced ? Icons.watch_outlined : Icons.sync,
                  size: 16, color: Colors.grey),
              const SizedBox(width: 8),
              Expanded(
                child: Text(msg, style: AppText.caption),
              ),
            ],
          ),
        ),
      );
    }

    // Order matches the most-glanced-at metrics first: HR + Steps top, then
    // recovery (HRV / RHR / SpO2), then activity (Exercise), then breath +
    // BP. Sleep card is inserted between the cardiac and recovery rows.
    final specs = <_UnifiedSpec>[
      _UnifiedSpec('HR_INSTANT',    _toStored('HR_INSTANT', s.latestHr),
          s.hrSampleAt,         Icons.favorite,                Colors.red.shade400),
      _UnifiedSpec('STEPS_DELTA',   _toStored('STEPS_DELTA', s.steps),
          null,                 Icons.directions_walk,         kNavy),
      _UnifiedSpec('HRV_SDNN',      _toStored('HRV_SDNN', s.hrv),
          s.hrvSampleAt,        Icons.monitor_heart_outlined,  Colors.blue.shade400),
      _UnifiedSpec('RHR_DAILY',     _toStored('RHR_DAILY', s.rhr),
          s.rhrSampleAt,        Icons.favorite_border,         Colors.pink.shade300),
      _UnifiedSpec('SPO2_INSTANT',  _toStored('SPO2_INSTANT', s.spo2),
          s.spo2SampleAt,       Icons.water_drop_outlined,     Colors.cyan.shade600),
      _UnifiedSpec('EXERCISE_TIME', _toStored('EXERCISE_TIME', s.exerciseMin),
          null,                 Icons.fitness_center,          Colors.green.shade600),
      _UnifiedSpec('RESP_RATE',     _toStored('RESP_RATE', s.respRate),
          s.respRateSampleAt,   Icons.air,                     Colors.teal.shade500),
      _UnifiedSpec('BP_SYSTOLIC',   _toStored('BP_SYSTOLIC', s.bpSystolic),
          s.bpSampleAt,         Icons.compress,                Colors.orange.shade400),
      _UnifiedSpec('BP_DIASTOLIC',  _toStored('BP_DIASTOLIC', s.bpDiastolic),
          s.bpSampleAt,         Icons.compress,                Colors.orange.shade300),
    ];

    final children = <Widget>[];
    for (var i = 0; i < specs.length; i++) {
      if (i > 0) children.add(const SizedBox(height: AppSpacing.sm));
      final spec = specs[i];
      children.add(UnifiedMetricTile(
        metricType: spec.metricType,
        currentValue: spec.value,
        sampleAt: spec.sampleAt,
        baselineMedian: baselines[spec.metricType],
        iconOverride: spec.icon,
        iconColor: spec.color,
      ));
      // Slot the Sleep breakdown card right after Steps so the "what did
      // you do today + how did you sleep" recap reads as one block.
      if (spec.metricType == 'STEPS_DELTA') {
        children.add(const SizedBox(height: AppSpacing.sm));
        children.add(_SleepBreakdownCard(
          snapshot: s,
          hint: HealthService.metricHint('sleep', deviceBrand),
        ));
      }
    }

    // AFib only when actually detected — a perpetual "None" tile adds no
    // information for the 99.x% of members who never have an episode.
    if (s.afibDetected == true) {
      children.add(const SizedBox(height: AppSpacing.sm));
      children.add(_AfibAlertTile(sampleAt: s.afibSampleAt));
    }

    // Source + baseline disclaimer. Single line, low-contrast — gives users
    // a one-glance reminder of where the numbers come from without cluttering
    // every tile.
    children.add(const SizedBox(height: AppSpacing.md));
    children.add(Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.watch_outlined, size: 12, color: kTextSecondary),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              s.primarySource != null
                  ? 'Via ${s.primarySource} · compared against your 90-day usual'
                  : 'Live from HealthKit · compared against your 90-day usual',
              style: AppText.caption.copyWith(color: kTextSecondary),
            ),
          ),
        ],
      ),
    ));

    return Column(children: children);
  }
}

class _UnifiedSpec {
  final String metricType;
  final double? value;
  final DateTime? sampleAt;
  final IconData icon;
  final Color color;
  const _UnifiedSpec(
      this.metricType, this.value, this.sampleAt, this.icon, this.color);
}

/// Inline AFib detection banner — only shown when AFib is currently flagged.
/// Apple Watch's AFib detection has 96% sensitivity and detected events
/// indicate ~5× higher stroke risk per Framingham, so a dedicated red
/// banner with a short call-to-action ("share with your doctor") is the
/// right surface — not buried in a tile grid.
class _AfibAlertTile extends StatelessWidget {
  final DateTime? sampleAt;
  const _AfibAlertTile({this.sampleAt});

  @override
  Widget build(BuildContext context) {
    final ageText = sampleAt != null ? relativeTime(sampleAt!) : null;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFECACA)),
      ),
      child: Row(
        children: [
          Icon(Icons.electrical_services, size: 20, color: Colors.red.shade600),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('AFib detected',
                    style: AppText.tileTitle.copyWith(
                        color: Colors.red.shade700)),
                Text(
                  ageText != null
                      ? 'Reported $ageText. Consider sharing with your doctor.'
                      : 'Recently reported. Consider sharing with your doctor.',
                  style: AppText.caption.copyWith(color: Colors.red.shade700),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// _MetricTile + MetricTileData were moved to widgets/metric_tile.dart
// in v4.4. Renamed to MetricTile / MetricTileData (public) so other screens
// can reuse them.

/// Full-width sleep card with a breakdown by stage. Replaces the single Sleep
/// tile so users see how the night was actually spent (Deep / REM / Light)
/// instead of one opaque "X.Yh" total. AWAKE intervals are intentionally not
/// shown — the pipeline filters them server-side and Apple Health does not
/// reliably distinguish "awake during sleep" from "awake after final wake".
class _SleepBreakdownCard extends StatelessWidget {
  final HealthSnapshot snapshot;
  final String? hint;
  const _SleepBreakdownCard({required this.snapshot, this.hint});

  @override
  Widget build(BuildContext context) {
    final s = snapshot;
    final hasTotal = s.sleepHours != null;
    final hasStages = s.sleepDeepMin != null || s.sleepRemMin != null || s.sleepLightMin != null;

    String fmtHrs(int? min) {
      if (min == null || min == 0) return '—';
      final h = min ~/ 60;
      final m = min % 60;
      if (h == 0) return '${m}m';
      if (m == 0) return '${h}h';
      return '${h}h ${m}m';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: hasTotal ? kMetricBg : const Color(0xFFF7F7F7),
        borderRadius: BorderRadius.circular(12),
        border: hasTotal ? null : Border.all(color: const Color(0xFFE8E8E8), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                hasTotal ? '${s.sleepHours!.toStringAsFixed(1)}h' : '—',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: hasTotal ? kTextPrimary : const Color(0xFFCCCCCC),
                  letterSpacing: -0.5,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 6),
              Padding(
                padding: const EdgeInsets.only(bottom: 5),
                child: Icon(
                  Icons.bedtime_outlined,
                  size: 13,
                  color: Colors.indigo.shade400.withValues(alpha: hasTotal ? 0.6 : 0.3),
                ),
              ),
              const SizedBox(width: 4),
              const Padding(
                padding: EdgeInsets.only(bottom: 5),
                child: Text(
                  'Sleep',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    color: kTextSecondary,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ],
          ),
          if (hasStages) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(child: _stageCell('Deep',  fmtHrs(s.sleepDeepMin),  Colors.indigo.shade700)),
                Expanded(child: _stageCell('REM',   fmtHrs(s.sleepRemMin),   Colors.purple.shade400)),
                Expanded(child: _stageCell('Light', fmtHrs(s.sleepLightMin), Colors.blue.shade300)),
              ],
            ),
          ] else if (!hasTotal && hint != null) ...[
            const SizedBox(height: 4),
            Text(
              hint!,
              style: const TextStyle(fontSize: 9, color: Color(0xFFAAAAAA), height: 1.3),
            ),
          ],
        ],
      ),
    );
  }

  Widget _stageCell(String label, String value, Color dotColor) {
    return Row(
      children: [
        Container(
          width: 6, height: 6,
          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: const TextStyle(fontSize: 10, color: kTextSecondary, fontWeight: FontWeight.w500),
        ),
        const SizedBox(width: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 11,
            color: kTextPrimary,
            fontWeight: FontWeight.w600,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
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
        // Round-11: dropped the 'ABI —' placeholder pill.  The error
        // state is now a simple message + Retry button — no jargon
        // label sitting on top of an empty value.
        return _Card(
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Icon(Icons.cloud_off_outlined, size: 16, color: Colors.grey),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Could not load your insights — please check your connection and try again.',
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

      // Round-11: dropped the 'ABI —' placeholder pill from the
      // no-data state and rephrased messages without the ABI label.
      // Keeps the same three context branches (iPhone-only vs synced
      // vs not-yet-synced) but in plain English.
      final String noDataMsg;
      if (iphoneOnly) {
        noDataMsg = 'Personalized insights require heart rate data from a '
            'wearable device (e.g. Apple Watch Series 5+). Steps and sleep '
            'are tracked, but cannot generate insights on their own.';
      } else if (hasSynced) {
        noDataMsg = 'Synced — your insights will appear shortly. '
            'This can take a few minutes after your first sync.';
      } else {
        noDataMsg = 'Sync your data to receive\npersonalized health insights.';
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
                  const Icon(Icons.shield_outlined, size: 16, color: Colors.grey),
                  const SizedBox(width: 8),
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
                  message: 'TikCare server unreachable — configure server URL in Settings.',
                ),
              ],
            ],
          ),
        ),
      );
    }

    final s = insight!;

    // v4.6: replaced the 80-pt ABI score circle + "Anomaly Burden Index"
    // hero with a minimalist sync-status card. The composite ABI score was
    // misleading — chronically-stable unhealthy users got "Excellent"
    // because they didn't deviate from their (already-elevated) baseline.
    // Per-metric data lives on the Risk tab now (Today's Signals panel).
    // NOTE: fraudRiskScore is an insurer-side actuarial signal;
    // it must NOT be displayed to the member (legal + UX risk).
    final totalAlerts7d =
        (s.anomalyBreakdown['severe'] ?? 0) +
        (s.anomalyBreakdown['moderate'] ?? 0) +
        (s.anomalyBreakdown['mild'] ?? 0);
    final severeCount = s.anomalyBreakdown['severe'] ?? 0;
    final moderateCount = s.anomalyBreakdown['moderate'] ?? 0;
    final mildCount = totalAlerts7d - severeCount - moderateCount;

    String alertSummary;
    Color alertColor;
    IconData alertIcon;
    if (totalAlerts7d == 0) {
      alertSummary = 'No alerts in the last 7 days';
      alertColor = kGreen;
      alertIcon = Icons.check_circle_outline;
    } else if (severeCount > 0) {
      alertSummary = '$severeCount severe · $moderateCount moderate · $mildCount mild (last 7 days)';
      alertColor = kRed;
      alertIcon = Icons.warning_amber_rounded;
    } else if (moderateCount > 0) {
      alertSummary = '$moderateCount moderate · $mildCount mild (last 7 days)';
      alertColor = kOrange;
      alertIcon = Icons.info_outline;
    } else {
      alertSummary = '$mildCount mild ${mildCount == 1 ? 'alert' : 'alerts'} in the last 7 days';
      alertColor = kAmber;
      alertIcon = Icons.info_outline;
    }

    return Column(
      children: [
        // Minimalist status card — sync time + alert summary, no score.
        _Card(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(alertIcon, size: 22, color: alertColor),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      alertSummary,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: alertColor,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Round-11: tier badge wired in here.  Replaces the
              // retired ABI score circle with a "what data depth do I
              // have today" affordance — Basic / Comprehensive /
              // Setting up.  Tap reveals active metrics + upgrade hint.
              _AbiTierBadge(insight: s),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.sync, size: 13, color: Colors.grey.shade400),
                  const SizedBox(width: 4),
                  Text(
                    'Last synced ${relativeTime(s.fetchedAt)}',
                    style: const TextStyle(fontSize: 11.5, color: kTextSecondary),
                  ),
                  const Spacer(),
                  Text(
                    'Risk tab → details',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                  ),
                ],
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

  // Round-11: removed the dead ``_showHriExplanation`` modal (the
  // "What is ABI?" tooltip), ``_hriColor``, and ``_hriDescription``
  // helpers.  v4.6 retired the ABI score circle from the home card,
  // and round-11 retired the term "ABI" from member-facing copy
  // (Option B in the round-11 plan: keep tier signal, drop the
  // opaque 0-100 number).  flutter analyze had been flagging these
  // three as ``unused_element`` since round-9 — now actually deleted.

  String _formatMetric(String m) {
    // Use MetricDisplay as the single source of truth for the user-facing label.
    final label = MetricDisplay.label(m);
    return label.isEmpty ? m : label;
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
  const _ConnectionBadge({required this.apiOnline});

  @override
  Widget build(BuildContext context) {
    final isOnline = apiOnline == true;
    final isChecking = apiOnline == null;
    final color = isChecking ? kAmber : (isOnline ? kGreen : kRed);
    final label = isChecking
        ? 'Checking server…'
        : isOnline
            ? 'TikCare server connected'
            : 'Cannot reach server';

    // Round-11: dropped the trailing refresh icon.  Tapping it called
    // _checkApi (just pings /health) which the user perceived as a
    // sync trigger — and on the next sync the connection check happens
    // implicitly anyway, so the manual trigger added nothing.
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
  const _StaleSyncWarning();

  @override
  Widget build(BuildContext context) {
    // Round-11: dropped the trailing "Sync now" button.  The compact
    // sync card directly below has the canonical action.
    return Row(
      children: const [
        Icon(Icons.warning_amber_rounded, size: 14, color: kAmber),
        SizedBox(width: 5),
        Expanded(
          child: Text(
            'Data may be outdated — last sync was over 24 hours ago.',
            style: TextStyle(fontSize: 12, color: kAmber),
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
  // (icon, label, key — must match keys passed via `active`)
  static const _metrics = <(IconData, String, String)>[
    (Icons.favorite, 'Heart Rate', 'hr'),
    (Icons.monitor_heart, 'HRV', 'hrv'),
    (Icons.directions_walk, 'Steps', 'steps'),
    (Icons.water_drop, 'Blood O₂', 'spo2'),
    (Icons.favorite_border, 'Resting HR', 'rhr'),
    (Icons.timer_outlined, 'Exercise Time', 'exercise'),
    (Icons.bedtime, 'Sleep', 'sleep'),
    (Icons.air, 'Resp. Rate*', 'resp'),
  ];

  final Set<String> active;

  const _WhatWeSyncChips({this.active = const <String>{}});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: _metrics.map((m) {
            final isActive = active.contains(m.$3);
            final bgColor = isActive ? const Color(0xFFEEF2FF) : const Color(0xFFF1F3F5);
            final fgColor = isActive ? kNavy : Colors.grey.shade500;
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(m.$1, size: 12, color: fgColor),
                  const SizedBox(width: 4),
                  Text(
                    m.$2,
                    style: TextStyle(fontSize: 11, color: fgColor, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            );
          }).toList(),
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
  final Set<String> activeMetrics;
  final VoidCallback onSync;
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
    this.activeMetrics = const <String>{},
    required this.onSync,
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
            const _StaleSyncWarning(),
          ],

          // Round-11: removed the inline "Retry" link that appeared
          // above the bottom Sync Now button when last sync failed.
          // Two buttons stacked (one small "Retry", one big "Sync Now")
          // both calling _runSync was the visual redundancy the round-11
          // audit flagged.  Bottom Sync Now is the only retry path now.

          // ── Expanded details ──
          if (_expanded) ...[
            const Divider(height: 20, color: kBorderColor),
            _ConnectionBadge(apiOnline: widget.apiOnline),
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
            _WhatWeSyncChips(active: widget.activeMetrics),
          ],

          // ── Sync button — always visible at the bottom of the card ──
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: widget.syncing ? null : widget.onSync,
                borderRadius: BorderRadius.circular(10),
                splashColor: Colors.white24,
                child: Ink(
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
  const _CacheBanner({required this.cachedAt});

  @override
  Widget build(BuildContext context) {
    // Round-11: removed the GestureDetector + chevron + "tap to sync"
    // affordance.  The bottom Sync Now button is the canonical action;
    // this banner is now purely informational about cache age.
    return Container(
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
              'Showing cached data from ${relativeTime(cachedAt)}',
              style: TextStyle(
                fontSize: 12,
                color: Colors.amber.shade800,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
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
                    _stepRow('4', 'Find "Vitametric" and turn on all categories'),
                    _stepRow('5', 'Come back here — sync starts automatically'),
                  ] else ...[
                    _stepRow('1', 'Open Health Connect'),
                    _stepRow('2', 'Go to "App permissions"'),
                    _stepRow('3', 'Find "Vitametric"'),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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
          // Copy-diagnostic affordance — testers paste this into bug reports
          // so we can triage without console access.
          if (widget.errorType != SyncErrorType.authExpired) ...[
            const SizedBox(height: 6),
            GestureDetector(
              onTap: () async {
                final info = await HealthService.getDiagnosticInfo();
                await Clipboard.setData(ClipboardData(text: info));
                HapticFeedback.selectionClick();
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Diagnostic copied — paste in your bug report.'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Icon(Icons.copy_outlined, size: 12, color: color.withValues(alpha: 0.8)),
                  const SizedBox(width: 4),
                  Text(
                    'Copy diagnostic',
                    style: TextStyle(
                      fontSize: 11,
                      color: color.withValues(alpha: 0.8),
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// Round-11: deleted _FirstSyncBanner.  The "Connect Now" / "Reconnect"
// banner duplicated the bottom Sync Now button and lingered after every
// failed first sync.

// ── ABI Tier Badge ────────────────────────────────────────────────────────────
/// Tier badge — Basic tracking / Comprehensive tracking / Setting up.
///
/// Shows the tier label as a pill plus a one-line explainer. All tiers are
/// tappable: Base shows an upgrade hint, Comprehensive shows what advanced
/// signals are active, Accumulating explains the 14-day requirement.
class _AbiTierBadge extends StatelessWidget {
  final RiskInsight insight;
  const _AbiTierBadge({required this.insight});

  // grey.shade400 extracted to a const so the chevron Icon can be const.
  static const Color _kChevronGrey = Color(0xFFBDBDBD);

  @override
  Widget build(BuildContext context) {
    final tier = AbiTierDisplay.parse(insight.abiTier);
    final isEarly = insight.dataAdequacyStage == 'early';
    final bg = AbiTierDisplay.badgeBackground(tier);
    final fg = AbiTierDisplay.badgeForeground(tier);

    return Semantics(
      button: true,
      label: '${AbiTierDisplay.label(tier)}. '
          '${AbiTierDisplay.explainer(tier, earlyStage: isEarly)}'
          '${isEarly ? '. Early stage — baseline still building.' : ''}',
      child: GestureDetector(
        onTap: () => _showTierDetails(context, tier, isEarly),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                AbiTierDisplay.label(tier),
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: fg,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                AbiTierDisplay.explainer(tier, earlyStage: isEarly),
                style: const TextStyle(
                  fontSize: 10.5,
                  color: kTextSecondary,
                  fontWeight: FontWeight.w500,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.chevron_right, size: 16, color: _kChevronGrey),
          ],
        ),
      ),
    );
  }

  void _showTierDetails(BuildContext context, AbiTier tier, bool isEarly) {
    final (title, body, footer) = switch (tier) {
      AbiTier.base => _baseUpgradeContent(),
      AbiTier.comprehensive => _comprehensiveDetailsContent(isEarly),
      AbiTier.accumulating => _accumulatingDetailsContent(),
    };

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              body,
              style: const TextStyle(fontSize: 13.5, color: kTextSecondary),
            ),
            if (footer != null) ...[
              const SizedBox(height: 12),
              Text(
                footer,
                style: const TextStyle(
                  fontSize: 12,
                  color: kTextSecondary,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(sheetContext).pop(),
                child: const Text('Got it'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  (String, String, String?) _baseUpgradeContent() {
    // Round-19: rewrite from the misleading "you need ALL these metrics
    // from one device" listicle into per-device-class guidance.
    //
    // Three things were wrong with the old copy:
    //   1. It listed every missing comprehensive metric (HRV / SpO₂ /
    //      VO₂ Max / AFib / BP-Sys / BP-Dia / Exercise / Resp Rate) as
    //      if all were required. In reality the backend tier upgrades
    //      as soon as ANY ONE of them lands — see
    //      app/core/reporting/daily.py:_classify_abi_tier.
    //   2. The "Compatible: Apple Watch, Garmin, Withings, Polar" footer
    //      lumped a wrist-worn watch and a stand-alone BP cuff into one
    //      bucket. They unlock different metrics — Withings does BP, the
    //      others do HRV / SpO₂ / VO₂ Max — and a member who already
    //      owns an Apple Watch shouldn't be told to "buy a Withings"
    //      to get comprehensive insights.
    //   3. AFib detection requires Apple Watch S4+ specifically, not a
    //      generic "smartwatch" — calling it out separately matters
    //      because the device cohort that already has AFib (Series 1-3
    //      owners) wouldn't be able to upgrade by re-pairing.
    final missing = insight.abiMissingForUpgrade.toSet();
    // Bucket missing metrics by which device class typically provides them.
    final wristMetrics = <String>{
      'HRV_SDNN', 'HRV_RMSSD', 'SPO2_INSTANT', 'VO2_MAX',
      'EXERCISE_TIME', 'RESP_RATE',
    }.intersection(missing);
    final cuffMetrics = <String>{
      'BP_SYSTOLIC', 'BP_DIASTOLIC',
    }.intersection(missing);
    final watchMetrics = <String>{'AFIB_FLAG'}.intersection(missing);

    final body = StringBuffer(
      'You\'ll move to comprehensive tracking as soon as ANY ONE '
      'of these advanced signals starts coming in:\n',
    );
    if (wristMetrics.isNotEmpty) {
      final names = wristMetrics
          .map((m) => MetricDisplay.meta(m).label)
          .join(', ');
      body.write('\n• $names — most modern wrist wearables '
          '(Apple Watch S4+, Garmin, Polar, Fitbit Sense / Charge 5+).');
    }
    if (watchMetrics.isNotEmpty) {
      body.write('\n• AFib Detection — Apple Watch S4 or later '
          '(or any FDA-cleared ECG wearable).');
    }
    if (cuffMetrics.isNotEmpty) {
      body.write('\n• Blood Pressure — a connected cuff like '
          'Withings BPM or Omron Connect.');
    }
    if (wristMetrics.isEmpty && watchMetrics.isEmpty && cuffMetrics.isEmpty) {
      // Fallback when every comprehensive signal is already active —
      // shouldn't reach this branch (would mean the tier is already
      // comprehensive), but guard the copy just in case.
      body.write('\nConnect any wearable that provides HRV, SpO₂ or '
          'VO₂ Max to upgrade.');
    }
    return (
      'Upgrade to comprehensive tracking',
      body.toString(),
      'You only need ONE of the above — not all of them. Adding more '
      'devices later refines the signal mix.',
    );
  }

  (String, String, String?) _comprehensiveDetailsContent(bool isEarly) {
    final active = insight.abiActiveMetrics;
    final friendly = active
        .take(8)
        .map((m) => MetricDisplay.meta(m).label)
        .join(', ');
    final earlyNote = isEarly
        ? ' Your baseline is still maturing (early stage), so day-to-day swings may be larger than usual until you reach 30 days of data.'
        : '';
    return (
      'Comprehensive tracking',
      active.isEmpty
          ? 'Your insights are computed from advanced signals like HRV, SpO₂, and VO₂ Max alongside heart rate and sleep.$earlyNote'
          : 'Your insights are computed from these signals today: $friendly.$earlyNote',
      'Personal-baseline insights are an engagement signal, not an insurance underwriting input.',
    );
  }

  (String, String, String?) _accumulatingDetailsContent() {
    final days = insight.daysWithData;
    final remaining = (14 - days).clamp(1, 14);
    return (
      'Building Your Baseline',
      'We need at least 14 days of data to compute meaningful insights. '
          'Once your personal baseline is established, you\'ll see how today compares to your norm.\n\n'
          '$days day${days == 1 ? '' : 's'} collected · $remaining more to go.',
      'Keep your wearable on overnight to accelerate baseline maturity.',
    );
  }
}

// Round-11: deleted _HriScaleBar — the 0-100 score bar was wired into the
// retired `_showHriExplanation` modal that round-11 also removed.

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
                  'Personalized health insights require a wearable device such as Apple Watch Series 5+ or later. '
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

// Round-11: deleted _HriBandRow — wired only into the retired
// `_showHriExplanation` modal.
// Round-18: deleted _SignalsPlaceholder — its only callers (the standalone
// Today's Signals section) were folded into _UnifiedHealthSection, which
// renders one tile per metric with its own per-tile "no data" / "no
// baseline" handling.
