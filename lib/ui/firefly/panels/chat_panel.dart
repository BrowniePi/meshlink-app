import 'dart:math';

import 'package:flutter/material.dart';

import '../../../friends/friend_store.dart';
import '../firefly_controller.dart';
import '../firefly_logo.dart';
import '../firefly_theme.dart';
import '../glass.dart';

class _Line {
  _Line({required this.msg, required this.from});
  final DirectMessage msg;

  /// Sender username for incoming group messages; null otherwise.
  final String? from;
}

/// Chat sheet — 1:1 DMs over the mesh, or a group view. Groups are a
/// client-side fan-out: "send" delivers the same sealed DM to each member
/// individually, and the thread is the merged view of those conversations.
class ChatPanel extends StatefulWidget {
  const ChatPanel({
    super.key,
    required this.controller,
    required this.isGroup,
    required this.username,
    required this.groupUsers,
    required this.onBack,
    required this.onFind,
  });

  final FireflyController controller;
  final bool isGroup;
  final String? username;
  final List<String> groupUsers;
  final VoidCallback onBack;
  final VoidCallback onFind;

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  String? _notice;
  int _lastCount = -1;

  FireflyController get _c => widget.controller;

  List<String> get _members =>
      widget.isGroup ? widget.groupUsers : [widget.username!];

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<_Line> _lines() {
    final lines = <_Line>[];
    for (final u in _members) {
      final entry = _c.friends.store.byUsername(u);
      if (entry == null) continue;
      for (final m in entry.messages) {
        // In a group view, our fanned-out copies exist once per member —
        // show each outgoing text only once (from the first member's log).
        if (widget.isGroup && m.outgoing && u != _members.first) continue;
        lines.add(_Line(
            msg: m, from: widget.isGroup && !m.outgoing ? u : null));
      }
    }
    lines.sort((a, b) => a.msg.at.compareTo(b.msg.at));
    return lines;
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    for (final u in _members) {
      final error = await _c.sendDm(u, text);
      if (error != null && mounted) {
        setState(() => _notice = error);
        return;
      }
    }
    if (mounted) setState(() => _notice = null);
  }

  void _autoScroll(int count) {
    if (count == _lastCount) return;
    _lastCount = count;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = FireflyTheme.of(context);
    final lines = _lines();
    _autoScroll(lines.length);

    final title = widget.isGroup ? _groupName() : widget.username!;
    final detail = widget.isGroup
        ? '${_members.length} people · mesh group'
        : _c.detailOf(widget.username!);

    return GlassPanel(
      radius: 32,
      strong: true,
      blur: 30,
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          // header
          Container(
            padding: const EdgeInsets.fromLTRB(14, 16, 18, 12),
            decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: c.stroke))),
            child: Row(
              children: [
                GestureDetector(
                  onTap: widget.onBack,
                  child: SizedBox(
                    width: 36,
                    height: 36,
                    child: Icon(Icons.arrow_back_ios_new_rounded,
                        size: 20, color: c.dim),
                  ),
                ),
                SizedBox(
                  width: 36.0 + 24 * (min(3, _members.length) - 1),
                  height: 36,
                  child: Stack(
                    children: [
                      for (var i = 0; i < min(3, _members.length); i++)
                        Positioned(
                          left: i * 24,
                          child: InitialAvatar(
                              name: _members[i], size: 36,
                              ringColor: c.edge),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: c.text)),
                      Text(detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: c.dim)),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: widget.onFind,
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle, color: c.glassLo),
                    child: Icon(Icons.explore_rounded,
                        size: 19, color: c.accent),
                  ),
                ),
              ],
            ),
          ),
          // messages
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              children: [
                Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      color: c.glassLo,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: c.stroke),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.lock_rounded, size: 13, color: c.faint),
                        const SizedBox(width: 5),
                        Text(
                            _c.wifiOn
                                ? 'turbo link to node · end-to-end encrypted'
                                : 'relayed over BLE mesh · end-to-end encrypted',
                            style:
                                TextStyle(fontSize: 11, color: c.faint)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                if (lines.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 60),
                    child: Column(
                      children: [
                        const FireflyLogo(size: 44, glow: .6),
                        const SizedBox(height: 10),
                        Text('Say hi over the mesh',
                            style:
                                TextStyle(fontSize: 13, color: c.faint)),
                      ],
                    ),
                  ),
                for (final line in lines) _bubble(c, line),
              ],
            ),
          ),
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(_notice!,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFFFF8A80))),
            ),
          // input
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 24),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.only(left: 16, right: 6),
                    decoration: BoxDecoration(
                      gradient: c.glass(strong: true),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: c.stroke2),
                    ),
                    child: TextField(
                      controller: _input,
                      style: TextStyle(fontSize: 14, color: c.text),
                      decoration: InputDecoration(
                        hintText: 'Message…',
                        hintStyle:
                            TextStyle(fontSize: 14, color: c.faint),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 15),
                      ),
                      onSubmitted: (_) => _send(),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Opacity(
                  opacity: _input.text.trim().isEmpty ? .45 : 1,
                  child: GlassIconButton(
                    icon: Icons.send_rounded,
                    size: 46,
                    iconSize: 21,
                    filled: true,
                    onTap: _send,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _groupName() {
    final first = [for (final m in _members) m.split(' ').first];
    if (first.length > 2) {
      return '${first.sublist(0, first.length - 1).join(', ')} & ${first.last}';
    }
    return first.join(' & ');
  }

  Widget _bubble(FfColors c, _Line line) {
    final m = line.msg;
    final mine = m.outgoing;
    final (IconData?, Color) tick = switch (m.status) {
      DmStatus.sending => (Icons.schedule_rounded, c.faint),
      DmStatus.relayed => (Icons.check_rounded, c.dim),
      DmStatus.failed => (Icons.error_outline_rounded,
          const Color(0xFFFF8A80)),
      null => (null, Colors.transparent),
    };
    final time =
        '${m.at.hour.toString().padLeft(2, '0')}:${m.at.minute.toString().padLeft(2, '0')}';

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * .68),
        child: Column(
          crossAxisAlignment:
              mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (line.from != null)
              Padding(
                padding: const EdgeInsets.only(left: 6, top: 4),
                child: Text(line.from!,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: c.dim)),
              ),
            Container(
              margin: const EdgeInsets.symmetric(vertical: 2),
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: mine
                      ? const [Color(0x38E6B34D), Color(0x12E6B34D)]
                      : [c.bubbleInHi, c.bubbleInLo],
                ),
                border: Border.all(
                    color: mine ? c.accentLine : c.stroke),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(18),
                  topRight: const Radius.circular(18),
                  bottomLeft: Radius.circular(mine ? 18 : 6),
                  bottomRight: Radius.circular(mine ? 6 : 18),
                ),
              ),
              child: Text(m.text,
                  style: TextStyle(
                      fontSize: 14, height: 1.45, color: c.text)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(time,
                      style: TextStyle(fontSize: 10, color: c.faint)),
                  // Transport badge: cloud = the online backend carried it
                  // (alone or alongside a mesh spray), no badge = mesh only
                  // (the default story).
                  if (m.via != DmVia.mesh) ...[
                    const SizedBox(width: 4),
                    Icon(Icons.cloud_outlined, size: 12, color: c.faint),
                  ],
                  if (mine && tick.$1 != null) ...[
                    const SizedBox(width: 4),
                    Icon(tick.$1, size: 14, color: tick.$2),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
