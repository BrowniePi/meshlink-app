import 'package:flutter/material.dart';

import '../auth/auth_chrome.dart';
import '../debug/debug_log.dart' as dbg;
import '../identity/device_identity.dart';
import '../identity/token_storage.dart';
import 'attestation_flow.dart';

/// First-launch gate: fetches the device's attestation token from the
/// organiser backend before the chat is reachable. Without a token the mesh
/// nodes refuse to relay this device's messages (Phase 5 §3), so onboarding
/// blocks until it succeeds — with a clear, retryable error if the backend
/// is unreachable and a distinct "event ended" path for a definitive refusal.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.identity,
    required this.flow,
    required this.tokenStorage,
    required this.onComplete,
  });

  final DeviceIdentity identity;
  final AttestationFlow flow;
  final TokenStorage tokenStorage;
  final ValueChanged<AttestationToken> onComplete;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

enum _Status { working, error }

class _OnboardingScreenState extends State<OnboardingScreen> {
  _Status _status = _Status.working;
  String _message = 'Getting your event pass…';
  bool _retryable = true;

  @override
  void initState() {
    super.initState();
    _run();
  }

  String _pubkeyHex() => widget.identity.publicKey
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  Future<void> _run() async {
    setState(() {
      _status = _Status.working;
      _message = 'Getting your event pass…';
    });
    dbg.DebugLog.instance.log('onboard', 'fetching event pass');
    try {
      final token = await widget.flow.fetchToken(_pubkeyHex());
      await widget.tokenStorage.write(token);
      dbg.DebugLog.instance.log('onboard', 'event pass stored — onboarding done');
      if (!mounted) return;
      widget.onComplete(token);
    } on AttestationException catch (e) {
      dbg.DebugLog.instance.log('onboard',
          'onboarding failed (${e.message}), retryable=${e.retryable}',
          level: dbg.LogLevel.error);
      if (!mounted) return;
      setState(() {
        _status = _Status.error;
        _message = e.message;
        _retryable = e.retryable;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: switch (_status) {
        _Status.working => 'Event pass',
        _Status.error =>
          _retryable ? 'Couldn\'t get your pass' : 'Event unavailable',
      },
      subtitle: 'Off-grid messaging for events',
      children: switch (_status) {
        _Status.working => [
            const Center(child: AuthSpinner()),
            const SizedBox(height: 18),
            AuthBody(text: _message, center: true),
          ],
        _Status.error => [
            Center(
              child: AuthBadge(
                  icon: _retryable ? Icons.wifi_off : Icons.event_busy),
            ),
            const SizedBox(height: 18),
            AuthBody(text: _message, center: true),
            if (_retryable) ...[
              const SizedBox(height: 20),
              AuthButton(label: 'Try again', onTap: _run),
            ],
          ],
      },
    );
  }
}
