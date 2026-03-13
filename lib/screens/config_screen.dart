import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/health_service.dart';

const _navy = Color(0xFF1B3A6B);
const _navyLight = Color(0xFF2A5298);

class ConfigScreen extends StatefulWidget {
  final dynamic prefs; // SharedPreferences — kept for compatibility
  const ConfigScreen({super.key, required this.prefs});

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  final _lpUrlCtrl = TextEditingController();
  final _lpApiKeyCtrl = TextEditingController();
  final _lpUserIdCtrl = TextEditingController();

  bool _testing = false;
  String? _testResult;
  bool? _testSuccess;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final cfg = await HealthService.getConfig();
    setState(() {
      _lpUrlCtrl.text = cfg['lpUrl'] ?? '';
      _lpApiKeyCtrl.text = cfg['lpApiKey'] ?? '';
      _lpUserIdCtrl.text = cfg['lpUserId'] ?? '';
    });
  }

  Future<void> _save() async {
    await HealthService.saveConfig({
      'owUrl': '',
      'owUserId': '',
      'owToken': '',
      'lpUrl': _lpUrlCtrl.text.trim(),
      'lpApiKey': _lpApiKeyCtrl.text.trim(),
      'lpUserId': _lpUserIdCtrl.text.trim(),
      'syncMode': 'direct',
    });
    if (mounted) {
      HapticFeedback.lightImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Configuration saved'),
          backgroundColor: Colors.green.shade700,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  Future<void> _testConnection() async {
    if (_lpUrlCtrl.text.trim().isEmpty) {
      setState(() {
        _testResult = 'Please enter an API URL first.';
        _testSuccess = false;
      });
      return;
    }
    // Save current values before testing
    await HealthService.saveConfig({
      'owUrl': '',
      'owUserId': '',
      'owToken': '',
      'lpUrl': _lpUrlCtrl.text.trim(),
      'lpApiKey': _lpApiKeyCtrl.text.trim(),
      'lpUserId': _lpUserIdCtrl.text.trim(),
      'syncMode': 'direct',
    });
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final result = await HealthService.pingLifePulse();
    if (mounted) {
      setState(() {
        _testing = false;
        _testSuccess = result.success;
        _testResult = result.success
            ? '✓ Connected — LifePulse API is online'
            : '✗ ${result.message}';
      });
    }
  }

  @override
  void dispose() {
    _lpUrlCtrl.dispose();
    _lpApiKeyCtrl.dispose();
    _lpUserIdCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FC),
      appBar: AppBar(
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [_navy, _navyLight],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
          ),
        ),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: const Text(
          'Connection Setup',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('Save', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _InfoBanner(),
            const SizedBox(height: 16),
            _SectionCard(
              title: 'LifePulse Server',
              children: [
                _Field(
                  ctrl: _lpUrlCtrl,
                  label: 'API Base URL',
                  hint: 'https://your-server.railway.app',
                  icon: Icons.link,
                  keyboardType: TextInputType.url,
                ),
                _Field(
                  ctrl: _lpApiKeyCtrl,
                  label: 'Partner API Key',
                  hint: 'lp_tikcare_…',
                  icon: Icons.key_outlined,
                  obscure: true,
                ),
                _Field(
                  ctrl: _lpUserIdCtrl,
                  label: 'Your User ID',
                  hint: 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx',
                  icon: Icons.person_outline,
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Test Connection button
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: _navy,
                side: const BorderSide(color: _navy),
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _testing ? null : _testConnection,
              icon: _testing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: _navy),
                    )
                  : const Icon(Icons.wifi_tethering, size: 18),
              label: Text(_testing ? 'Testing…' : 'Test Connection'),
            ),

            if (_testResult != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: (_testSuccess ?? false)
                      ? Colors.green.shade50
                      : Colors.red.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: (_testSuccess ?? false)
                        ? Colors.green.shade200
                        : Colors.red.shade200,
                  ),
                ),
                child: Text(
                  _testResult!,
                  style: TextStyle(
                    fontSize: 13,
                    color: (_testSuccess ?? false)
                        ? Colors.green.shade800
                        : Colors.red.shade800,
                  ),
                ),
              ),
            ],

            const SizedBox(height: 20),

            // Save button
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _navy,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
              onPressed: _save,
              child: const Text('Save Configuration', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),

            const SizedBox(height: 20),
            _HowToGetValues(),
          ],
        ),
      ),
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _InfoBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFEEF2FF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFC7D2FE)),
      ),
      child: const Row(
        children: [
          Icon(Icons.info_outline, color: _navy, size: 18),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Configure once — the app will sync your Apple Health data directly to the TikCare LifePulse platform.',
              style: TextStyle(fontSize: 13, color: _navy),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _SectionCard({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
            child: Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13,
                color: _navy,
                letterSpacing: 0.2,
              ),
            ),
          ),
          ...children.map(
            (w) => Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 2),
              child: w,
            ),
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final TextEditingController ctrl;
  final String label;
  final String hint;
  final IconData icon;
  final bool obscure;
  final TextInputType? keyboardType;

  const _Field({
    required this.ctrl,
    required this.label,
    required this.hint,
    required this.icon,
    this.obscure = false,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: ctrl,
        obscureText: obscure,
        keyboardType: keyboardType,
        autocorrect: false,
        enableSuggestions: false,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: Icon(icon, size: 18, color: Colors.grey),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: _navy, width: 1.5),
          ),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        ),
      ),
    );
  }
}

class _HowToGetValues extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Where to find these values',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
          const SizedBox(height: 8),
          _helpRow('API Base URL', 'Server URL from your deployment (Railway / Cloudflare)'),
          _helpRow('Partner API Key', 'Management Portal → Admin → API Keys'),
          _helpRow('Your User ID', 'Management Portal → Members → click your name'),
        ],
      ),
    );
  }

  Widget _helpRow(String key, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: RichText(
          text: TextSpan(
            style: const TextStyle(fontSize: 12, color: Colors.black87),
            children: [
              TextSpan(
                text: '$key: ',
                style: const TextStyle(fontWeight: FontWeight.w600, color: _navy),
              ),
              TextSpan(text: value),
            ],
          ),
        ),
      );
}
