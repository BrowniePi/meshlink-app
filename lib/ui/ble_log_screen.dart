import 'package:flutter/material.dart';

import '../debug/debug_log.dart';

/// Live view of the transport/BLE event log ([DebugLog]). Newest at the
/// bottom; auto-follows as new events arrive.
class BleLogScreen extends StatelessWidget {
  const BleLogScreen({super.key});

  Color _color(BuildContext context, LogLevel level) {
    final scheme = Theme.of(context).colorScheme;
    return switch (level) {
      LogLevel.info => scheme.onSurfaceVariant,
      LogLevel.warn => Colors.orange,
      LogLevel.error => scheme.error,
    };
  }

  String _time(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}'
      ':${t.second.toString().padLeft(2, '0')}.${(t.millisecond ~/ 100)}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bluetooth logs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear',
            onPressed: DebugLog.instance.clear,
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: DebugLog.instance,
        builder: (context, _) {
          final entries = DebugLog.instance.entries;
          if (entries.isEmpty) {
            return const Center(child: Text('No events yet'));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(8),
            itemCount: entries.length,
            itemBuilder: (context, i) {
              final e = entries[i];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: SelectableText.rich(
                  TextSpan(
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12, height: 1.3),
                    children: [
                      TextSpan(
                        text: '${_time(e.time)}  ',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.outline),
                      ),
                      TextSpan(
                        text: '[${e.tag}] ',
                        style: TextStyle(
                            color: _color(context, e.level),
                            fontWeight: FontWeight.bold),
                      ),
                      TextSpan(
                        text: e.message,
                        style: TextStyle(color: _color(context, e.level)),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
