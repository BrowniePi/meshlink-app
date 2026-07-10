import 'package:flutter/material.dart';

import '../../../onboarding/wifi_mesh_toggle.dart';
import '../../../transport/failover_transport.dart';
import '../firefly_controller.dart';
import '../firefly_theme.dart';
import '../glass.dart';
import 'cards.dart';

/// Muted red for the sign-out action — legible on both glass themes.
const Color _danger = Color(0xFFE5605E);

/// Settings sheet: profile, power mode (mapped to the Phase 7 battery
/// tiers), appearance, turbo link (the WiFi mesh opt-in), the master
/// location-sharing switch, and live mesh-network stats.
class SettingsPanel extends StatefulWidget {
  const SettingsPanel({super.key, required this.controller,
      required this.onClose, required this.onLogout});

  final FireflyController controller;
  final VoidCallback onClose;
  final VoidCallback onLogout;

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  FireflyController get _c => widget.controller;

  Future<void> _toggleTurbo(bool on) async {
    final t = _c.transport;
    if (t is! FailoverTransport) return;
    if (on) {
      await enableWifiMeshWithWarnings(context, t);
    } else {
      await t.disableWifi();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = FireflyTheme.of(context);
    final username = _c.friends.store.ownUsername ?? '';
    final power = _c.powerMode;
    final tier = _c.batteryTier?.tier.value;
    final level = _c.batteryTier?.level.value;
    final peers = _c.peers;

    final powerSubs = {
      PowerMode.saver:
          'Leaf mode: own messages only, no relaying. Lasts the whole night.',
      PowerMode.balanced:
          'Follows your battery level automatically. Recommended.',
      PowerMode.boost:
          'Relays more traffic for nearby fireflies. Higher battery use.',
    };

    return GlassPanel(
      radius: 28,
      strong: true,
      blur: 28,
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 12),
            child: Row(
              children: [
                Text('Settings',
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: c.text)),
                const Spacer(),
                closeButton(context, widget.onClose),
              ],
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
              children: [
                // profile
                _card(c, Row(
                  children: [
                    InitialAvatar(name: username, size: 44,
                        background: const Color(0xFF565E7C)),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(username,
                              style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: c.text)),
                          Text(
                              '@$username · '
                              '${_c.sharingAny ? 'visible on mesh' : 'not sharing location'}',
                              style:
                                  TextStyle(fontSize: 12, color: c.dim)),
                        ],
                      ),
                    ),
                  ],
                )),
                const SizedBox(height: 12),
                // power mode
                _card(c, Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                            switch (power) {
                              PowerMode.saver => Icons.battery_saver_rounded,
                              PowerMode.boost => Icons.bolt_rounded,
                              PowerMode.balanced =>
                                Icons.battery_full_rounded,
                            },
                            size: 19,
                            color: c.dim),
                        const SizedBox(width: 12),
                        Text('Power mode',
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: c.text)),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: c.glassLo,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: c.stroke),
                      ),
                      child: Row(
                        children: [
                          for (final (mode, label) in [
                            (PowerMode.saver, 'Saver'),
                            (PowerMode.balanced, 'Balanced'),
                            (PowerMode.boost, 'Boost'),
                          ])
                            Expanded(
                              child: GestureDetector(
                                onTap: () => _c.setPowerMode(mode),
                                child: AnimatedContainer(
                                  duration:
                                      const Duration(milliseconds: 250),
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 7),
                                  decoration: BoxDecoration(
                                    color: power == mode
                                        ? c.accent
                                        : Colors.transparent,
                                    borderRadius:
                                        BorderRadius.circular(999),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(label,
                                      style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: power == mode
                                              ? c.accentInk
                                              : c.dim)),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 9),
                    Text(powerSubs[power]!,
                        style: TextStyle(
                            fontSize: 12, color: c.dim, height: 1.4)),
                  ],
                )),
                const SizedBox(height: 12),
                // appearance + toggles
                _card(c, Column(
                  children: [
                    Row(
                      children: [
                        ValueListenableBuilder<bool>(
                          valueListenable: _c.darkMode,
                          builder: (context, dark, _) => Icon(
                              dark
                                  ? Icons.dark_mode_rounded
                                  : Icons.light_mode_rounded,
                              size: 19,
                              color: c.dim),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text('Appearance',
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: c.text)),
                        ),
                        Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: c.glassLo,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: c.stroke),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final (dark, label) in [
                                (true, 'Dark'),
                                (false, 'Light')
                              ])
                                GestureDetector(
                                  onTap: () => _c.darkMode.value = dark,
                                  child: AnimatedContainer(
                                    duration:
                                        const Duration(milliseconds: 250),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 13, vertical: 5),
                                    decoration: BoxDecoration(
                                      color: _c.darkMode.value == dark
                                          ? c.accent
                                          : Colors.transparent,
                                      borderRadius:
                                          BorderRadius.circular(999),
                                    ),
                                    child: Text(label,
                                        style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: _c.darkMode.value == dark
                                                ? c.accentInk
                                                : c.dim)),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    Divider(color: c.stroke, height: 24),
                    _toggleRow(
                      c,
                      icon: Icons.wifi_tethering_rounded,
                      label: 'Turbo link',
                      sub: 'WiFi bursts to nodes · drains battery faster',
                      value: _c.wifiOn,
                      onChanged: _toggleTurbo,
                    ),
                    Divider(color: c.stroke, height: 24),
                    _toggleRow(
                      c,
                      icon: Icons.my_location_rounded,
                      label: 'Share my location',
                      sub: 'Friends you approved see you on their map',
                      value: _c.sharingAny,
                      onChanged: (on) => _c.setSharingMaster(on),
                    ),
                  ],
                )),
                const SizedBox(height: 12),
                // mesh network stats
                _card(c, Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.hub_rounded, size: 17, color: c.faint),
                        const SizedBox(width: 8),
                        Text('MESH NETWORK',
                            style: TextStyle(
                                fontSize: 11,
                                letterSpacing: 1.5,
                                color: c.faint)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _statRow(c, 'Connected node',
                        peers.isEmpty
                            ? '—'
                            : _c.ownZoneId != null
                                ? 'Zone ${_c.ownZoneId} · ${_short(peers.first)}'
                                : _short(peers.first)),
                    _statRow(c, 'Peers in range', '${peers.length}'),
                    _statRow(
                        c,
                        'Battery tier',
                        tier == null
                            ? '—'
                            : '${tier.label}${level != null ? ' · $level%' : ''}'
                                '${_c.batteryTier?.forced != null ? ' (pinned)' : ''}'),
                    _statRow(c, 'Link', switch (_c.strength) {
                      LinkStrength.strong => 'strong (WiFi node)',
                      LinkStrength.good => 'good (BLE mesh)',
                      LinkStrength.weak => 'weak (one peer)',
                      LinkStrength.offline => 'offline — direct radio only',
                    }),
                  ],
                )),
                const SizedBox(height: 12),
                // log out
                GestureDetector(
                  onTap: widget.onLogout,
                  behavior: HitTestBehavior.opaque,
                  child: _card(c, Row(
                    children: [
                      const Icon(Icons.logout_rounded,
                          size: 19, color: _danger),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text('Log out',
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: _danger)),
                      ),
                      Icon(Icons.chevron_right_rounded,
                          size: 20, color: c.faint),
                    ],
                  )),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.lock_rounded, size: 14, color: c.faint),
                    const SizedBox(width: 5),
                    Text('Firefly · messages stay on the mesh',
                        style: TextStyle(fontSize: 12, color: c.faint)),
                  ],
                ),
                const SizedBox(height: 4),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _short(String peer) =>
      peer.length <= 18 ? peer : '${peer.substring(0, 15)}…';

  Widget _card(FfColors c, Widget child) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: c.glass(),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: c.stroke),
        ),
        child: child,
      );

  Widget _toggleRow(FfColors c,
      {required IconData icon,
      required String label,
      required String sub,
      required bool value,
      required ValueChanged<bool> onChanged}) {
    return Row(
      children: [
        Icon(icon, size: 19, color: c.dim),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: c.text)),
              const SizedBox(height: 1),
              Text(sub, style: TextStyle(fontSize: 12, color: c.dim)),
            ],
          ),
        ),
        GlassSwitch(value: value, onChanged: onChanged),
      ],
    );
  }

  Widget _statRow(FfColors c, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Text(label, style: TextStyle(fontSize: 13, color: c.dim)),
            const Spacer(),
            Text(value,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: c.text)),
          ],
        ),
      );
}
