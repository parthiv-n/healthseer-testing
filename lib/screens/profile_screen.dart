import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/health_service.dart';
import '../models/daily_report.dart';

const _navy = Color(0xFF1B3A6B);
const _navyLight = Color(0xFF2A5298);
const _bg = Color(0xFFF7F9FC);

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
  bool _showDebugLog = false;
  bool _testing = false;
  bool? _testSuccess;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final email = await HealthService.getLoggedInEmail();
    final prefs = await SharedPreferences.getInstance();
    final showLog = prefs.getBool('show_debug_log') ?? false;
    final results = await Future.wait([
      HealthService.fetchUserProfile(),
      HealthService.fetchDailyReport(),
    ]);
    if (mounted) {
      setState(() {
        _email = email;
        _showDebugLog = showLog;
        _profile = results[0] as Map<String, dynamic>?;
        _dailyReport = results[1] as DailyReport?;
      });
    }
  }

  Future<void> _toggleDebugLog(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('show_debug_log', value);
    if (mounted) setState(() => _showDebugLog = value);
  }

  Future<void> _testConnection() async {
    setState(() { _testing = true; _testSuccess = null; });
    final result = await HealthService.pingLifePulse();
    if (mounted) setState(() { _testing = false; _testSuccess = result.success; });
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
      backgroundColor: _bg,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 100,
            pinned: true,
            backgroundColor: _navy,
            automaticallyImplyLeading: false,
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
                            gradient: LinearGradient(colors: [_navy, _navyLight]),
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
                                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: _navy),
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
                                child: const Text('TikCare Member', style: TextStyle(fontSize: 10, color: _navy, fontWeight: FontWeight.w600)),
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
                        _InfoRow(icon: Icons.shield_outlined, label: 'Data shared with TikCare', value: 'Heart Rate, HRV, Steps, SpO2, Active & Basal Energy, Resting HR, Distance, Floors Climbed, Exercise Time, Sleep, Resp. Rate (S6+)'),
                        const Divider(height: 20),
                        _InfoRow(icon: Icons.lock_outline, label: 'Data use', value: 'Health risk scoring & anomaly detection only'),
                        const Divider(height: 20),
                        _InfoRow(icon: Icons.visibility_off_outlined, label: 'Not shared', value: 'GPS location, contacts, photos'),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Health Profile Maturity
                  if (_dailyReport != null)
                    _MaturityCard(report: _dailyReport!),

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
                            const Expanded(child: Text('LifePulse API', style: TextStyle(fontSize: 13))),
                            if (_testing)
                              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: _navy))
                            else if (_testSuccess == true)
                              const Icon(Icons.check_circle, size: 16, color: Color(0xFF38A169))
                            else if (_testSuccess == false)
                              const Icon(Icons.error_outline, size: 16, color: Colors.red),
                            const SizedBox(width: 8),
                            GestureDetector(
                              onTap: _testing ? null : _testConnection,
                              child: const Text('Test', style: TextStyle(fontSize: 12, color: _navy, fontWeight: FontWeight.w600)),
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
                              activeThumbColor: _navy,
                              activeTrackColor: _navy.withValues(alpha: 0.4),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // DEV ONLY: Clear My Data
                  Container(
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

                  const SizedBox(height: 12),
                  const Text('TikCare LifePulse v1.0', style: TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              ),
            ),
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
              Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: _navy)),
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
          const Color(0xFF38A169),
        ),
      'developing' => (
          'Developing',
          '$days of 30 days synced. Keep syncing daily to improve accuracy.',
          days / 30.0,
          const Color(0xFFD97706),
        ),
      _ => (
          'Building Baseline',
          '$days of 14 days synced. Sync daily so TikCare can learn your patterns.',
          days / 14.0,
          const Color(0xFF2A5298),
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
