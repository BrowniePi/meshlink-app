import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'auth_chrome.dart';
import 'auth_client.dart';
import 'auth_service.dart';
import 'verify_pending_screen.dart';

/// Create an account: email, a mesh username (same [a-z0-9_.-]/32 rule the
/// directory enforces), and a password. On success we route to the
/// verify-pending screen — login stays blocked until the email is verified.
class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key, required this.auth});

  final AuthService auth;

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _waking = false;
  Timer? _wakingTimer;

  @override
  void dispose() {
    _wakingTimer?.cancel();
    _email.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _stopWaking() {
    _wakingTimer?.cancel();
    _waking = false;
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final username = _username.text.trim();
    final password = _password.text;
    if (email.isEmpty || username.isEmpty || password.isEmpty) return;
    if (password.length < 8) {
      setState(() => _error = 'Password must be at least 8 characters');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _waking = false;
    });
    _wakingTimer?.cancel();
    _wakingTimer = Timer(authWakingAfter, () {
      if (mounted) setState(() => _waking = true);
    });
    try {
      await widget.auth
          .signup(email: email, username: username, password: password);
      _stopWaking();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => VerifyPendingScreen(
            auth: widget.auth, email: email, password: password),
      ));
    } on AuthException catch (e) {
      _stopWaking();
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
      title: 'Create account',
      subtitle: 'Off-grid messaging for events',
      children: [
        const AuthBody(
          text: 'Your email + password sign you in on any device. Your '
              'username is how friends find you on the mesh.',
        ),
        const SizedBox(height: 16),
        AuthField(
          controller: _email,
          icon: Icons.alternate_email_rounded,
          hint: 'Email',
          enabled: !_busy,
          autofocus: true,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
        ),
        const SizedBox(height: 12),
        AuthField(
          controller: _username,
          icon: Icons.person_outline_rounded,
          hint: 'Username · e.g. ada-l',
          enabled: !_busy,
          maxLength: 32,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[a-z0-9_.-]')),
          ],
        ),
        const SizedBox(height: 12),
        AuthField(
          controller: _password,
          icon: Icons.lock_outline_rounded,
          hint: 'Password (8+ characters)',
          enabled: !_busy,
          obscure: true,
          autofillHints: const [AutofillHints.newPassword],
          onSubmitted: (_) => _submit(),
        ),
        if (_error != null)
          AuthNotice(text: _error!, error: true)
        else if (_waking)
          const AuthNotice(text: authWakingMessage),
        const SizedBox(height: 18),
        AuthButton(label: 'Sign up', busy: _busy, onTap: _submit),
      ],
    );
  }
}
