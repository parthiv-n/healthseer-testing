import 'dart:async';
import 'package:flutter/material.dart';
import '../services/health_service.dart';
import '../theme/colors.dart';

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _emailCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();
  final _newPwCtrl = TextEditingController();

  bool _loading = false;
  bool _slowHint = false;
  String? _error;
  String? _success;
  bool _obscure = true;
  bool _tokenStep = false; // true = show token + new password fields
  Timer? _slowHintTimer;

  @override
  void dispose() {
    _slowHintTimer?.cancel();
    _emailCtrl.dispose();
    _tokenCtrl.dispose();
    _newPwCtrl.dispose();
    super.dispose();
  }

  Future<void> _requestReset() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'Please enter your email address.');
      return;
    }
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      setState(() => _error = 'Please enter a valid email address.');
      return;
    }
    setState(() { _loading = true; _error = null; _success = null; _slowHint = false; });
    _slowHintTimer?.cancel();
    _slowHintTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && _loading) setState(() => _slowHint = true);
    });

    try {
      final result = await HealthService.requestPasswordReset(email: email);
      _slowHintTimer?.cancel();
      if (!mounted) return;

      if (result.success) {
        // If token was returned (dev/demo mode), pre-fill it
        final token = result.data?['reset_token'] as String?;
        if (token != null) {
          _tokenCtrl.text = token;
        }
        setState(() {
          _loading = false;
          _slowHint = false;
          _tokenStep = true;
          _success = 'Reset token generated. Enter your new password below.';
          _error = null;
        });
      } else {
        setState(() { _loading = false; _slowHint = false; _error = result.message; });
      }
    } catch (e) {
      _slowHintTimer?.cancel();
      if (mounted) {
        setState(() { _loading = false; _slowHint = false; _error = 'An unexpected error occurred.'; });
      }
    }
  }

  Future<void> _resetPassword() async {
    final token = _tokenCtrl.text.trim();
    final newPw = _newPwCtrl.text;

    if (token.isEmpty) {
      setState(() => _error = 'Please enter the reset token.');
      return;
    }
    if (newPw.length < 8) {
      setState(() => _error = 'Password must be at least 8 characters.');
      return;
    }

    setState(() { _loading = true; _error = null; _success = null; _slowHint = false; });

    try {
      final result = await HealthService.resetPassword(token: token, newPassword: newPw);
      if (!mounted) return;

      if (result.success) {
        setState(() { _loading = false; _success = result.message; _error = null; });
        // Navigate back to login after brief delay
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) Navigator.pop(context);
        });
      } else {
        setState(() { _loading = false; _error = result.message; });
      }
    } catch (e) {
      if (mounted) {
        setState(() { _loading = false; _error = 'An unexpected error occurred.'; });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 48),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Logo + title
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.asset(
                    'assets/tikcare_logo.jpeg',
                    width: 200,
                    height: 60,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => Container(
                      width: 200,
                      height: 60,
                      decoration: BoxDecoration(
                        color: kNavy,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.lock_reset, color: Colors.white, size: 36),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Center(
                child: Text(
                  'Reset Password',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: kNavy,
                    letterSpacing: -0.5,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Center(
                child: Text(
                  _tokenStep
                      ? 'Enter the reset token and your new password'
                      : 'Enter your email to receive a reset token',
                  style: const TextStyle(fontSize: 14, color: Colors.grey),
                ),
              ),
              const SizedBox(height: 40),

              // Step 1: Email
              if (!_tokenStep) ...[
                TextField(
                  controller: _emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _requestReset(),
                  style: const TextStyle(fontSize: 15),
                  decoration: _inputDecoration('Email', Icons.email_outlined),
                ),
              ],

              // Step 2: Token + New password
              if (_tokenStep) ...[
                TextField(
                  controller: _tokenCtrl,
                  autocorrect: false,
                  textInputAction: TextInputAction.next,
                  style: const TextStyle(fontSize: 15),
                  decoration: _inputDecoration('Reset Token', Icons.key_outlined),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _newPwCtrl,
                  obscureText: _obscure,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _resetPassword(),
                  style: const TextStyle(fontSize: 15),
                  decoration: _inputDecoration(
                    'New Password',
                    Icons.lock_outline,
                    suffix: IconButton(
                      icon: Icon(
                        _obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                        size: 20,
                        color: Colors.grey,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
              ],

              // Success message
              if (_success != null) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.green.shade200),
                  ),
                  child: Text(
                    _success!,
                    style: TextStyle(fontSize: 13, color: Colors.green.shade800),
                  ),
                ),
              ],

              // Error message
              if (_error != null) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: Text(
                    _error!,
                    style: TextStyle(fontSize: 13, color: Colors.red.shade800),
                  ),
                ),
              ],

              const SizedBox(height: 24),

              // Action button
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: kNavy,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  elevation: 0,
                ),
                onPressed: _loading ? null : (_tokenStep ? _resetPassword : _requestReset),
                child: _loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : Text(
                        _tokenStep ? 'Set New Password' : 'Send Reset Token',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                      ),
              ),
              if (_slowHint) ...[
                const SizedBox(height: 10),
                const Text(
                  'Taking a moment -- server may be warming up...',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],

              const SizedBox(height: 20),
              Center(
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text(
                    'Back to Sign In',
                    style: TextStyle(fontSize: 13, color: kNavy),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String label, IconData icon, {Widget? suffix}) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon, size: 20, color: Colors.grey),
      suffixIcon: suffix,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: kNavy, width: 1.5),
      ),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    );
  }
}
