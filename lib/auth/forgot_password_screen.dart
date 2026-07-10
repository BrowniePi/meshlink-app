import 'package:flutter/material.dart';

import 'auth_chrome.dart';
import 'auth_client.dart';
import 'auth_service.dart';
import 'reset_password_screen.dart';

/// Request a password-reset email. The backend always accepts (no account
/// enumeration), so we always confirm and offer to enter the reset code.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key, required this.auth});

  final AuthService auth;

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final TextEditingController _email = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _sent = false;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    if (email.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.auth.requestReset(email);
      if (mounted) setState(() => _sent = true);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Reset password',
      children: [
        if (_sent) ...[
          const Center(child: AuthBadge(icon: Icons.mark_email_read_outlined)),
          const SizedBox(height: 16),
        ],
        AuthBody(
          center: _sent,
          text: _sent
              ? 'If that email has an account, a reset link is on its way. '
                  'Enter the code from it to set a new password.'
              : 'Enter your account email and we\'ll send a reset link.',
        ),
        const SizedBox(height: 16),
        if (!_sent) ...[
          AuthField(
            controller: _email,
            icon: Icons.alternate_email_rounded,
            hint: 'Email',
            enabled: !_busy,
            autofocus: true,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) AuthNotice(text: _error!, error: true),
          const SizedBox(height: 18),
          AuthButton(label: 'Send reset link', busy: _busy, onTap: _submit),
        ] else
          AuthButton(
            label: 'I have a reset code',
            onTap: () => Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                  builder: (_) => ResetPasswordScreen(auth: widget.auth)),
            ),
          ),
      ],
    );
  }
}
