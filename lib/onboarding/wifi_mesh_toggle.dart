import 'package:flutter/material.dart';

import '../auth/auth_chrome.dart';
import '../transport/failover_transport.dart';
import '../transport/wifi/wifi_join.dart';
import '../ui/firefly/firefly_theme.dart';
import '../ui/firefly/glass.dart';

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

  final confirmed = await showGlassConfirmDialog(
    context,
    title: 'Connect to venue mesh network?',
    lines: lines,
    confirmLabel:
        state.wifiCallingActive == true ? 'Connect anyway' : 'Connect',
    cancelLabel: 'Not now',
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

/// Frosted-glass confirm dialog in the Firefly language — replaces the stock
/// Material AlertDialog for the mesh-join warning. The dialog route sits
/// above any screen-local [FireflyTheme], so it carries its own (platform
/// brightness, same rule as [AuthScaffold]).
Future<bool?> showGlassConfirmDialog(
  BuildContext context, {
  required String title,
  required List<String> lines,
  required String confirmLabel,
  required String cancelLabel,
}) {
  final dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
  final colors = dark ? FfColors.dark : FfColors.light;
  return showDialog<bool>(
    context: context,
    barrierColor: colors.scrim,
    builder: (context) => FireflyTheme(
      colors: colors,
      child: Builder(builder: (context) {
        final c = FireflyTheme.of(context);
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24),
          child: GlassPanel(
            radius: 28,
            strong: true,
            blur: 28,
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: c.text)),
                const SizedBox(height: 14),
                for (final (i, line) in lines.indexed) ...[
                  if (i > 0) const SizedBox(height: 10),
                  AuthBody(text: line),
                ],
                const SizedBox(height: 20),
                AuthButton(
                  label: confirmLabel,
                  onTap: () => Navigator.pop(context, true),
                ),
                const SizedBox(height: 6),
                Center(
                  child: AuthLink(
                    label: cancelLabel,
                    onTap: () => Navigator.pop(context, false),
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    ),
  );
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
    if (_connecting) return;
    setState(() => _connecting = true);
    final enabled =
        await enableWifiMeshWithWarnings(context, widget.transport);
    if (!mounted) return;
    setState(() => _connecting = false);
    if (enabled) widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Connect to venue mesh network?',
      subtitle: 'Off-grid messaging for events',
      children: [
        const Center(child: AuthBadge(icon: Icons.wifi_tethering)),
        const SizedBox(height: 18),
        const AuthBody(
          text: 'Optional. Messaging works over Bluetooth either way — WiFi '
              'adds speed and range. The mesh network has no internet '
              'access, by design.',
          center: true,
        ),
        const SizedBox(height: 20),
        // No busy spinner here: the warning dialog sits on top while
        // [_connecting] is true, and an indefinite animation under a modal
        // barrier adds nothing (and never settles in widget tests).
        AuthButton(label: 'Connect', onTap: _connect),
        const SizedBox(height: 6),
        Center(
          child: AuthLink(
            label: 'Not now',
            enabled: !_connecting,
            onTap: widget.onDone,
          ),
        ),
      ],
    );
  }
}
