import 'package:flutter/material.dart';

import 'auth_chrome.dart';

/// Short one-time intro shown after the first verified login, before the mesh
/// setup steps. Purely informational — [onContinue] advances the gate.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key, required this.username, required this.onContinue});

  final String username;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      hero: true,
      title: 'Welcome, $username',
      subtitle: 'Off-grid messaging for events',
      children: [
        const AuthBody(
          text: 'Firefly keeps you connected without the internet. Your '
              'phone talks to nearby mesh nodes and other phones over '
              'Bluetooth and WiFi, relaying messages hop by hop.',
        ),
        const SizedBox(height: 12),
        const AuthBody(
          text: 'Add friends by username to chat privately end-to-end. '
              'A quick setup comes next.',
        ),
        const SizedBox(height: 20),
        AuthButton(label: 'Get started', onTap: onContinue),
      ],
    );
  }
}
