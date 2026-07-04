import 'package:flutter/foundation.dart';

enum LogLevel { info, warn, error }

class LogEntry {
  LogEntry(this.time, this.level, this.tag, this.message);

  final DateTime time;
  final LogLevel level;
  final String tag; // e.g. scan, conn, tx, rx, error
  final String message;
}

/// In-memory ring buffer of transport/BLE events, surfaced by the debug
/// BLE-log screen. Process-lifetime only, never persisted. A single shared
/// [instance] lets the transport log without threading a sink through every
/// constructor.
class DebugLog extends ChangeNotifier {
  DebugLog._();
  static final DebugLog instance = DebugLog._();

  static const int _maxEntries = 500;
  final List<LogEntry> _entries = [];

  List<LogEntry> get entries => List.unmodifiable(_entries);

  void log(String tag, String message, {LogLevel level = LogLevel.info}) {
    _entries.add(LogEntry(DateTime.now(), level, tag, message));
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
    notifyListeners();
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }
}
