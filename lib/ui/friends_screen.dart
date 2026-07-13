import 'package:flutter/material.dart';

import '../friends/directory_client.dart';
import '../friends/friend_service.dart';
import '../friends/friend_store.dart';
import 'direct_message_screen.dart';
import 'friend_map_screen.dart';

/// Friends list: inbound requests (explicit Accept / Decline — never
/// auto-accepted), current friends with the per-friend "share my location"
/// toggle, and a "view on map" entry for friends who granted us theirs.
class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key, required this.friends});

  final FriendService friends;

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  @override
  void initState() {
    super.initState();
    widget.friends.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.friends.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() => setState(() {});

  Future<void> _addFriend() async {
    final controller = TextEditingController();
    final username = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add friend'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'username'),
          onSubmitted: (v) => Navigator.pop(dialogContext, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Send request'),
          ),
        ],
      ),
    );
    if (username == null || username.isEmpty) return;
    try {
      await widget.friends.sendFriendRequest(username);
      _snack('Friend request sent to $username');
    } on DirectoryException catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _acceptDialog(FriendEntry entry) async {
    final username = entry.record.peerUsername;
    // Accept-time location opt-in: friendship consent and location consent
    // are separate questions, asked separately.
    final share = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Accept $username?'),
        content: const Text('Also share your location with them? You can '
            'change this per friend at any time.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Accept'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Accept + share location'),
          ),
        ],
      ),
    );
    if (share == null) return;
    await widget.friends.accept(username, shareLocation: share);
    _snack('You and $username are now friends');
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final receivedRequests = widget.friends.receivedRequests;
    final sentRequests = widget.friends.sentRequests;
    final friends = widget.friends.friends;
    return Scaffold(
      appBar: AppBar(
        title: Text('Friends — ${widget.friends.store.ownUsername ?? ''}'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addFriend,
        icon: const Icon(Icons.person_add),
        label: const Text('Add friend'),
      ),
      body: ListView(
        children: [
          if (receivedRequests.isNotEmpty) ...[
            const _SectionLabel('Received requests'),
            for (final entry in receivedRequests)
              ListTile(
                leading: const Icon(Icons.mark_email_unread_outlined),
                title: Text(entry.record.peerUsername),
                subtitle: const Text('wants to be friends'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.check),
                      tooltip: 'Accept',
                      onPressed: () => _acceptDialog(entry),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Decline',
                      onPressed: () =>
                          widget.friends.decline(entry.record.peerUsername),
                    ),
                  ],
                ),
              ),
          ],
          if (sentRequests.isNotEmpty) ...[
            const _SectionLabel('Sent requests'),
            for (final entry in sentRequests)
              ListTile(
                leading: const Icon(Icons.outgoing_mail),
                title: Text(entry.record.peerUsername),
                subtitle: const Text('awaiting response'),
              ),
          ],
          const _SectionLabel('Friends'),
          if (friends.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No friends yet — add one by username.',
                  textAlign: TextAlign.center),
            ),
          for (final entry in friends) _friendTile(entry),
        ],
      ),
    );
  }

  Widget _friendTile(FriendEntry entry) {
    final username = entry.record.peerUsername;
    final sharing = entry.record.locationSharingEnabled;
    final theyShare = entry.theirTokenToMe != null ||
        widget.friends.lastKnownLocation.containsKey(username);
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.person),
          title: Text(username),
          subtitle: Text(theyShare
              ? 'shares their location with you'
              : 'does not share their location'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.chat_bubble_outline),
                tooltip: 'Message',
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => DirectMessageScreen(
                    friends: widget.friends,
                    username: username,
                  ),
                )),
              ),
              IconButton(
                icon: const Icon(Icons.map_outlined),
                tooltip: theyShare ? 'View on map' : 'Location not available',
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => FriendMapScreen(
                    friends: widget.friends,
                    username: username,
                  ),
                )),
              ),
            ],
          ),
        ),
        SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.only(left: 72, right: 16),
          title: Text('Share my location with $username'),
          value: sharing,
          onChanged: (on) async {
            if (on) {
              await widget.friends.enableLocationSharing(username);
            } else {
              await widget.friends.disableLocationSharing(username);
            }
          },
        ),
        const Divider(height: 1),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text, style: Theme.of(context).textTheme.labelLarge),
      );
}
