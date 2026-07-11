import 'dart:async';

import 'package:flutter/material.dart';

import 'auth_chrome.dart';
import 'auth_client.dart';
import 'auth_service.dart';
import 'forgot_password_screen.dart';
import 'signup_screen.dart';
import 'verify_pending_screen.dart';

/// The default gate when there is no account session: email + password login,
/// with links out to signup and password reset. On success [AuthService]
/// notifies its listeners and the app advances past the auth gate.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.auth});

  final AuthService auth;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _waking = false;
  Timer? _wakingTimer;

  @override
  void dispose() {
    _wakingTimer?.cancel();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  void _stopWaking() {
    _wakingTimer?.cancel();
    _waking = false;
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.isEmpty) return;
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
      await widget.auth.login(email: email, password: password);
      _stopWaking();
      // Success: AuthService notified; the root gate rebuilds to onboarding.
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on AuthException catch (e) {
      _stopWaking();
      if (!mounted) return;
      if (e.unverified) {
        // Email still unverified — send them to the pending screen to finish.
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => VerifyPendingScreen(
              auth: widget.auth, email: email, password: password),
        ));
        setState(() => _busy = false);
        return;
      }
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      hero: true,
      title: 'Log in',
      subtitle: 'Off-grid messaging for events',
      children: [
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
          controller: _password,
          icon: Icons.lock_outline_rounded,
          hint: 'Password',
          enabled: !_busy,
          obscure: true,
          autofillHints: const [AutofillHints.password],
          onSubmitted: (_) => _submit(),
        ),
        if (_error != null)
          AuthNotice(text: _error!, error: true)
        else if (_waking)
          const AuthNotice(text: authWakingMessage),
        const SizedBox(height: 18),
        AuthButton(label: 'Log in', busy: _busy, onTap: _submit),
        const SizedBox(height: 10),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          children: [
            AuthLink(
              label: 'Create an account',
              enabled: !_busy,
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => SignupScreen(auth: widget.auth))),
            ),
            AuthLink(
              label: 'Forgot password?',
              enabled: !_busy,
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ForgotPasswordScreen(auth: widget.auth))),
            ),
          ],
        ),
      ],
    );
  }
}
