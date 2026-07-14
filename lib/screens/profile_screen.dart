import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/health_service.dart';
import '../services/sync_state.dart';
import '../services/sync_telemetry.dart';
import '../models/daily_report.dart';
import '../theme/colors.dart';

class ProfileScreen extends StatefulWidget {
  final SharedPreferences prefs;
  const ProfileScreen({super.key, required this.prefs});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  String? _email;
  Map<String, dynamic>? _profile;
  DailyReport? _dailyReport;
  bool _loadingProfile = true;
  bool _profileLoadError = false;
  bool _showDebugLog = false;
  bool _testing = false;
  bool _resyncingHistorical = false;
  bool? _testSuccess;

  // Sync history (last sync only — stored by HomeScreen)
  String? _lastSyncTime;
  int? _lastSyncEventCount;
  bool? _lastSyncSuccess;
  List<String> _lastSyncDevices = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loadingProfile = true; _profileLoadError = false; });
    try {
      final email = await HealthService.getLoggedInEmail();
      final prefs = await SharedPreferences.getInstance();
      final showLog = prefs.getBool('show_debug_log') ?? false;
      // Track B: load sync state from SyncStateStore — the legacy
      // SharedPrefs keys (last_sync_time / last_event_count /
      // last_sync_success) are deleted by migrate() and would all
      // return null for any upgraded user.
      await SyncStateStore.instance.load();
      final syncState = SyncStateStore.instance.value;
      String? successLabel;
      if (syncState.lastSuccessAtIso != null) {
        final dt = DateTime.tryParse(syncState.lastSuccessAtIso!);
        if (dt != null) {
          final hh = dt.hour.toString().padLeft(2, '0');
          final mm = dt.minute.toString().padLeft(2, '0');
          successLabel = '${dt.month}/${dt.day} $hh:$mm';
        }
      }
      final results = await Future.wait([
        HealthService.fetchUserProfile(),
        HealthService.fetchDailyReport(),
      ]);
      if (mounted) {
        setState(() {
          _loadingProfile = false;
          _email = email;
          _showDebugLog = showLog;
          _profile = results[0] as Map<String, dynamic>?;
          _dailyReport = results[1] as DailyReport?;
          _lastSyncTime = successLabel;
          _lastSyncEventCount = syncState.lastEventCount;
          _lastSyncSuccess = syncState.lastAttemptAtIso == null
              ? null
              : !syncState.lastAttemptFailed;
          _lastSyncDevices = prefs.getStringList('last_sync_devices') ?? [];
        });
      }
    } catch (e) {
      debugPrint('[ProfileScreen._load] $e');
      if (mounted) setState(() { _loadingProfile = false; _profileLoadError = true; });
    }
  }

  Future<void> _toggleDebugLog(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('show_debug_log', value);
    if (mounted) setState(() => _showDebugLog = value);
  }

  Future<void> _resyncHistorical() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(children: [
          Icon(Icons.history, color: kNavy, size: 20),
          SizedBox(width: 8),
          Text('Re-sync Historical Data', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        ]),
        content: Text(
          'This will re-upload the last ${HealthService.kHistoricalSyncDays} days from Apple Health to fill any gaps. It runs in weekly chunks so it\'s safe to interrupt — progress is saved.\n\nDuplicate data is automatically filtered.',
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Re-sync', style: TextStyle(color: kNavy, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _resyncingHistorical = true);
    final result = await HealthService.syncDirect(
      forceFullResync: true,
      syncPath: SyncPath.historical,
    );
    if (!mounted) return;
    setState(() => _resyncingHistorical = false);

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(result.success
          ? 'Historical re-sync complete. New data will appear shortly.'
          : 'Re-sync failed: ${result.message}'),
      backgroundColor: result.success ? Colors.green : Colors.red,
    ));
  }

  Future<void> _clearMyData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(children: [
          Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 20),
          SizedBox(width: 8),
          Text('Clear My Health Data', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        ]),
        content: const Text(
          'This will permanently delete all your synced health data, baselines, and anomaly history.\n\nYour account will remain. Use this to reset between test runs.',
          style: TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete All Data', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final result = await HealthService.clearMyData();
    if (!mounted) return;
    if (result != null) {
      final deleted = result['deleted'] as Map<String, dynamic>? ?? {};
      final events = (deleted['canonical_events'] as int?) ?? 0;
      final anomalies = (deleted['anomalies'] as int?) ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Cleared: $events events, $anomalies anomalies'),
        backgroundColor: Colors.green,
      ));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Failed to clear data. Check your connection.'),
        backgroundColor: Colors.red,
      ));
    }
  }

  Future<void> _testConnection() async {
    setState(() { _testing = true; _testSuccess = null; });
    final result = await HealthService.pingVitametric();
    if (mounted) setState(() { _testing = false; _testSuccess = result.success; });
  }

  Future<void> _deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(children: [
          Icon(Icons.warning_amber_rounded, color: Colors.red, size: 20),
          SizedBox(width: 8),
          Text('Delete Account', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        ]),
        content: const Text(
          'This will permanently delete your account and all associated health data.\n\nThis action cannot be undone.',
          style: TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete Account', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final success = await HealthService.deleteAccount();
    if (!mounted) return;
    if (success) {
      try {
        await HealthService.clearAllCaches();
        await HealthService.logout();
      } catch (_) { /* best-effort */ }
      if (mounted) Navigator.pushNamedAndRemoveUntil(context, '/login', (_) => false);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Unable to delete account. Please contact support@tikcare.co.'),
        backgroundColor: Colors.red,
      ));
    }
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Sign Out', style: TextStyle(fontWeight: FontWeight.w700)),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign Out', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await HealthService.clearAllCaches();
      await HealthService.logout();
      if (mounted) Navigator.pushNamedAndRemoveUntil(context, '/login', (_) => false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final firstName = _profile?['first_name'] as String? ?? '';
    final lastName = _profile?['last_name'] as String? ?? '';
    final displayName = [firstName, lastName].where((s) => s.isNotEmpty).join(' ');

    return Scaffold(
      backgroundColor: kBg,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 100,
            pinned: true,
            backgroundColor: kNavy,
            automaticallyImplyLeading: false,
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
                        Text('My Profile', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700)),
                        SizedBox(height: 2),
                        Text('Account & settings', style: TextStyle(color: Colors.white60, fontSize: 13)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_loadingProfile)
            const SliverFillRemaining(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: kNavy, strokeWidth: 2),
                    SizedBox(height: 16),
                    Text('Loading profile…', style: TextStyle(fontSize: 13, color: Colors.grey)),
                  ],
                ),
              ),
            )
          else if (_profileLoadError)
            SliverFillRemaining(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_off_outlined, size: 48, color: Colors.grey),
                      const SizedBox(height: 16),
                      const Text(
                        'Could not load profile',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: kNavy),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Check your connection and try again.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, color: Colors.grey),
                      ),
                      const SizedBox(height: 20),
                      ElevatedButton.icon(
                        onPressed: _load,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('Retry'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: kNavy,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
              child: Column(
                children: [
                  // Avatar + name
                  _Card(
                    child: Row(
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(colors: [kNavy, kNavyLight]),
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: Text(
                              _email?.isNotEmpty == true ? _email![0].toUpperCase() : '?',
                              style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700),
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                displayName.isNotEmpty ? displayName : (_email ?? 'Member'),
                                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: kNavy),
                              ),
                              if (_email != null)
                                Text(_email!, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                              const SizedBox(height: 4),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFEEF2FF),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Text('TikCare Member', style: TextStyle(fontSize: 10, color: kNavy, fontWeight: FontWeight.w600)),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Data Transparency
                  _Card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _SectionLabel(label: 'DATA & PRIVACY'),
                        const SizedBox(height: 12),
                        _InfoRow(icon: Icons.shield_outlined, label: 'Data shared with TikCare', value: 'Heart Rate, HRV, Steps, SpO₂, Resting HR, Exercise Time, Sleep, Resp. Rate*, Blood Pressure, AFib History\n*Resp. Rate requires Apple Watch Series 6+'),
                        const Divider(height: 20),
                        _InfoRow(icon: Icons.lock_outline, label: 'Data use', value: 'Health risk scoring & anomaly detection only'),
                        const Divider(height: 20),
                        _InfoRow(icon: Icons.visibility_off_outlined, label: 'Not shared', value: 'GPS location, contacts, photos'),
                        const Divider(height: 20),
                        GestureDetector(
                          onTap: () async {
                            final uri = Uri.parse('https://tikcare.co/privacy-policy/');
                            if (await canLaunchUrl(uri)) {
                              await launchUrl(uri, mode: LaunchMode.externalApplication);
                            }
                          },
                          child: const Row(
                            children: [
                              Icon(Icons.policy_outlined, size: 16, color: Colors.grey),
                              SizedBox(width: 10),
                              Expanded(child: Text('Privacy Policy', style: TextStyle(fontSize: 13, color: kNavy))),
                              Icon(Icons.open_in_new, size: 14, color: Colors.grey),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Health Profile Maturity
                  if (_dailyReport != null)
                    _MaturityCard(report: _dailyReport!),

                  const SizedBox(height: 12),

                  // Sync History
                  if (_lastSyncTime != null)
                    _SyncHistoryCard(
                      lastSyncTime: _lastSyncTime!,
                      eventCount: _lastSyncEventCount,
                      success: _lastSyncSuccess ?? false,
                      devices: _lastSyncDevices,
                    ),

                  if (_lastSyncTime != null) const SizedBox(height: 12),

                  // Re-sync historical data
                  _Card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _SectionLabel(label: 'HISTORICAL DATA'),
                        const SizedBox(height: 8),
                        Text(
                          'Missing past health data? Re-sync uploads the last ${HealthService.kHistoricalSyncDays} days from Apple Health to fill any gaps.',
                          style: const TextStyle(fontSize: 12, color: Colors.grey, height: 1.4),
                        ),
                        const SizedBox(height: 12),
                        ValueListenableBuilder<String?>(
                          valueListenable: HealthService.historicalSyncProgress,
                          builder: (_, progress, __) {
                            final label = progress ?? (_resyncingHistorical ? 'Starting…' : 'Re-sync Historical Data');
                            final busy = _resyncingHistorical;
                            return SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: busy ? null : _resyncHistorical,
                                icon: busy
                                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                                    : const Icon(Icons.history, size: 16),
                                label: Text(label),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: kNavy,
                                  side: const BorderSide(color: kNavy),
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Server & Debug
                  _Card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _SectionLabel(label: 'CONNECTION'),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            const Icon(Icons.cloud_outlined, size: 16, color: Colors.grey),
                            const SizedBox(width: 8),
                            const Expanded(child: Text('Vitametric API', style: TextStyle(fontSize: 13))),
                            if (_testing)
                              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: kNavy))
                            else if (_testSuccess == true)
                              const Icon(Icons.check_circle, size: 16, color: kGreen)
                            else if (_testSuccess == false)
                              const Icon(Icons.error_outline, size: 16, color: Colors.red),
                          ],
                        ),
                        // Dev-only: API test button + sync log toggle
                        if (kDebugMode) ...[
                          const Divider(height: 20),
                          Row(
                            children: [
                              const Icon(Icons.bug_report_outlined, size: 16, color: Colors.grey),
                              const SizedBox(width: 8),
                              GestureDetector(
                                onTap: _testing ? null : _testConnection,
                                child: const Text('Test Connection', style: TextStyle(fontSize: 12, color: kNavy, fontWeight: FontWeight.w600)),
                              ),
                            ],
                          ),
                          const Divider(height: 20),
                          Row(
                            children: [
                              const Icon(Icons.terminal, size: 16, color: Colors.grey),
                              const SizedBox(width: 8),
                              const Expanded(child: Text('Show Sync Log', style: TextStyle(fontSize: 13))),
                              Switch.adaptive(
                                value: _showDebugLog,
                                onChanged: _toggleDebugLog,
                                activeThumbColor: kNavy,
                                activeTrackColor: kNavy.withValues(alpha: 0.4),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // DEV ONLY — hidden in release/TestFlight/App Store builds.
                  if (kDebugMode) Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.orange.shade200),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(children: [
                          Icon(Icons.science_outlined, size: 14, color: Colors.orange),
                          SizedBox(width: 6),
                          Text('DEV / TESTING', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.orange, letterSpacing: 0.8)),
                        ]),
                        const SizedBox(height: 8),
                        const Text(
                          'Reset your health data between test runs with your Apple Watch.',
                          style: TextStyle(fontSize: 12, color: Colors.black54, height: 1.4),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.orange.shade700,
                              side: BorderSide(color: Colors.orange.shade300),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            onPressed: _clearMyData,
                            icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                            label: const Text('Clear All My Health Data', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.orange.shade700,
                              side: BorderSide(color: Colors.orange.shade300),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            onPressed: () => Navigator.of(context).pushNamed('/dev-tools'),
                            icon: const Icon(Icons.build_outlined, size: 16),
                            label: const Text('Developer Tools', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Sign out
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                        side: const BorderSide(color: Colors.red),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      onPressed: _logout,
                      icon: const Icon(Icons.logout, size: 18),
                      label: const Text('Sign Out', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                    ),
                  ),

                  const SizedBox(height: 8),
                  // Account deletion — required by App Store guidelines
                  Center(
                    child: TextButton(
                      onPressed: _deleteAccount,
                      child: const Text(
                        'Delete Account',
                        style: TextStyle(fontSize: 12, color: Colors.red),
                      ),
                    ),
                  ),

                  const SizedBox(height: 4),
                  // Long-press the version label to reach the hidden Dev Tools
                  // screen (on-device sync verification). Version string is
                  // derived from BuildMetadata (CFBundle values) rather than a
                  // hard-coded literal so it never drifts from the real build.
                  GestureDetector(
                    onLongPress: () =>
                        Navigator.of(context).pushNamed('/dev-tools'),
                    behavior: HitTestBehavior.opaque,
                    child: Text(
                      'Vitametric v${BuildMetadata.version} (${BuildMetadata.build})',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
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

// ── Sync History Card ─────────────────────────────────────────────────────────

class _SyncHistoryCard extends StatelessWidget {
  final String lastSyncTime;
  final int? eventCount;
  final bool success;
  final List<String> devices;

  const _SyncHistoryCard({
    required this.lastSyncTime,
    required this.eventCount,
    required this.success,
    required this.devices,
  });

  @override
  Widget build(BuildContext context) {
    final color = success ? kGreen : kRed;
    final deviceLabel = devices.isEmpty
        ? 'No devices recorded'
        : devices.length == 1
            ? devices.first
            : '${devices.first} + ${devices.length - 1} more';

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionLabel(label: 'LAST SYNC'),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(
                success ? Icons.check_circle_outline : Icons.error_outline,
                size: 15,
                color: color,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  success ? 'Completed · $lastSyncTime' : 'Failed · $lastSyncTime',
                  style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          if (eventCount != null && success) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.upload_outlined, size: 15, color: Colors.grey),
                const SizedBox(width: 8),
                Text('$eventCount health events uploaded', style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
          ],
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(Icons.watch_outlined, size: 15, color: Colors.grey),
              const SizedBox(width: 8),
              Expanded(
                child: Text(deviceLabel, style: const TextStyle(fontSize: 12, color: Colors.grey), overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: child,
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.grey, letterSpacing: 0.8));
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _InfoRow({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 15, color: Colors.grey),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 2),
              Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: kNavy)),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Health Profile Maturity Card ──────────────────────────────────────────────

class _MaturityCard extends StatelessWidget {
  final DailyReport report;
  const _MaturityCard({required this.report});

  @override
  Widget build(BuildContext context) {
    final maturity = report.baselineMaturity;
    final days = report.daysWithData;
    final estDate = report.estimatedEstablishedDate;

    final (label, description, progress, color) = switch (maturity) {
      'established' => (
          'Established',
          'Your personal health baseline is fully built.',
          1.0,
          kGreen,
        ),
      'developing' => (
          'Developing',
          '${days.clamp(0, 30)} of 30 days synced. Keep syncing daily to improve accuracy.',
          days / 30.0,
          kAmber,
        ),
      _ => (
          'Building Baseline',
          '${days.clamp(0, 14)} of 14 days synced. Sync daily so TikCare can learn your patterns.',
          days / 14.0,
          kNavyLight,
        ),
    };

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionLabel(label: 'HEALTH PROFILE MATURITY'),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(
                maturity == 'established'
                    ? Icons.verified_outlined
                    : Icons.hourglass_top_outlined,
                size: 16,
                color: color,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: color),
              ),
              const Spacer(),
              Text(
                '${(report.avgConfidence * 100).toStringAsFixed(0)}% confidence',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: Colors.grey.shade200,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          const SizedBox(height: 8),
          Text(description, style: const TextStyle(fontSize: 12, color: Colors.grey, height: 1.4)),
          if (maturity != 'established' && estDate != null) ...[
            const SizedBox(height: 4),
            Text(
              'Estimated ready: $estDate',
              style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w500),
            ),
          ],
        ],
      ),
    );
  }
}
