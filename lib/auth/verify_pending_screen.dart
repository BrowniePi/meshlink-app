import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'auth_chrome.dart';
import 'auth_client.dart';
import 'auth_service.dart';

/// Shown after signup (or a login blocked as unverified): the user enters the
/// 6-digit code from the verification email (or taps the link in it and
/// comes back), then we log them in with the credentials they just entered.
/// On success [AuthService] notifies and the app advances past the auth gate.
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
  final TextEditingController _token = TextEditingController();
  bool _busy = false;
  String? _notice;
  bool _noticeIsError = false;

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

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
      _show('Verification code sent to ${widget.email}');
    } on AuthException catch (e) {
      _show(e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    final token = _token.text.trim();
    if (token.isEmpty) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await widget.auth.verifyEmail(email: widget.email, token: token);
      await widget.auth
          .login(email: widget.email, password: widget.password);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on AuthException catch (e) {
      _show(e.message, error: true);
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
              ? 'Not verified yet — enter the code or tap the link'
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
          text: 'Enter the 6-digit code we sent to ${widget.email}, or '
              'tap the link in that email.',
        ),
        const SizedBox(height: 16),
        AuthField(
          controller: _token,
          icon: Icons.pin_rounded,
          hint: '6-digit code',
          enabled: !_busy,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
          onSubmitted: (_) => _verify(),
        ),
        if (_notice != null)
          Center(child: AuthNotice(text: _notice!, error: _noticeIsError)),
        const SizedBox(height: 18),
        AuthButton(label: 'Verify', busy: _busy, onTap: _verify),
        const SizedBox(height: 6),
        Center(
            child: AuthLink(
                label: "I've tapped the link — continue",
                enabled: !_busy,
                onTap: _continue)),
        Center(
            child: AuthLink(
                label: 'Resend code', enabled: !_busy, onTap: _resend)),
      ],
    );
  }
}
