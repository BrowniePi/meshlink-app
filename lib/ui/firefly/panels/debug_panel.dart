import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/message_factory.dart';
import '../../../identity/device_identity.dart';
import '../../../power/battery_tier_manager.dart';
import '../../ble_log_screen.dart';
import '../../packet_info_sheet.dart';
import '../firefly_controller.dart';
import '../firefly_theme.dart';
import '../glass.dart';
import 'cards.dart';

/// Attacks the debug menu can inject, each targeting a specific pipeline
/// step on the *receiving* device (ported from the old ChatScreen test menu).
enum _Attack {
  forgedSignature('Forged signature', 'step 6 — signature'),
  replay('Replay last message', 'step 4 — dedup'),
  staleTimestamp('Stale timestamp', 'step 3 — timestamp'),
  futureTimestamp('Future timestamp', 'step 3 — timestamp'),
  flood('Flood (rate limit)', 'step 5 — rate limit'),
  oversized('Oversized packet', 'step 1 — size'),
  unattestedSender('Unattested sender', 'step 7 — attestation');

  const _Attack(this.label, this.target);
  final String label;
  final String target;
}

/// The developer sheet — only reachable when the app is launched with
/// --dart-define=FF_DEBUG=true. Bundles the broadcast ("nearby") chat, the
/// pipeline-attack injector, the BLE log, battery-tier forcing and packet
/// inspection that the old debug ChatScreen exposed. None of this is part of
/// the shipped Firefly experience.
class DebugPanel extends StatefulWidget {
  const DebugPanel({
    super.key,
    required this.controller,
    required this.identity,
    this.batteryTier,
  });

  final FireflyController controller;
  final DeviceIdentity identity;
  final BatteryTierManager? batteryTier;

  @override
  State<DebugPanel> createState() => _DebugPanelState();
}

class _DebugPanelState extends State<DebugPanel> {
  final TextEditingController _input = TextEditingController();
  final Uint8List _attackerEphem = Uint8List.fromList(List.filled(16, 0xaa));
  String? _notice;
  int _testCount = 0;

  FireflyController get _c => widget.controller;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _sendBroadcast(String text) async {
    final error = await _c.sendBroadcast(text);
    if (mounted) setState(() => _notice = error);
  }

  Future<void> _conductAttack(_Attack attack) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    List<Uint8List> packets;
    switch (attack) {
      case _Attack.forgedSignature:
        final p = await buildSignedPacket(
            identity: widget.identity,
            ephemId: _attackerEphem,
            payload: utf8.encode('forged'));
        p[p.length - 1] ^= 0xff;
        packets = [p];
      case _Attack.replay:
        final base = _c.lastSentPacket;
        if (base == null) {
          setState(() => _notice = 'Send a nearby message first, then replay');
          return;
        }
        packets = [base];
      case _Attack.staleTimestamp:
        packets = [
          await buildSignedPacket(
              identity: widget.identity,
              ephemId: _attackerEphem,
              payload: utf8.encode('from the past'),
              timestamp: now - 301),
        ];
      case _Attack.futureTimestamp:
        packets = [
          await buildSignedPacket(
              identity: widget.identity,
              ephemId: _attackerEphem,
              payload: utf8.encode('from the future'),
              timestamp: now + 31),
        ];
      case _Attack.flood:
        final floodEphem = Uint8List.fromList(List.filled(16, 0x66));
        packets = [
          for (var i = 0; i < 11; i++)
            await buildSignedPacket(
                identity: widget.identity,
                ephemId: floodEphem,
                payload: utf8.encode('flood $i')),
        ];
      case _Attack.oversized:
        packets = [Uint8List(600)..fillRange(0, 600, 0x41)];
      case _Attack.unattestedSender:
        final stranger = await DeviceIdentity.generate();
        packets = [
          await buildSignedPacket(
              identity: stranger,
              ephemId: Uint8List.fromList(List.filled(16, 0x99)),
              payload: utf8.encode('never onboarded')),
        ];
    }
    final peers = _c.peers;
    if (peers.isEmpty) {
      setState(() => _notice = 'No peers connected — pair another device');
      return;
    }
    for (final packet in packets) {
      for (final peer in peers) {
        try {
          await _c.transport.send(peer, packet);
        } catch (_) {}
      }
    }
    setState(() => _notice =
        'Sent to ${peers.length} peer(s) — expected reject at ${attack.target}');
  }

  @override
  Widget build(BuildContext context) {
    final c = FireflyTheme.of(context);
    final battery = widget.batteryTier;

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
                Icon(Icons.bug_report_rounded, size: 18, color: c.accent),
                const SizedBox(width: 8),
                Text('Developer',
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: c.text)),
                const Spacer(),
                closeButton(context, () => Navigator.of(context).maybePop()),
              ],
            ),
          ),
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_notice!,
                  style: TextStyle(fontSize: 12, color: c.accent)),
            ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(horizontal: 2),
              children: [
                _label(c, 'NEARBY BROADCAST CHAT'),
                _card(c, Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_c.broadcast.isEmpty)
                      Text('No broadcast messages yet.',
                          style: TextStyle(fontSize: 12, color: c.dim))
                    else
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 160),
                        child: ListView(
                          shrinkWrap: true,
                          children: [
                            for (final e in _c.broadcast)
                              GestureDetector(
                                onLongPress: e.packet == null
                                    ? null
                                    : () => showPacketInfo(
                                        context, e.packet!),
                                child: Align(
                                  alignment: e.outgoing
                                      ? Alignment.centerRight
                                      : Alignment.centerLeft,
                                  child: Container(
                                    margin: const EdgeInsets.symmetric(
                                        vertical: 3),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: e.outgoing
                                          ? c.accentSoft
                                          : c.glassLo,
                                      borderRadius:
                                          BorderRadius.circular(10),
                                    ),
                                    child: Text(e.text,
                                        style: TextStyle(
                                            fontSize: 13, color: c.text)),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    if (_c.lastDrop != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text('last dropped: ${_c.lastDrop}',
                            style:
                                TextStyle(fontSize: 11, color: c.faint)),
                      ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12),
                            decoration: BoxDecoration(
                              color: c.glassLo,
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(color: c.stroke),
                            ),
                            child: TextField(
                              controller: _input,
                              style: TextStyle(fontSize: 13, color: c.text),
                              decoration: InputDecoration(
                                hintText: 'Message nearby devices',
                                hintStyle: TextStyle(
                                    fontSize: 13, color: c.faint),
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding:
                                    const EdgeInsets.symmetric(vertical: 12),
                              ),
                              onSubmitted: (v) {
                                _sendBroadcast(v.trim());
                                _input.clear();
                              },
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        GlassIconButton(
                          icon: Icons.send_rounded,
                          size: 40,
                          iconSize: 18,
                          filled: true,
                          onTap: () {
                            _sendBroadcast(_input.text.trim());
                            _input.clear();
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _ghostTile(c, Icons.send_rounded,
                        'Send a normal test message', () {
                      _testCount++;
                      _sendBroadcast('Test message #$_testCount');
                    }),
                  ],
                )),
                const SizedBox(height: 12),
                _label(c, 'PIPELINE ATTACKS'),
                _card(c, Column(
                  children: [
                    for (final attack in _Attack.values)
                      _ghostTile(
                          c,
                          Icons.warning_amber_rounded,
                          attack.label,
                          () => _conductAttack(attack),
                          sub: 'expect reject at ${attack.target}'),
                  ],
                )),
                const SizedBox(height: 12),
                if (battery != null) ...[
                  _label(c, 'FORCE BATTERY TIER'),
                  _card(c, Column(
                    children: [
                      _ghostTile(
                          c,
                          Icons.autorenew_rounded,
                          'Auto (from battery level)',
                          () {
                            battery.force(null);
                            setState(() {});
                          },
                          selected: battery.forced == null),
                      for (final tier in BatteryTier.values)
                        _ghostTile(c, Icons.battery_std_rounded, tier.label,
                            () {
                          battery.force(tier);
                          setState(() {});
                        }, selected: battery.forced == tier),
                    ],
                  )),
                  const SizedBox(height: 12),
                ],
                _label(c, 'DIAGNOSTICS'),
                _card(c, _ghostTile(c, Icons.bluetooth_searching_rounded,
                    'Bluetooth logs', () {
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const BleLogScreen()));
                })),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(FfColors c, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 2, 6, 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(text,
              style: TextStyle(
                  fontSize: 11, letterSpacing: 1.5, color: c.faint)),
        ),
      );

  Widget _card(FfColors c, Widget child) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          gradient: c.glass(),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: c.stroke),
        ),
        child: child,
      );

  Widget _ghostTile(FfColors c, IconData icon, String label, VoidCallback onTap,
      {String? sub, bool selected = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? c.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: selected ? c.accentLine : c.stroke),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: selected ? c.accent : c.dim),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: c.text)),
                  if (sub != null)
                    Text(sub,
                        style: TextStyle(fontSize: 11, color: c.faint)),
                ],
              ),
            ),
            if (selected)
              Icon(Icons.check_rounded, size: 16, color: c.accent),
          ],
        ),
      ),
    );
  }
}
