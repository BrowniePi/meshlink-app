import 'dart:math';

import 'package:flutter/material.dart';

import '../firefly_controller.dart';
import '../firefly_theme.dart';
import '../glass.dart';

/// Accent primary button (Message / Message all).
class AccentButton extends StatelessWidget {
  const AccentButton({super.key, required this.icon, required this.label,
      required this.onTap, this.badge = 0});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final c = FireflyTheme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: BoxDecoration(
          color: c.accent,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: c.accentGlow, blurRadius: 16)],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: c.accentInk),
            const SizedBox(width: 8),
            Text(label,
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: c.accentInk)),
            if (badge > 0) ...[
              const SizedBox(width: 8),
              Container(
                constraints: const BoxConstraints(minWidth: 19),
                height: 19,
                padding: const EdgeInsets.symmetric(horizontal: 5),
                decoration: BoxDecoration(
                  color: c.accentInk,
                  borderRadius: BorderRadius.circular(999),
                ),
                alignment: Alignment.center,
                child: Text('$badge',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: c.accent)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Glass secondary button (Find / Find group).
class GhostButton extends StatelessWidget {
  const GhostButton({super.key, required this.icon, required this.label,
      required this.onTap, this.enabled = true});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final c = FireflyTheme.of(context);
    return Opacity(
      opacity: enabled ? 1 : .45,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 13),
          decoration: BoxDecoration(
            gradient: c.glass(),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: c.stroke2),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: c.accent),
              const SizedBox(width: 8),
              Text(label,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: c.text)),
            ],
          ),
        ),
      ),
    );
  }
}

Widget closeButton(BuildContext context, VoidCallback onTap) {
  final c = FireflyTheme.of(context);
  return GestureDetector(
    onTap: onTap,
    child: Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(shape: BoxShape.circle, color: c.glassLo),
      child: Icon(Icons.close_rounded, size: 18, color: c.dim),
    ),
  );
}

/// Bottom sheet card for one friend: identity, live detail line, the
/// "share my location" toggle, and Message / Find actions.
class FriendCardSheet extends StatelessWidget {
  const FriendCardSheet({
    super.key,
    required this.controller,
    required this.username,
    required this.onClose,
    required this.onChat,
    required this.onFind,
  });

  final FireflyController controller;
  final String username;
  final VoidCallback onClose;
  final VoidCallback onChat;
  final VoidCallback onFind;

  @override
  Widget build(BuildContext context) {
    final c = FireflyTheme.of(context);
    final entry = controller.friends.store.byUsername(username);
    final sharing = entry?.record.locationSharingEnabled ?? false;
    final unread = controller.unread[username] ?? 0;
    final canFind = controller.worldOf(username) != null;

    return GlassPanel(
      radius: 28,
      strong: true,
      blur: 28,
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              InitialAvatar(name: username, size: 54),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(username,
                        style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: c.text)),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(Icons.near_me_rounded,
                            size: 15, color: c.accent),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(controller.detailOf(username),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  TextStyle(fontSize: 13, color: c.dim)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              closeButton(context, onClose),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              gradient: c.glass(),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: c.stroke),
            ),
            child: Row(
              children: [
                Icon(Icons.my_location_rounded, size: 17, color: c.dim),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('Share my location with them',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: c.text)),
                ),
                GlassSwitch(
                  value: sharing,
                  width: 40,
                  onChanged: (on) => on
                      ? controller.friends.enableLocationSharing(username)
                      : controller.friends.disableLocationSharing(username),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: AccentButton(
                    icon: Icons.chat_bubble_rounded,
                    label: 'Message',
                    badge: unread,
                    onTap: onChat),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: GhostButton(
                    icon: Icons.explore_rounded,
                    label: 'Find',
                    enabled: canFind,
                    onTap: onFind),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Bottom sheet for a cluster of friends: stacked avatars, member rows with
/// per-member chat, and Message all / Find group.
class GroupCardSheet extends StatelessWidget {
  const GroupCardSheet({
    super.key,
    required this.controller,
    required this.members,
    required this.onClose,
    required this.onMemberChat,
    required this.onChatAll,
    required this.onFind,
  });

  final FireflyController controller;
  final List<String> members;
  final VoidCallback onClose;
  final ValueChanged<String> onMemberChat;
  final VoidCallback onChatAll;
  final VoidCallback onFind;

  String get _groupName {
    final first = [for (final m in members) m.split(' ').first];
    if (first.length > 2) {
      return '${first.sublist(0, first.length - 1).join(', ')} & ${first.last}';
    }
    return first.join(' & ');
  }

  @override
  Widget build(BuildContext context) {
    final c = FireflyTheme.of(context);
    return GlassPanel(
      radius: 28,
      strong: true,
      blur: 28,
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 38.0 + 26 * (min(3, members.length) - 1),
                  height: 38,
                  child: Stack(
                    children: [
                      for (var i = 0; i < min(3, members.length); i++)
                        Positioned(
                          left: i * 26,
                          child: InitialAvatar(
                              name: members[i], size: 38, ringColor: c.edge),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_groupName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: c.text)),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Icon(Icons.near_me_rounded,
                              size: 14, color: c.accent),
                          const SizedBox(width: 5),
                          Text('${members.length} friends together',
                              style: TextStyle(fontSize: 12, color: c.dim)),
                        ],
                      ),
                    ],
                  ),
                ),
                closeButton(context, onClose),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  for (final m in members)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: GestureDetector(
                        onTap: () => onMemberChat(m),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 9),
                          decoration: BoxDecoration(
                            gradient: c.glass(),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: c.stroke),
                          ),
                          child: Row(
                            children: [
                              InitialAvatar(name: m, size: 34),
                              const SizedBox(width: 11),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(m,
                                        style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                            color: c.text)),
                                    Text(controller.detailOf(m),
                                        style: TextStyle(
                                            fontSize: 11, color: c.dim)),
                                  ],
                                ),
                              ),
                              if ((controller.unread[m] ?? 0) > 0)
                                Container(
                                  constraints:
                                      const BoxConstraints(minWidth: 17),
                                  height: 17,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 4),
                                  margin: const EdgeInsets.only(right: 8),
                                  decoration: BoxDecoration(
                                    color: c.accent,
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text('${controller.unread[m]}',
                                      style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                          color: c.accentInk)),
                                ),
                              Icon(Icons.chat_bubble_outline_rounded,
                                  size: 17, color: c.faint),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: AccentButton(
                    icon: Icons.forum_rounded,
                    label: 'Message all',
                    onTap: onChatAll),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: GhostButton(
                    icon: Icons.explore_rounded,
                    label: 'Find group',
                    onTap: onFind),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
