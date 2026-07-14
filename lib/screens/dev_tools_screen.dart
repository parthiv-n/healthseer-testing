import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/census_report.dart';
import '../services/census_compare.dart';
import '../services/health_census.dart';
import '../services/health_service.dart';
import '../services/sync_attempt_history.dart';
import '../services/sync_state.dart';
import '../theme/colors.dart';

/// Hidden on-device sync-verification screen. Reached by long-pressing the
/// version label on the Profile tab (and via a visible tile in the debug-only
/// dev section). Answers "does what HealthKit holds match what the pipeline
/// stored?" entirely on-device, plus a live verbose sync console and the
/// low-level sync state / API URL knobs.
///
/// Route: '/dev-tools' (registered in main.dart).
class DevToolsScreen extends StatefulWidget {
  const DevToolsScreen({super.key});

  @override
  State<DevToolsScreen> createState() => _DevToolsScreenState();
}

/// SharedPreferences key for the persisted verbose sync-log ring buffer, so
/// the console survives navigating away from and back to the screen.
const String kDevSyncLogPrefsKey = 'dev_sync_log_ring_v1';

/// Cap on the persisted verbose sync-log ring buffer.
const int _kSyncLogRingCap = 200;

/// Theme-appropriate colour for a compare status.
Color compareStatusColor(CompareStatus status) {
  switch (status) {
    case CompareStatus.ok:
      return kGreen;
    case CompareStatus.warn:
      return kAmber;
    case CompareStatus.fail:
      return kRed;
  }
}

class _DevToolsScreenState extends State<DevToolsScreen> {
  // ── Census card ──────────────────────────────────────────────────────────
  CensusReport? _census;
  final List<String> _censusLog = [];
  bool _censusRunning = false;
  String? _censusError;

  // ── Reconciliation card ──────────────────────────────────────────────────
  List<CompareRow>? _compareRows;
  bool _reconLoading = false;
  String? _reconError;

  // ── Sync log card ────────────────────────────────────────────────────────
  bool _showDebugLog = false;
  final List<String> _syncLog = [];
  bool _syncRunning = false;
  final ScrollController _consoleController = ScrollController();

  // ── Sync state card ──────────────────────────────────────────────────────
  SyncState _syncState = SyncState.empty;
  List<SyncAttemptRecord> _attempts = const [];
  Map<String, String>? _serverAnchors;
  bool _anchorsLoading = false;
  String? _anchorsError;

  // ── API URL card ─────────────────────────────────────────────────────────
  final TextEditingController _urlController = TextEditingController();
  String? _urlError;
  String _effectiveBaseUrl = kDefaultApiUrl;

  @override
  void initState() {
    super.initState();
    _preload();
  }

  @override
  void dispose() {
    _consoleController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  /// All work here is local (SharedPreferences / in-memory stores) — no
  /// network — so the screen opens instantly and is widget-testable without
  /// a mocked HTTP client.
  Future<void> _preload() async {
    final prefs = await SharedPreferences.getInstance();

    final census = await HealthCensus.loadLastCensus();

    await SyncStateStore.instance.load();
    final state = SyncStateStore.instance.value;

    final attempts = await SyncAttemptHistory.load();

    final showLog = prefs.getBool('show_debug_log') ?? false;
    final ring = prefs.getStringList(kDevSyncLogPrefsKey) ?? const [];
    final baseUrl = prefs.getString('lp_api_url') ?? kDefaultApiUrl;

    if (!mounted) return;
    setState(() {
      _census = census;
      _syncState = state;
      _attempts = attempts;
      _showDebugLog = showLog;
      _syncLog
        ..clear()
        ..addAll(ring);
      _effectiveBaseUrl = baseUrl;
      _urlController.text = baseUrl;
    });
  }

  // ── Census ───────────────────────────────────────────────────────────────
  Future<void> _runCensus() async {
    setState(() {
      _censusRunning = true;
      _censusError = null;
      _censusLog.clear();
    });
    try {
      final report = await HealthCensus.runCensus(
        onProgress: (line) {
          if (!mounted) return;
          // Surface every progress line verbatim — including any chunk error
          // lines runCensus emits — so a partial census is visibly partial.
          setState(() => _censusLog.add(line));
        },
      );
      if (!mounted) return;
      setState(() => _census = report);
    } catch (e) {
      if (!mounted) return;
      setState(() => _censusError = '$e');
    } finally {
      if (mounted) setState(() => _censusRunning = false);
    }
  }

  // ── Reconciliation ───────────────────────────────────────────────────────
  Future<void> _fetchReconciliation() async {
    if (_census == null) return;
    setState(() {
      _reconLoading = true;
      _reconError = null;
    });
    try {
      final server = await HealthService.fetchReconciliation(days: 180);
      final rows = compareCensusToServer(_census!, server);
      if (!mounted) return;
      setState(() => _compareRows = rows);
    } catch (e) {
      if (!mounted) return;
      setState(() => _reconError = '$e');
    } finally {
      if (mounted) setState(() => _reconLoading = false);
    }
  }

  // ── Verbose sync ─────────────────────────────────────────────────────────
  Future<void> _appendSyncLog(String line) async {
    if (!mounted) return;
    setState(() {
      _syncLog.add(line);
      // Ring-buffer cap: drop oldest so the console + pref stay bounded.
      while (_syncLog.length > _kSyncLogRingCap) {
        _syncLog.removeAt(0);
      }
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(kDevSyncLogPrefsKey, _syncLog);
    } catch (_) {/* best-effort persistence */}
    // Auto-scroll to newest.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_consoleController.hasClients) {
        _consoleController.jumpTo(_consoleController.position.maxScrollExtent);
      }
    });
  }

  Future<void> _syncNow() async {
    setState(() => _syncRunning = true);
    await _appendSyncLog('── Sync started ${DateTime.now().toIso8601String()} ──');
    try {
      final result = await HealthService.syncDirect(
        onLog: (l) => _appendSyncLog(l),
      );
      await _appendSyncLog(result.success
          ? '✓ ${result.message}'
          : '✗ ${result.errorType?.name ?? "failure"}: ${result.message}');
    } catch (e) {
      await _appendSyncLog('✗ crashed: $e');
    } finally {
      // Refresh the sync-state + attempt-history cards after a run.
      await SyncStateStore.instance.load();
      final attempts = await SyncAttemptHistory.load();
      if (mounted) {
        setState(() {
          _syncRunning = false;
          _syncState = SyncStateStore.instance.value;
          _attempts = attempts;
        });
      }
    }
  }

  Future<void> _clearSyncLog() async {
    setState(() => _syncLog.clear());
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kDevSyncLogPrefsKey);
    } catch (_) {/* best-effort */}
  }

  // ── Server anchors ───────────────────────────────────────────────────────
  Future<void> _fetchAnchors() async {
    setState(() {
      _anchorsLoading = true;
      _anchorsError = null;
    });
    try {
      final anchors = await HealthService.fetchLatestEventTimes();
      if (!mounted) return;
      setState(() => _serverAnchors = anchors);
    } catch (e) {
      if (!mounted) return;
      setState(() => _anchorsError = '$e');
    } finally {
      if (mounted) setState(() => _anchorsLoading = false);
    }
  }

  // ── API URL ──────────────────────────────────────────────────────────────
  Future<void> _saveUrl() async {
    final url = _urlController.text.trim();
    if (!isAllowedApiUrl(url)) {
      setState(() => _urlError =
          'Rejected: not on the allow-list (must be https on a permitted host, '
          'or http on localhost).');
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('lp_api_url', url);
      if (!mounted) return;
      setState(() {
        _urlError = null;
        _effectiveBaseUrl = url;
      });
      _toast('Saved API URL');
    } catch (e) {
      if (!mounted) return;
      setState(() => _urlError = 'Save failed: $e');
    }
  }

  // ── Shared helpers ───────────────────────────────────────────────────────
  Future<void> _copy(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    _toast('Copied $label');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kNavy,
        foregroundColor: Colors.white,
        title: const Text('Dev Tools',
            style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildCensusCard(),
          const SizedBox(height: 14),
          _buildReconciliationCard(),
          const SizedBox(height: 14),
          _buildSyncLogCard(),
          const SizedBox(height: 14),
          _buildSyncStateCard(),
          const SizedBox(height: 14),
          _buildApiUrlCard(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // ── Card a: HealthKit Census ─────────────────────────────────────────────
  Widget _buildCensusCard() {
    final census = _census;
    final partial = census != null &&
        census.rows.any((r) => r.dropReason == 'bridge unavailable');
    return _DevCard(
      icon: Icons.fact_check_outlined,
      title: 'HealthKit Census',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (census != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Window: ${_shortDate(census.windowStart)} → '
                '${_shortDate(census.windowEnd)} · ${census.rows.length} types',
                style: const TextStyle(fontSize: 12, color: kTextSecondary),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: _PrimaryButton(
                  label: _censusRunning
                      ? 'Running census…'
                      : 'Run Census (180 days)',
                  icon: Icons.play_arrow_rounded,
                  loading: _censusRunning,
                  onPressed: _censusRunning ? null : _runCensus,
                ),
              ),
              if (census != null) ...[
                const SizedBox(width: 8),
                _SecondaryButton(
                  label: 'Copy TSV',
                  icon: Icons.copy,
                  onPressed: () => _copy(census.toTsv(), 'census TSV'),
                ),
              ],
            ],
          ),
          if (_censusLog.isNotEmpty) ...[
            const SizedBox(height: 10),
            _MonoBox(lines: _censusLog, maxHeight: 120),
          ],
          if (_censusError != null) ...[
            const SizedBox(height: 8),
            _ErrorText(_censusError!),
          ],
          if (partial) ...[
            const SizedBox(height: 8),
            Row(children: const [
              Icon(Icons.warning_amber_rounded, size: 15, color: kAmber),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Partial census — one or more native bridges were unavailable.',
                  style: TextStyle(fontSize: 11, color: kAmber),
                ),
              ),
            ]),
          ],
          if (census != null) ...[
            const SizedBox(height: 12),
            _censusTable(census),
            const SizedBox(height: 6),
            const Text(
              'Cross-chunk duplicates are not deduped; a full run may take 1–3 min.',
              style: TextStyle(
                  fontSize: 10.5,
                  color: kTextSecondary,
                  fontStyle: FontStyle.italic),
            ),
          ],
        ],
      ),
    );
  }

  Widget _censusTable(CensusReport census) {
    int totRaw = 0, totDedup = 0, totUpload = 0;
    for (final r in census.rows) {
      totRaw += r.rawCount;
      totDedup += r.afterPluginDedup;
      totUpload += r.uploadable;
    }
    return _ScrollTable(
      columns: const [
        'Metric',
        'Raw',
        'Dedup',
        'Upload',
        'Mapped',
        'Drop',
      ],
      rows: [
        for (final r in census.rows)
          [
            r.hkType,
            '${r.rawCount}',
            '${r.afterPluginDedup}',
            '${r.uploadable}',
            r.mappedMetric ?? '—',
            r.dropReason ?? '',
          ],
      ],
      totalsRow: ['TOTAL', '$totRaw', '$totDedup', '$totUpload', '', ''],
    );
  }

  // ── Card b: Server Reconciliation ────────────────────────────────────────
  Widget _buildReconciliationCard() {
    final rows = _compareRows;
    return _DevCard(
      icon: Icons.compare_arrows_rounded,
      title: 'Server Reconciliation',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Census = HealthKit ground truth · Reconciliation = what the '
            'pipeline stored.',
            style: TextStyle(fontSize: 11.5, color: kTextSecondary),
          ),
          const SizedBox(height: 10),
          if (_census == null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: kAmber.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'Run a census first — reconciliation compares it against the '
                'server.',
                style: TextStyle(fontSize: 12, color: kAmber),
              ),
            )
          else
            Row(
              children: [
                Expanded(
                  child: _PrimaryButton(
                    label: _reconLoading
                        ? 'Fetching…'
                        : 'Fetch Reconciliation (180d)',
                    icon: Icons.cloud_download_outlined,
                    loading: _reconLoading,
                    onPressed: _reconLoading ? null : _fetchReconciliation,
                  ),
                ),
                if (rows != null) ...[
                  const SizedBox(width: 8),
                  _SecondaryButton(
                    label: 'Copy TSV',
                    icon: Icons.copy,
                    onPressed: () => _copy(compareTsv(rows), 'compare TSV'),
                  ),
                ],
              ],
            ),
          if (_reconError != null) ...[
            const SizedBox(height: 8),
            _ErrorText(_reconError!),
          ],
          if (rows != null) ...[
            const SizedBox(height: 12),
            DevCompareTable(rows: rows),
          ],
        ],
      ),
    );
  }

  // ── Card c: Sync Log ─────────────────────────────────────────────────────
  Widget _buildSyncLogCard() {
    return _DevCard(
      icon: Icons.terminal_rounded,
      title: 'Sync Log',
      subtitle: _showDebugLog
          ? 'Verbose logging is ON (Profile → Show Sync Log).'
          : 'Verbose logging is OFF — enable it via Profile → Show Sync Log.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _PrimaryButton(
                  label: _syncRunning ? 'Syncing…' : 'Sync Now (verbose)',
                  icon: Icons.sync,
                  loading: _syncRunning,
                  onPressed: _syncRunning ? null : _syncNow,
                ),
              ),
              const SizedBox(width: 8),
              _SecondaryButton(
                label: 'Clear',
                icon: Icons.clear_all,
                onPressed: _syncLog.isEmpty ? null : _clearSyncLog,
              ),
              const SizedBox(width: 8),
              _SecondaryButton(
                label: 'Copy',
                icon: Icons.copy,
                onPressed: _syncLog.isEmpty
                    ? null
                    : () => _copy(_syncLog.join('\n'), 'sync log'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _MonoBox(
            lines: _syncLog.isEmpty ? const ['(no output yet)'] : _syncLog,
            maxHeight: 200,
            controller: _consoleController,
          ),
        ],
      ),
    );
  }

  // ── Card d: Sync State ───────────────────────────────────────────────────
  Widget _buildSyncStateCard() {
    final s = _syncState;
    return _DevCard(
      icon: Icons.insights_outlined,
      title: 'Sync State',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _kv('Last success', s.lastSuccessAtIso ?? '(never)'),
          _kv('Last attempt', s.lastAttemptAtIso ?? '(never)'),
          _kv('Last error', s.lastErrorClass ?? '(none)'),
          _kv('Last events', '${s.lastEventCount ?? 0}'),
          _kv('Anchor', s.clientUploadAnchorIso ?? '(none)'),
          const SizedBox(height: 12),
          const Text('Recent attempts',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          if (_attempts.isEmpty)
            const Text('(no attempts recorded)',
                style: TextStyle(fontSize: 12, color: kTextSecondary))
          else
            _ScrollTable(
              columns: const ['Time', 'Path', 'Outcome', 'Events'],
              rows: [
                // Newest first for readability.
                for (final a in _attempts.reversed)
                  [
                    _shortTime(a.at),
                    a.path,
                    a.outcome,
                    '${a.eventsSent}',
                  ],
              ],
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _PrimaryButton(
                  label: _anchorsLoading ? 'Fetching…' : 'Fetch server anchors',
                  icon: Icons.anchor,
                  loading: _anchorsLoading,
                  onPressed: _anchorsLoading ? null : _fetchAnchors,
                ),
              ),
              const SizedBox(width: 8),
              _SecondaryButton(
                label: 'Copy',
                icon: Icons.copy,
                onPressed: () => _copy(_syncStateText(), 'sync state'),
              ),
            ],
          ),
          if (_anchorsError != null) ...[
            const SizedBox(height: 8),
            _ErrorText(_anchorsError!),
          ],
          if (_serverAnchors != null) ...[
            const SizedBox(height: 10),
            const Text('Server latest_event_times',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            if (_serverAnchors!.isEmpty)
              const Text('(empty)',
                  style: TextStyle(fontSize: 12, color: kTextSecondary))
            else
              _ScrollTable(
                columns: const ['Metric', 'Latest event'],
                rows: [
                  for (final e in _serverAnchors!.entries) [e.key, e.value],
                ],
              ),
          ],
        ],
      ),
    );
  }

  String _syncStateText() {
    final s = _syncState;
    final buf = StringBuffer()
      ..writeln('Sync State')
      ..writeln('last_success_at: ${s.lastSuccessAtIso ?? "(never)"}')
      ..writeln('last_attempt_at: ${s.lastAttemptAtIso ?? "(never)"}')
      ..writeln('last_error_class: ${s.lastErrorClass ?? "(none)"}')
      ..writeln('last_event_count: ${s.lastEventCount ?? 0}')
      ..writeln('anchor: ${s.clientUploadAnchorIso ?? "(none)"}')
      ..writeln('')
      ..writeln('Recent attempts (newest first):');
    for (final a in _attempts.reversed) {
      buf.writeln('  ${a.at.toIso8601String()}\t${a.path}\t${a.outcome}\t'
          '${a.eventsSent}${a.errorClass != null ? "\t${a.errorClass}" : ""}');
    }
    final anchors = _serverAnchors;
    if (anchors != null) {
      buf..writeln('')..writeln('Server latest_event_times:');
      anchors.forEach((k, v) => buf.writeln('  $k\t$v'));
    }
    return buf.toString();
  }

  // ── Card e: API URL ──────────────────────────────────────────────────────
  Widget _buildApiUrlCard() {
    return _DevCard(
      icon: Icons.link_rounded,
      title: 'API URL',
      subtitle: 'Effective: $_effectiveBaseUrl',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _urlController,
            keyboardType: TextInputType.url,
            autocorrect: false,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              labelText: 'Base URL',
              errorText: _urlError,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
          ),
          const SizedBox(height: 6),
          Text('Default: $kDefaultApiUrl',
              style: const TextStyle(fontSize: 11, color: kTextSecondary)),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _PrimaryButton(
                  label: 'Save',
                  icon: Icons.save_outlined,
                  onPressed: _saveUrl,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Small render helpers ─────────────────────────────────────────────────
  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 110,
              child: Text(k,
                  style: const TextStyle(
                      fontSize: 12,
                      color: kTextSecondary,
                      fontWeight: FontWeight.w600)),
            ),
            Expanded(
              child: Text(v,
                  style: const TextStyle(fontSize: 12, color: kTextPrimary)),
            ),
          ],
        ),
      );

  static String _shortDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static String _shortTime(DateTime d) {
    final l = d.toLocal();
    return '${l.month}/${l.day} '
        '${l.hour.toString().padLeft(2, '0')}:'
        '${l.minute.toString().padLeft(2, '0')}';
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Reusable / testable widgets
// ═══════════════════════════════════════════════════════════════════════════

/// Renders a list of [CompareRow]s as a colour-coded table. Extracted as a
/// public widget so a widget test can pump it with fixed rows (a seeded fail
/// row must render red) without any network round-trip.
class DevCompareTable extends StatelessWidget {
  final List<CompareRow> rows;
  const DevCompareTable({super.key, required this.rows});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 18,
        headingRowHeight: 34,
        dataRowMinHeight: 32,
        dataRowMaxHeight: 44,
        headingTextStyle: const TextStyle(
            fontSize: 11, fontWeight: FontWeight.w700, color: kTextPrimary),
        dataTextStyle: const TextStyle(fontSize: 11.5, color: kTextPrimary),
        columns: const [
          DataColumn(label: Text('Metric')),
          DataColumn(label: Text('HK')),
          DataColumn(label: Text('Server')),
          DataColumn(label: Text('Usable')),
          DataColumn(label: Text('Δ')),
          DataColumn(label: Text('Status')),
          DataColumn(label: Text('Note')),
        ],
        rows: [
          for (final r in rows)
            DataRow(cells: [
              DataCell(Text(r.metric)),
              DataCell(Text('${r.hkUploadable}')),
              DataCell(Text('${r.serverRawUploaded}')),
              DataCell(Text('${r.serverUsable}')),
              DataCell(Text('${r.delta}')),
              DataCell(_statusPill(r.status)),
              DataCell(Text(r.note)),
            ]),
        ],
      ),
    );
  }

  Widget _statusPill(CompareStatus status) {
    final color = compareStatusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        status.name,
        style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }
}

/// A titled card matching the app's warm-neutral surface style.
class _DevCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget child;
  const _DevCard({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kCardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: kNavy),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: kTextPrimary)),
              ),
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!,
                style: const TextStyle(fontSize: 11.5, color: kTextSecondary)),
          ],
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

/// Horizontally-scrollable text table (Metric | numeric columns | notes) with
/// an optional bold totals row.
class _ScrollTable extends StatelessWidget {
  final List<String> columns;
  final List<List<String>> rows;
  final List<String>? totalsRow;
  const _ScrollTable({
    required this.columns,
    required this.rows,
    this.totalsRow,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 18,
        headingRowHeight: 32,
        dataRowMinHeight: 28,
        dataRowMaxHeight: 40,
        headingTextStyle: const TextStyle(
            fontSize: 11, fontWeight: FontWeight.w700, color: kTextPrimary),
        dataTextStyle: const TextStyle(fontSize: 11.5, color: kTextPrimary),
        columns: [
          for (final c in columns) DataColumn(label: Text(c)),
        ],
        rows: [
          for (final r in rows)
            DataRow(cells: [for (final c in r) DataCell(Text(c))]),
          if (totalsRow != null)
            DataRow(
              cells: [
                for (final c in totalsRow!)
                  DataCell(Text(c,
                      style: const TextStyle(fontWeight: FontWeight.w800))),
              ],
            ),
        ],
      ),
    );
  }
}

/// Monospace, scrollable output box for progress / console lines.
class _MonoBox extends StatelessWidget {
  final List<String> lines;
  final double maxHeight;
  final ScrollController? controller;
  const _MonoBox({
    required this.lines,
    required this.maxHeight,
    this.controller,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: BoxConstraints(maxHeight: maxHeight),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Scrollbar(
        controller: controller,
        child: SingleChildScrollView(
          controller: controller,
          child: Text(
            lines.join('\n'),
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              height: 1.4,
              color: Color(0xFFD4D4D4),
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorText extends StatelessWidget {
  final String message;
  const _ErrorText(this.message);

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.error_outline, size: 15, color: kRed),
        const SizedBox(width: 6),
        Expanded(
          child: Text(message,
              style: const TextStyle(fontSize: 11.5, color: kRed)),
        ),
      ],
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool loading;
  final VoidCallback? onPressed;
  const _PrimaryButton({
    required this.label,
    required this.icon,
    this.loading = false,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      style: ElevatedButton.styleFrom(
        backgroundColor: kNavy,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
      ),
      onPressed: onPressed,
      icon: loading
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            )
          : Icon(icon, size: 16),
      label: Text(label, overflow: TextOverflow.ellipsis),
    );
  }
}

class _SecondaryButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  const _SecondaryButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        foregroundColor: kNavy,
        side: const BorderSide(color: kNavy),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
      ),
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label),
    );
  }
}
