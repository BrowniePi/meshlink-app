import 'package:flutter/material.dart';

import '../../../friends/directory_client.dart';
import '../firefly_controller.dart';
import '../firefly_theme.dart';
import '../glass.dart';
import 'cards.dart';

/// Friends sheet: add-by-username (mesh directory), inbound friend requests
/// with explicit Accept / Decline (consent is never automatic), and the
/// friend rows with unread badge, live detail and the show-on-map toggle.
class FriendsPanel extends StatefulWidget {
  const FriendsPanel({super.key, required this.controller,
      required this.onOpen, required this.onClose});

  final FireflyController controller;
  final ValueChanged<String> onOpen;
  final VoidCallback onClose;

  @override
  State<FriendsPanel> createState() => _FriendsPanelState();
}

class _FriendsPanelState extends State<FriendsPanel> {
  final TextEditingController _search = TextEditingController();
  String? _notice;

  FireflyController get _c => widget.controller;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _addFriend() async {
    var username = _search.text.trim();
    if (username.startsWith('@')) username = username.substring(1);
    if (username.isEmpty) return;
    try {
      final reached = await _c.friends.sendFriendRequest(username);
      setState(() {
        // The mesh gives no delivery receipt, so "sent" can only ever mean
        // "some peer took it". Reaching nobody is the honest common case in
        // an empty cell — the service keeps re-spraying until they answer.
        _notice = reached > 0
            ? 'Friend request sent to @$username'
            : 'No devices in range — @$username will get it when one is';
        _search.clear();
      });
    } on DirectoryException catch (e) {
      setState(() => _notice = e.message);
    } catch (e) {
      setState(() => _notice = 'Could not reach the directory: $e');
    }
  }

  Future<void> _accept(String username) async {
    final c = FireflyTheme.of(context);
    // Friendship consent and location consent are separate questions.
    final share = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        child: FireflyTheme(
          colors: c,
          child: GlassPanel(
            radius: 24,
            strong: true,
            blur: 28,
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Accept @$username?',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: c.text)),
                const SizedBox(height: 8),
                Text(
                    'Also share your location with them? You can change '
                    'this per friend at any time.',
                    style: TextStyle(fontSize: 13, color: c.dim)),
                const SizedBox(height: 16),
                AccentButton(
                    icon: Icons.my_location_rounded,
                    label: 'Accept + share location',
                    onTap: () => Navigator.pop(dialogContext, true)),
                const SizedBox(height: 8),
                GhostButton(
                    icon: Icons.check_rounded,
                    label: 'Accept only',
                    onTap: () => Navigator.pop(dialogContext, false)),
              ],
            ),
          ),
        ),
      ),
    );
    if (share == null) return;
    await _c.friends.accept(username, shareLocation: share);
    setState(() => _notice = 'You and @$username are now friends');
  }

  @override
  Widget build(BuildContext context) {
    final c = FireflyTheme.of(context);
    final requests = _c.friends.pendingRequests;
    final friends = _c.friends.friends;

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
                Text('Friends',
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: c.text)),
                const Spacer(),
                closeButton(context, widget.onClose),
              ],
            ),
          ),
          // add friend
          Container(
            margin: const EdgeInsets.fromLTRB(2, 0, 2, 10),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: c.glassLo,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: c.stroke),
            ),
            child: Row(
              children: [
                Icon(Icons.person_add_alt_rounded, size: 19, color: c.faint),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _search,
                    style: TextStyle(fontSize: 13, color: c.text),
                    decoration: InputDecoration(
                      hintText: 'Add @username via mesh directory',
                      hintStyle: TextStyle(fontSize: 13, color: c.faint),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding:
                          const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onSubmitted: (_) => _addFriend(),
                  ),
                ),
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
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
              children: [
                if (requests.isNotEmpty) ...[
                  _sectionLabel(c, 'REQUESTS'),
                  for (final entry in requests)
                    _requestRow(c, entry.record.peerUsername),
                  const SizedBox(height: 8),
                ],
                if (friends.isEmpty && requests.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('No friends yet — add one by username.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, color: c.dim)),
                  ),
                for (final entry in friends)
                  _friendRow(c, entry.record.peerUsername),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(FfColors c, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 2, 6, 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(text,
              style: TextStyle(
                  fontSize: 11, letterSpacing: 1.5, color: c.faint)),
        ),
      );

  Widget _requestRow(FfColors c, String username) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        gradient: c.glass(),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.accentLine),
      ),
      child: Row(
        children: [
          InitialAvatar(name: username, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(username,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: c.text)),
                Text('wants to be friends',
                    style: TextStyle(fontSize: 12, color: c.dim)),
              ],
            ),
          ),
          GestureDetector(
            onTap: () => _accept(username),
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                  shape: BoxShape.circle, color: c.accent,
                  boxShadow: [BoxShadow(color: c.accentGlow, blurRadius: 10)]),
              child: Icon(Icons.check_rounded, size: 19, color: c.accentInk),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => _c.friends.decline(username),
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: c.glassLo,
                  border: Border.all(color: c.stroke)),
              child: Icon(Icons.close_rounded, size: 18, color: c.dim),
            ),
          ),
        ],
      ),
    );
  }

  Widget _friendRow(FfColors c, String username) {
    final unread = _c.unread[username] ?? 0;
    final visible = _c.isVisible(username);
    return GestureDetector(
      onTap: () => widget.onOpen(username),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          gradient: c.glass(),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: c.stroke),
        ),
        child: Row(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                InitialAvatar(name: username, size: 40),
                if (unread > 0)
                  Positioned(
                    top: -3,
                    right: -3,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 16),
                      height: 16,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                          color: c.accent,
                          borderRadius: BorderRadius.circular(999)),
                      alignment: Alignment.center,
                      child: Text('$unread',
                          style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: c.accentInk)),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('@$username',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: c.text)),
                  Text(
                      visible
                          ? _c.detailOf(username)
                          : 'hidden from map',
                      style: TextStyle(fontSize: 12, color: c.dim)),
                ],
              ),
            ),
            Tooltip(
              message: 'Show on map',
              child: GlassSwitch(
                value: visible,
                width: 40,
                onChanged: (on) => _c.setVisible(username, on),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
