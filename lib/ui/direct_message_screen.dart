import 'package:flutter/material.dart';

import '../core/friend_wire.dart';
import '../friends/friend_service.dart';
import '../friends/friend_store.dart';

/// One-to-one conversation with a friend. Messages ride the mesh sealed to
/// the friend's X25519 key (relays and nodes carry them opaque) and delivery
/// is best-effort spray-and-wait — same guarantees as broadcast chat, minus
/// the audience.
class DirectMessageScreen extends StatefulWidget {
  const DirectMessageScreen(
      {super.key, required this.friends, required this.username});

  final FriendService friends;
  final String username;

  @override
  State<DirectMessageScreen> createState() => _DirectMessageScreenState();
}

class _DirectMessageScreenState extends State<DirectMessageScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.friends.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.friends.removeListener(_onChange);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChange() {
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    try {
      await widget.friends.sendDirectMessage(widget.username, text);
      _input.clear();
    } on ArgumentError {
      _snack('Message too long — max $maxDmTextBytes bytes');
    } on StateError {
      _snack('You are no longer friends with ${widget.username}');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.friends.store.byUsername(widget.username);
    final messages = entry?.messages ?? const <DirectMessage>[];
    return Scaffold(
      appBar: AppBar(title: Text(widget.username)),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? const Center(
                    child: Text('No messages yet.\nDelivery is best-effort '
                        'over the mesh — like everything here.',
                        textAlign: TextAlign.center))
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(8),
                    itemCount: messages.length,
                    itemBuilder: (_, i) => _bubble(messages[i]),
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      decoration: InputDecoration(
                        hintText: 'Message ${widget.username}',
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    icon: const Icon(Icons.send),
                    tooltip: 'Send',
                    onPressed: _send,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubble(DirectMessage message) {
    final theme = Theme.of(context);
    return Align(
      alignment:
          message.outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: message.outgoing
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(message.text),
      ),
    );
  }
}
