import 'package:flutter/material.dart';

import 'auth_chrome.dart';
import 'auth_client.dart';
import 'auth_service.dart';

/// Shown after signup (or a login blocked as unverified): tells the user to
/// check their email, lets them resend, and — once they've clicked the link —
/// retries login with the credentials they just entered. On success
/// [AuthService] notifies and the app advances past the auth gate.
class VerifyPendingScreen extends StatefulWidget {
  const VerifyPendingScreen({
    super.key,
    required this.auth,
    required this.email,
    required this.password,
  });

  final AuthService auth;
  final String email;
  final String password;

  @override
  State<VerifyPendingScreen> createState() => _VerifyPendingScreenState();
}

class _VerifyPendingScreenState extends State<VerifyPendingScreen> {
  bool _busy = false;
  String? _notice;
  bool _noticeIsError = false;

  void _show(String message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _notice = message;
      _noticeIsError = error;
    });
  }

  Future<void> _resend() async {
    setState(() => _busy = true);
    try {
      await widget.auth.resendVerification(widget.email);
      _show('Verification email sent to ${widget.email}');
    } on AuthException catch (e) {
      _show(e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _continue() async {
    setState(() => _busy = true);
    try {
      await widget.auth
          .login(email: widget.email, password: widget.password);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on AuthException catch (e) {
      _show(
          e.unverified
              ? 'Not verified yet — check your inbox and tap the link'
              : e.message,
          error: true);
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Verify your email',
      children: [
        const Center(
            child: AuthBadge(icon: Icons.mark_email_unread_outlined)),
        const SizedBox(height: 16),
        AuthBody(
          center: true,
          text: 'We sent a verification link to ${widget.email}. Tap it, '
              'then come back and continue.',
        ),
        if (_notice != null)
          Center(child: AuthNotice(text: _notice!, error: _noticeIsError)),
        const SizedBox(height: 18),
        AuthButton(
            label: "I've verified — continue",
            busy: _busy,
            onTap: _continue),
        const SizedBox(height: 6),
        Center(
            child: AuthLink(
                label: 'Resend email', enabled: !_busy, onTap: _resend)),
      ],
    );
  }
}
