import 'package:flutter/material.dart';

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
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: switch (_status) {
            _Status.working => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 24),
                  Text(_message, textAlign: TextAlign.center),
                ],
              ),
            _Status.error => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _retryable ? Icons.wifi_off : Icons.event_busy,
                    size: 48,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _retryable ? 'Couldn\'t get your pass' : 'Event unavailable',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(_message, textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  if (_retryable)
                    FilledButton(
                      onPressed: _run,
                      child: const Text('Try again'),
                    ),
                ],
              ),
          },
        ),
      ),
    );
  }
}
