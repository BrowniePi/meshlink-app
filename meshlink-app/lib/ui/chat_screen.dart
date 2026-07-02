import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/message_factory.dart';
import '../core/pipeline.dart';
import '../core/test_identity.dart';
import '../transport/transport.dart';

class _ChatEntry {
  _ChatEntry(this.text, {required this.outgoing});
  final String text;
  final bool outgoing;
}

/// Minimal Phase 1 chat: a text input, a send button, and a scrolling list.
/// Send path: sign → pipeline checks → transport send. Receive path:
/// transport → pipeline checks → display. No threads, no persistence, no
/// styling polish — just enough to demo the relay pipeline over real BLE.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.transport,
    required this.pipeline,
    required this.identity,
  });

  final Transport transport;
  final RelayPipeline pipeline;
  final TestIdentity identity;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _input = TextEditingController();
  final List<_ChatEntry> _entries = [];
  String? _transportError;
  String? _lastDrop;

  /// Session ephemeral id. Spec §3 wants 15-min rotation aligned to
  /// floor(unix/900); Phase 1 keeps one id per app session.
  late final Uint8List _ephemId;

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

  @override
  void dispose() {
    widget.transport.stop();
    _input.dispose();
    super.dispose();
  }

  Future<void> _onPacket(String peerId, Uint8List data) async {
    final result = await widget.pipeline.process(data);
    if (!mounted) return;
    if (result.outcome == Outcome.deliver) {
      setState(() {
        _entries.add(_ChatEntry(
          utf8.decode(result.message!.payload, allowMalformed: true),
          outgoing: false,
        ));
      });
    } else {
      // Surface drops (forged/duplicate/expired) so the demo can show the
      // pipeline rejecting bad traffic.
      setState(() => _lastDrop = result.dropReason);
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;

    final packet = await buildSignedPacket(
      identity: widget.identity,
      ephemId: _ephemId,
      payload: utf8.encode(text),
    );

    // Outgoing traffic obeys the same pipeline as incoming: a message we
    // wouldn't relay is a message we shouldn't send. This also seeds dedup so
    // our own message echoed back by a peer is dropped, not re-displayed.
    final result = await widget.pipeline.process(packet);
    if (result.outcome != Outcome.deliver) {
      _showError('Not sent: ${result.dropReason}');
      return;
    }

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
      _entries.add(_ChatEntry(text, outgoing: true));
      _input.clear();
    });
    if (peers.isEmpty) {
      _showError('No peers in range — message not transmitted');
    } else if (failures > 0) {
      _showError('Send failed to $failures of ${peers.length} peer(s)');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MeshLink chat (Phase 1)')),
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
              itemBuilder: (context, i) {
                final entry = _entries[i];
                return Align(
                  alignment: entry.outgoing
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    margin:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: entry.outgoing
                          ? Theme.of(context).colorScheme.primaryContainer
                          : Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(entry.text),
                  ),
                );
              },
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
                      decoration:
                          const InputDecoration(hintText: 'Message nearby devices'),
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
}
