import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../friends/directory_client.dart';
import '../friends/friend_service.dart';

/// Post-attestation onboarding step: pick a username and register it (with
/// the device's two public keys, already generated at Phase 4 install) via
/// POST /account. Handles username-taken with an inline retry.
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key, required this.friends, required this.onDone});

  final FriendService friends;
  final VoidCallback onDone;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final TextEditingController _username = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _submit() async {
    final username = _username.text.trim();
    if (username.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.friends.createAccount(username);
      if (mounted) widget.onDone();
    } on DirectoryException catch (e) {
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
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.person_add_alt, size: 48),
              const SizedBox(height: 16),
              Text('Pick a username',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text(
                'Friends add you by this name. It is registered with the '
                'event directory along with your device keys.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _username,
                enabled: !_busy,
                autofocus: true,
                maxLength: 32,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[a-z0-9_.-]')),
                ],
                decoration: InputDecoration(
                  hintText: 'e.g. ada-l',
                  errorText: _error,
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Create account'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
