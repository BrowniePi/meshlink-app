import 'package:flutter/material.dart';

import 'auth_chrome.dart';
import 'auth_client.dart';
import 'auth_service.dart';

/// Enter the reset code from the email plus a new password. On success we pop
/// back to login (every prior session was revoked server-side).
class ResetPasswordScreen extends StatefulWidget {
  const ResetPasswordScreen(
      {super.key, required this.auth, required this.email});

  final AuthService auth;

  /// The account email the recovery code was sent to (the code is only valid
  /// together with it).
  final String email;

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  final TextEditingController _token = TextEditingController();
  final TextEditingController _password = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _token.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final token = _token.text.trim();
    final password = _password.text;
    if (token.isEmpty || password.isEmpty) return;
    if (password.length < 8) {
      setState(() => _error = 'Password must be at least 8 characters');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.auth.resetPassword(
          email: widget.email, token: token, newPassword: password);
      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password updated — please log in')),
      );
    } on AuthException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Set new password',
      children: [
        AuthField(
          controller: _token,
          icon: Icons.key_rounded,
          hint: 'Reset code',
          enabled: !_busy,
          autofocus: true,
        ),
        const SizedBox(height: 12),
        AuthField(
          controller: _password,
          icon: Icons.lock_outline_rounded,
          hint: 'New password (8+ characters)',
          enabled: !_busy,
          obscure: true,
          autofillHints: const [AutofillHints.newPassword],
          onSubmitted: (_) => _submit(),
        ),
        if (_error != null) AuthNotice(text: _error!, error: true),
        const SizedBox(height: 18),
        AuthButton(label: 'Update password', busy: _busy, onTap: _submit),
      ],
    );
  }
}
