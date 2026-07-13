import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../debug/debug_log.dart' as dbg;
import 'online_client.dart';

/// How often the fallback poll runs while connected. Every push event has a
/// polling equivalent server-side, so a missed push costs at most one cycle.
const Duration onlinePollInterval = Duration(seconds: 45);

/// Reconnect backoff bounds for the push socket.
const Duration _backoffMin = Duration(seconds: 2);
const Duration _backoffMax = Duration(seconds: 60);

/// Owns the app's "am I online?" truth and the realtime push channel.
///
/// Connectivity is defined by what actually matters — the backend WebSocket
/// being up — not by radio state: venue WiFi with no internet counts as
/// offline, a phone on LTE counts as online. While connected, online is the
/// PRIMARY transport (friend requests, DMs, location) and the mesh is the
/// fallback; disconnected, everything runs over the mesh exactly as before.
///
/// The [handler] (FriendService) is invoked for every push event and on each
/// poll cycle; delivery guarantees live in the polling endpoints, the socket
/// only shortens latency.
abstract class OnlineHandler {
  /// A store-and-forward relay body arrived: [1-byte msgType][wire payload].
  Future<void> onOnlineRelay(String fromUser, Uint8List body);

  /// Friend-request state changed server-side (new request, accept, decline)
  /// — re-sync pending lists.
  Future<void> onFriendEvent();
}

class OnlineService extends ChangeNotifier {
  OnlineService({
    required this.client,
    required this.accessToken,
    required String baseUrl,
    DateTime Function()? now,
  })  : _wsBase = baseUrl.replaceFirst(RegExp(r'^http'), 'ws'),
        _now = now ?? DateTime.now;

  final OnlineClient client;
  final Future<String> Function() accessToken;
  final String _wsBase;
  final DateTime Function() _now;

  OnlineHandler? handler;

  WebSocket? _socket;
  Timer? _reconnectTimer;
  Timer? _pollTimer;
  Duration _backoff = _backoffMin;
  bool _running = false;
  bool _connected = false;

  /// Whether the backend push channel is up right now — THE online/mesh
  /// mode switch, and what the UI indicator shows.
  bool get connected => _connected;

  /// Instant of the last connectivity flip, for "online since"/"offline
  /// since" UI copy.
  DateTime? lastChangeAt;

  /// Start keeping the push socket up (call after login). Idempotent.
  void start() {
    if (_running) return;
    _running = true;
    unawaited(_connect());
  }

  /// Tear down (logout). The next [start] begins a fresh session.
  void stop() {
    _running = false;
    _reconnectTimer?.cancel();
    _pollTimer?.cancel();
    _socket?.close();
    _socket = null;
    _setConnected(false);
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }

  Future<void> _connect() async {
    if (!_running || _socket != null) return;
    final String token;
    try {
      token = await accessToken();
    } catch (e) {
      _log('no access token ($e) — retrying in $_backoff');
      _scheduleReconnect();
      return;
    }
    try {
      final socket = await WebSocket.connect('$_wsBase/online/ws?token=$token')
          .timeout(const Duration(seconds: 10));
      if (!_running) {
        await socket.close();
        return;
      }
      _socket = socket;
      _backoff = _backoffMin;
      _setConnected(true);
      _log('push socket connected');
      socket.listen(_onFrame, onDone: _onSocketClosed,
          onError: (_) => _onSocketClosed(), cancelOnError: true);
      // Catch up on anything that happened while disconnected, then keep the
      // fallback poll running (it also covers silently dropped pushes).
      _pollTimer?.cancel();
      _pollTimer = Timer.periodic(onlinePollInterval, (_) => _poll());
      unawaited(_poll());
    } catch (e) {
      _log('connect failed ($e) — retrying in $_backoff');
      _scheduleReconnect();
    }
  }

  void _onSocketClosed() {
    _socket = null;
    _pollTimer?.cancel();
    _setConnected(false);
    if (!_running) return;
    _log('push socket closed — reconnecting');
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!_running) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(_backoff, _connect);
    _backoff = _backoff * 2 > _backoffMax ? _backoffMax : _backoff * 2;
  }

  void _onFrame(dynamic frame) {
    final Map<String, dynamic> event;
    try {
      event = jsonDecode(frame as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (event['type']) {
      case 'message':
        // The event carries the full ciphertext, but the inbox poll is the
        // delivery-guaranteed path (fetch + ack); use the push as a trigger.
        unawaited(_poll());
      case 'friend_request' || 'friend_accept' || 'friend_decline':
        unawaited(handler?.onFriendEvent() ?? Future.value());
    }
  }

  bool _polling = false;

  /// Run one catch-up cycle now: drain the message inbox (fetch, handle,
  /// ack) and re-sync friend-request state. The periodic timer calls this;
  /// callers may too (e.g. app resumed from background).
  Future<void> pollNow() => _poll();

  Future<void> _poll() async {
    final h = handler;
    // No overlapping polls: a push-triggered poll racing the periodic one
    // would hand the same not-yet-acked inbox rows to the handler twice.
    if (h == null || !_connected || _polling) return;
    _polling = true;
    try {
      final messages = await client.inbox();
      for (final m in messages) {
        await h.onOnlineRelay(m.fromUser, m.body);
      }
      await client.ackMessages([for (final m in messages) m.id]);
      await h.onFriendEvent();
    } on OnlineException catch (e) {
      _log('poll failed: $e');
    } finally {
      _polling = false;
    }
  }

  void _setConnected(bool value) {
    if (_connected == value) return;
    _connected = value;
    lastChangeAt = _now();
    notifyListeners();
  }

  void _log(String message) => dbg.DebugLog.instance.log('online', message);

  /// Test hook: force the connected flag without a real socket.
  @visibleForTesting
  void debugSetConnected(bool value) => _setConnected(value);
}
