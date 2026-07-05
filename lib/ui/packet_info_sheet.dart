import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/message.dart';

String _hex(Uint8List b, {String sep = ''}) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(sep);

/// Bottom sheet showing the on-wire byte layout of [packet] — the fixed
/// 75-byte header fields (with offsets), payload, and 64-byte signature,
/// per docs/message-format.md. If the packet is structurally malformed
/// (e.g. an oversized/forged attack packet) it shows the parse error plus a
/// raw hex dump instead.
Future<void> showPacketInfo(BuildContext context, Uint8List packet) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => PacketInfoSheet(packet: packet),
  );
}

class PacketInfoSheet extends StatelessWidget {
  const PacketInfoSheet({super.key, required this.packet});

  final Uint8List packet;

  @override
  Widget build(BuildContext context) {
    Message? msg;
    String? parseError;
    try {
      msg = parsePacket(packet);
    } on MalformedPacket catch (e) {
      parseError = e.message;
    }

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Text('Packet details',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('${packet.length} bytes on the wire',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 16),
          if (parseError != null)
            _MalformedBody(error: parseError, packet: packet)
          else
            _ParsedBody(msg: msg!),
          const SizedBox(height: 16),
          const Text('Raw hex', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          _HexDump(bytes: packet),
        ],
      ),
    );
  }
}

class _ParsedBody extends StatelessWidget {
  const _ParsedBody({required this.msg});

  final Message msg;

  @override
  Widget build(BuildContext context) {
    final ts = DateTime.fromMillisecondsSinceEpoch(msg.timestamp * 1000);
    final payloadText = utf8.decode(msg.payload, allowMalformed: true);
    final zone = msg.zoneId == 0xFFFF ? '0xFFFF (broadcast)' : '${msg.zoneId}';
    return Column(
      children: [
        _field('msg_id', '0–16', _hex(msg.msgId),
            note: 'BLAKE3 content id'),
        _field('sender_key', '16–48', _hex(msg.senderKey),
            note: 'Ed25519 public key'),
        _field('ephem_id', '48–64', _hex(msg.ephemId),
            note: 'rotating on-air id'),
        _field('timestamp', '64–68', '${msg.timestamp}  (${ts.toLocal()})'),
        _field('ttl', '68', '${msg.ttl}',
            note: 'mutable — excluded from signature'),
        _field('spray_L', '69', '${msg.sprayL}',
            note: 'mutable — excluded from signature'),
        _field('zone_id', '70–72', zone),
        _field('msg_type', '72',
            '0x${msg.msgType.toRadixString(16).padLeft(2, '0')}'),
        _field('payload_len', '73–75', '${msg.payloadLen}'),
        _field('payload', '75–${75 + msg.payloadLen}',
            '"$payloadText"\n${_hex(msg.payload)}'),
        _field('signature', 'last 64', _hex(msg.signature),
            note: 'Ed25519 over all bytes except ttl/spray_L'),
      ],
    );
  }

  Widget _field(String name, String offset, String value, {String? note}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(name,
                  style: const TextStyle(
                      fontFamily: 'monospace', fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              Text('bytes $offset',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
          if (note != null)
            Text(note,
                style: const TextStyle(
                    fontSize: 11, fontStyle: FontStyle.italic, color: Colors.grey)),
          const SizedBox(height: 2),
          SelectableText(value,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ],
      ),
    );
  }
}

class _MalformedBody extends StatelessWidget {
  const _MalformedBody({required this.error, required this.packet});

  final String error;
  final Uint8List packet;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Malformed packet — rejected before parsing',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          SelectableText(error,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ],
      ),
    );
  }
}

class _HexDump extends StatelessWidget {
  const _HexDump({required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    // 16 bytes per line, offset-prefixed.
    final lines = <String>[];
    for (var i = 0; i < bytes.length; i += 16) {
      final end = (i + 16 < bytes.length) ? i + 16 : bytes.length;
      final slice = Uint8List.sublistView(bytes, i, end);
      lines.add('${i.toRadixString(16).padLeft(4, '0')}  ${_hex(slice, sep: ' ')}');
    }
    final dump = lines.join('\n');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: SelectableText(dump,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
        ),
        IconButton(
          icon: const Icon(Icons.copy, size: 18),
          tooltip: 'Copy hex',
          onPressed: () => Clipboard.setData(ClipboardData(text: _hex(bytes))),
        ),
      ],
    );
  }
}
