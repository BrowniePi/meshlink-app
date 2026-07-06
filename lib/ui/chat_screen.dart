import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/message.dart';
import '../core/message_factory.dart';
import '../core/pipeline.dart';
import '../debug/debug_log.dart' as dbg;
import '../identity/device_identity.dart';
import '../identity/token_storage.dart';
import '../transport/transport.dart';
import 'ble_log_screen.dart';
import 'packet_info_sheet.dart';

/// Attacks the test menu can inject, each targeting a specific pipeline step.
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

class _ChatEntry {
  _ChatEntry.message({
    required this.text,
    required this.outgoing,
    required this.packet,
  })  : isAttack = false,
        note = null;

  _ChatEntry.attack({
    required this.text,
    required this.packet,
    required this.note,
  })  : outgoing = true,
        isAttack = true;

  final String text;
  final bool outgoing;
  final Uint8List? packet; // raw wire bytes, for the packet-info sheet
  final bool isAttack;

  /// Attacks are transmitted raw and never run through this device's own
  /// pipeline (see [_ChatScreenState._conductAttack]), so this device has no
  /// way to know whether the target rejected it — [note] just records what
  /// was sent and where to look for the verdict.
  final String? note;
}

/// Minimal Phase 1 chat: a text input, a send button, and a scrolling list.
/// Send path: sign → pipeline checks → transport send. Receive path:
/// transport → pipeline checks → display. A debug "test menu" (AppBar
/// science icon) injects normal messages and adversarial packets, and opens
/// the BLE log; long-pressing any bubble shows its on-wire byte layout.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.transport,
    required this.pipeline,
    required this.identity,
    required this.attestationToken,
    required this.onTokenExpired,
  });

  final Transport transport;
  final RelayPipeline pipeline;
  final DeviceIdentity identity;

  /// The organiser attestation token (Phase 5). Its JWT is presented to each
  /// node before this device's messages so the node will relay them; see
  /// [_presentToPeers]. Its expiry gates when we must re-fetch.
  final AttestationToken attestationToken;

  /// Called when the token has expired mid-session. The app routes back
  /// through onboarding to fetch and present a fresh one — a node silently
  /// drops messages presented with a dead token, so there's no other signal.
  final VoidCallback onTokenExpired;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _input = TextEditingController();
  final List<_ChatEntry> _entries = [];
  String? _transportError;
  String? _lastDrop;
  int _testCount = 0;

  /// Session ephemeral id. Spec §3 wants 15-min rotation aligned to
  /// floor(unix/900); Phase 1 keeps one id per app session.
  late final Uint8List _ephemId;

  /// A distinct ephem_id for injected attacks, so they don't consume the
  /// user's real rate-limit budget (and vice versa).
  final Uint8List _attackerEphem = Uint8List.fromList(List.filled(16, 0xaa));

  /// Last packet we sent — the source for the replay attack.
  Uint8List? _lastSentPacket;

  /// Peers we've already handed our attestation token to. A node won't relay
  /// this device's messages until it has cached our token (Phase 5 §3), so we
  /// present it to each peer before sending anything through them.
  final Set<String> _presentedPeers = {};

  @override
  void initState() {
    super.initState();
    final rng = Random.secure();
    _ephemId = Uint8List.fromList(List.generate(16, (_) => rng.nextInt(256)));

    widget.transport.onReceive(_onPacket);
    widget.transport.start().catchError((Object e) {
      if (mounted) setState(() => _transportError = 'Transport: $e');
    });
  }

  /// True if the token has expired. When it has, ask the app to re-onboard
  /// (fetch + present a fresh token) and stop using the dead one — a node
  /// silently drops anything presented with an expired token.
  bool _handleExpiredToken() {
    if (!widget.attestationToken.isExpiredAt(DateTime.now())) return false;
    widget.onTokenExpired();
    return true;
  }

  /// Send our attestation token to every connected peer we haven't presented
  /// to yet. One signed message per call (msg_type ATTESTATION, payload = the
  /// JWT); sends are sequential, so a peer that is also given a chat message
  /// right after receives the token first — the order the node needs.
  Future<void> _presentToPeers() async {
    if (_handleExpiredToken()) return;
    final unpresented = widget.transport
        .listPeers()
        .where((p) => !_presentedPeers.contains(p))
        .toList();
    if (unpresented.isEmpty) return;

    final Uint8List packet;
    try {
      packet = await buildSignedPacket(
        identity: widget.identity,
        ephemId: _ephemId,
        payload: utf8.encode(widget.attestationToken.token),
        msgType: msgTypeAttestation,
        zoneId: broadcastZone,
      );
    } catch (e) {
      // Was silently swallowed before — a token too large for maxPayload
      // (e.g. a verbose JWT) threw here and the peer was never told, so the
      // node correctly (but confusingly) reports "no valid token" forever.
      dbg.DebugLog.instance.log('attest', 'failed to build presentation: $e',
          level: dbg.LogLevel.error);
      return;
    }
    for (final peer in unpresented) {
      try {
        await widget.transport.send(peer, packet);
        _presentedPeers.add(peer);
        dbg.DebugLog.instance.log('attest', 'presented token to $peer');
      } catch (_) {
        // Peer dropped mid-send; it'll be re-presented when it reappears.
      }
    }
  }

  @override
  void dispose() {
    widget.transport.stop();
    _input.dispose();
    super.dispose();
  }

  Future<void> _onPacket(String peerId, Uint8List data) async {
    // Traffic from a peer means it's connected — present our token to any
    // newly-seen peer (covers a node reconnecting after onboarding).
    unawaited(_presentToPeers());

    final result = await widget.pipeline.process(data);
    // This is the check that matters for attack testing: it runs on
    // whichever device actually received the bytes, not the one that sent
    // them. Logged to DebugLog so the BLE-log screen on *this* device shows
    // every accept/reject verdict, including for packets a peer attacked us
    // with.
    if (result.outcome == Outcome.deliver) {
      dbg.DebugLog.instance
          .log('pipeline', 'delivered ${data.length}B from $peerId');
    } else {
      dbg.DebugLog.instance.log(
          'pipeline', 'DROPPED ${data.length}B from $peerId: ${result.dropReason}',
          level: dbg.LogLevel.warn);
    }

    if (!mounted) return;
    if (result.outcome == Outcome.deliver) {
      setState(() {
        _entries.add(_ChatEntry.message(
          text: utf8.decode(result.message!.payload, allowMalformed: true),
          outgoing: false,
          packet: data,
        ));
      });
    } else {
      // Surface drops (forged/duplicate/expired) so the demo can show the
      // pipeline rejecting bad traffic.
      setState(() => _lastDrop = result.dropReason);
    }
  }

  Future<void> _send() => _sendMessage(_input.text.trim(), fromInput: true);

  Future<void> _sendMessage(String text, {bool fromInput = false}) async {
    if (text.isEmpty) return;
    // An expired pass means the node would drop this anyway — re-onboard first.
    if (_handleExpiredToken()) {
      _showError('Your event pass expired — getting a new one…');
      return;
    }

    // Broadcast zone (0xFFFF): this is a "message nearby devices" chat with
    // no per-recipient addressing, so every message is mesh-wide. A node
    // routes broadcast traffic to all other nodes AND its local BLE cell, so
    // both directions relay symmetrically — a fixed unicast zone only ever
    // relayed away from the node that owned that zone, which made the demo
    // one-way.
    final packet = await buildSignedPacket(
      identity: widget.identity,
      ephemId: _ephemId,
      payload: utf8.encode(text),
      zoneId: broadcastZone,
    );

    // Outgoing traffic obeys the same pipeline as incoming: a message we
    // wouldn't relay is a message we shouldn't send. This also seeds dedup so
    // our own message echoed back by a peer is dropped, not re-displayed.
    final result = await widget.pipeline.process(packet);
    if (result.outcome != Outcome.deliver) {
      _showError('Not sent: ${result.dropReason}');
      return;
    }
    _lastSentPacket = packet;

    // Make sure every peer has our token before the chat message, so the node
    // relays it rather than dropping it as unattested.
    await _presentToPeers();

    final peers = widget.transport.listPeers();
    var failures = 0;
    for (final peer in peers) {
      try {
        await widget.transport.send(peer, packet);
      } catch (_) {
        failures++; // peer disconnected mid-send; dedup makes retries safe
      }
    }

    if (!mounted) return;
    setState(() {
      _entries.add(_ChatEntry.message(
        text: text,
        outgoing: true,
        packet: packet,
      ));
      if (fromInput) _input.clear();
    });
    if (peers.isEmpty) {
      _showError('No peers in range — message not transmitted');
    } else if (failures > 0) {
      _showError('Send failed to $failures of ${peers.length} peer(s)');
    }
  }

  // ---- test menu ----

  void _openTestMenu() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text('Test menu',
                    style: TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              ListTile(
                leading: const Icon(Icons.send),
                title: const Text('Send a normal message'),
                subtitle: const Text('Signed, passes the full pipeline'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _testCount++;
                  _sendMessage('Test message #$_testCount');
                },
              ),
              ListTile(
                leading: const Icon(Icons.bluetooth_searching),
                title: const Text('Bluetooth logs'),
                subtitle: const Text('Live scan / connect / tx / rx events'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const BleLogScreen(),
                  ));
                },
              ),
              const Divider(),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Text('Conduct attack',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              for (final attack in _Attack.values)
                ListTile(
                  leading: const Icon(Icons.bug_report_outlined),
                  title: Text(attack.label),
                  subtitle: Text('Expected: rejected at ${attack.target}'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _conductAttack(attack);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Builds and transmits the attack's packet(s) directly over the
  /// transport, bypassing [widget.pipeline] entirely — that's this device's
  /// own pipeline, and checking there would let the sender silently
  /// swallow the attack before it ever reaches a peer. The whole point of
  /// these attacks is to prove the *receiving* node's pipeline does the
  /// rejecting.
  Future<void> _conductAttack(_Attack attack) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    List<Uint8List> packets;

    switch (attack) {
      case _Attack.forgedSignature:
        final p = await buildSignedPacket(
          identity: widget.identity,
          ephemId: _attackerEphem,
          payload: utf8.encode('forged'),
        );
        p[p.length - 1] ^= 0xff; // corrupt the signature
        packets = [p];

      case _Attack.replay:
        final base = _lastSentPacket;
        if (base == null) {
          _showError('Send a message first, then replay it');
          return;
        }
        // Re-inject the genuine prior packet byte-for-byte. This only
        // demonstrates anything if the target already saw the original —
        // its dedup cache is what catches this, not ours.
        packets = [base];

      case _Attack.staleTimestamp:
        packets = [
          await buildSignedPacket(
            identity: widget.identity,
            ephemId: _attackerEphem,
            payload: utf8.encode('from the past'),
            timestamp: now - 301, // older than the 5-min freshness window
          ),
        ];

      case _Attack.futureTimestamp:
        packets = [
          await buildSignedPacket(
            identity: widget.identity,
            ephemId: _attackerEphem,
            payload: utf8.encode('from the future'),
            timestamp: now + 31, // beyond the 30-s clock-skew tolerance
          ),
        ];

      case _Attack.flood:
        // 11 distinct packets on one ephem_id: the target's rate limiter
        // allows 10 per 10s window, so the 11th should be the one it drops.
        final floodEphem = Uint8List.fromList(List.filled(16, 0x66));
        packets = [
          for (var i = 0; i < 11; i++)
            await buildSignedPacket(
              identity: widget.identity,
              ephemId: floodEphem,
              payload: utf8.encode('flood $i'),
            ),
        ];

      case _Attack.oversized:
        // 600 bytes > 460-byte max: rejected pre-parse at the size check.
        packets = [Uint8List(600)..fillRange(0, 600, 0x41)];

      case _Attack.unattestedSender:
        // Every other attack reuses widget.identity — the real, already-
        // attested device key — so it's caught at its own step regardless of
        // attestation (step 7 runs last; steps 1/3/4/5/6 reject them first).
        // This is the only attack that needs a genuinely different identity:
        // a fresh keypair that never ran onboarding or presented a token, so
        // an otherwise perfectly valid, honestly-signed message has nothing
        // to fail *except* attestation.
        final strangerIdentity = await DeviceIdentity.generate();
        packets = [
          await buildSignedPacket(
            identity: strangerIdentity,
            ephemId: Uint8List.fromList(List.filled(16, 0x99)),
            payload: utf8.encode('never onboarded'),
          ),
        ];
    }

    final peers = widget.transport.listPeers();
    if (peers.isEmpty) {
      _showError(
          'No peers connected — pair with another MeshLink device to test '
          'this attack against its pipeline');
      return;
    }

    // Straight to the wire, bypassing this device's own pipeline entirely.
    for (final packet in packets) {
      for (final peer in peers) {
        try {
          await widget.transport.send(peer, packet);
        } catch (_) {
          // Peer disconnected mid-send; irrelevant to the attack's outcome.
        }
      }
    }

    if (!mounted) return;
    final packetWord = packets.length > 1 ? '${packets.length} packets' : 'packet';
    setState(() {
      _entries.add(_ChatEntry.attack(
        text: attack.label,
        packet: packets.last,
        note: '$packetWord sent to ${peers.length} peer(s), bypassing this '
            "device's own pipeline. Expected rejection at ${attack.target} "
            "on the receiving device — check its chat footer or BLE logs.",
      ));
    });
    _showError(
        'Sent $packetWord to ${peers.length} peer(s) — check the target '
        'device to see whether it was blocked');
  }

  // ---- bubble context menu ----

  void _showEntryMenu(_ChatEntry entry) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (entry.packet != null)
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('Packet info'),
                subtitle: const Text('Byte headers and wire layout'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  showPacketInfo(context, entry.packet!);
                },
              ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy text'),
              onTap: () {
                Navigator.pop(sheetContext);
                _input.text = entry.text;
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MeshLink chat (Phase 1)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.science_outlined),
            tooltip: 'Test menu',
            onPressed: _openTestMenu,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_transportError != null)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.errorContainer,
              padding: const EdgeInsets.all(8),
              child: Text(_transportError!),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: _entries.length,
              itemBuilder: (context, i) => _bubble(_entries[i]),
            ),
          ),
          if (_lastDrop != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                'last dropped: $_lastDrop',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          SafeArea(
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: TextField(
                      controller: _input,
                      decoration: const InputDecoration(
                          hintText: 'Message nearby devices'),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _send,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubble(_ChatEntry entry) {
    final scheme = Theme.of(context).colorScheme;
    final Color color;
    if (entry.isAttack) {
      // No local verdict is possible — this device transmitted the packet
      // without checking it, so the bubble is neutral, not pass/fail.
      color = scheme.tertiaryContainer;
    } else if (entry.outgoing) {
      color = scheme.primaryContainer;
    } else {
      color = scheme.surfaceContainerHighest;
    }

    return Align(
      alignment: entry.outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _showEntryMenu(entry),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          padding: const EdgeInsets.all(10),
          constraints: const BoxConstraints(maxWidth: 320),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (entry.isAttack)
                Row(
                  children: [
                    const Icon(Icons.bug_report_outlined, size: 16),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text('Attack: ${entry.text}',
                          style:
                              const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ],
                )
              else
                Text(entry.text),
              if (entry.isAttack && entry.note != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(entry.note!,
                      style: Theme.of(context).textTheme.bodySmall),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
