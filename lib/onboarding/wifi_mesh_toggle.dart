import 'package:flutter/material.dart';

import '../transport/failover_transport.dart';
import '../transport/wifi/wifi_join.dart';

/// Warning-then-enable flow shared by the onboarding screen below and the
/// chat AppBar toggle. Checks the phone's current WiFi state first and
/// surfaces the single-WiFi-client tradeoff at the moment of choice (WiFi
/// Mesh Add-On §4.2): if the phone is on another network it is named
/// explicitly, and an active WiFi Calling link escalates to the stronger
/// call-specific warning (§4.3). Returns true if the mesh was enabled.
Future<bool> enableWifiMeshWithWarnings(
  BuildContext context,
  FailoverTransport transport,
) async {
  WifiState state;
  try {
    state = await transport.wifi.join.currentState();
  } catch (_) {
    state = const WifiState(); // unknown state — show the generic copy
  }
  if (!context.mounted) return false;

  final meshSsid = transport.wifi.config.ssid;
  final otherNetwork =
      (state.currentSsid != null && state.currentSsid != meshSsid)
          ? state.currentSsid
          : null;

  final lines = <String>[
    'The venue mesh network is faster and longer-range than Bluetooth, '
        'but it is a closed network: it has no internet access, by design.',
  ];
  if (state.wifiCallingActive == true) {
    lines.add('Your phone is using WiFi Calling right now. Switching to the '
        'mesh network will break WiFi calls — you may be unreachable for '
        'voice calls while connected.');
  } else if (otherNetwork != null) {
    lines.add('You\'re currently connected to "$otherNetwork". Switching to '
        'the mesh network will disconnect you from it.');
  }
  lines.add('Your messages fall back to Bluetooth automatically if you '
      'turn this off or move out of WiFi range.');

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Connect to venue mesh network?'),
      content: Text(lines.join('\n\n')),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(state.wifiCallingActive == true
              ? 'Connect anyway'
              : 'Connect'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return false;

  try {
    await transport.enableWifi();
    return true;
  } on WifiJoinException catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
    return false;
  }
}

/// One-time onboarding step after the attestation fetch: WiFi mesh as an
/// explicit opt-in choice, off by default — never a silent background
/// action. Skipping proceeds straight to chat on BLE only; the same toggle
/// remains available from the chat AppBar afterwards.
class WifiMeshToggleScreen extends StatefulWidget {
  const WifiMeshToggleScreen({
    super.key,
    required this.transport,
    required this.onDone,
  });

  final FailoverTransport transport;
  final VoidCallback onDone;

  @override
  State<WifiMeshToggleScreen> createState() => _WifiMeshToggleScreenState();
}

class _WifiMeshToggleScreenState extends State<WifiMeshToggleScreen> {
  bool _connecting = false;

  Future<void> _connect() async {
    setState(() => _connecting = true);
    final enabled =
        await enableWifiMeshWithWarnings(context, widget.transport);
    if (!mounted) return;
    setState(() => _connecting = false);
    if (enabled) widget.onDone();
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
              const Icon(Icons.wifi_tethering, size: 48),
              const SizedBox(height: 16),
              Text(
                'Connect to venue mesh network\nfor faster messaging?',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              const Text(
                'Optional. Messaging works over Bluetooth either way — WiFi '
                'adds speed and range. The mesh network has no internet '
                'access, by design.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _connecting ? null : _connect,
                child: const Text('Connect'),
              ),
              TextButton(
                onPressed: _connecting ? null : widget.onDone,
                child: const Text('Not now'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
