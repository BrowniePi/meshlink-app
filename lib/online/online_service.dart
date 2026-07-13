import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../config/backend_config.dart';
import '../debug/debug_log.dart' as dbg;
import 'online_client.dart';

/// How often the fallback poll runs while connected. Every push event has a
/// polling equivalent server-side, so a missed push costs at most one cycle.
const Duration onlinePollInterval = Duration(seconds: 45);

/// Reconnect backoff bounds for the push socket.
const Duration _backoffMin = Duration(seconds: 2);
const Duration _backoffMax = Duration(seconds: 60);

/// Phoenix keepalive: Supabase Realtime drops sockets that go quiet.
const Duration _phoenixHeartbeat = Duration(seconds: 25);

/// Owns the app's "am I online?" truth and the realtime push channel
/// (Supabase Realtime: Postgres change events on relay_messages and
/// friend_requests, RLS-scoped to this account).
///
/// Connectivity is defined by what actually matters — the push socket being
/// up — not by radio state: venue WiFi with no internet counts as offline, a
/// phone on LTE counts as online. While connected, online is the PRIMARY
/// transport (friend requests, DMs, location) and the mesh is the fallback;
/// disconnected, everything runs over the mesh exactly as before.
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
    required BackendConfig config,
    DateTime Function()? now,
  })  : _wsBase = config.baseUrl.replaceFirst(RegExp(r'^http'), 'ws'),
        _anonKey = config.anonKey,
        _now = now ?? DateTime.now;

  final OnlineClient client;
  final Future<String> Function() accessToken;
  final String _wsBase;
  final String _anonKey;
  final DateTime Function() _now;

  OnlineHandler? handler;

  WebSocket? _socket;
  Timer? _reconnectTimer;
  Timer? _pollTimer;
  Timer? _heartbeatTimer;
  int _ref = 0;
  Duration _backoff = _backoffMin;
  bool _running = false;
  bool _connected = false;

  /// Whether the backend push channel is up right now — THE online/mesh
  /// mode switch, and what the UI indicator shows.
  bool get connected => _connected;

  /// REST remains usable through the node's MLBP1 backend proxy even when
  /// the direct Supabase realtime socket is down.
  bool get canRequest => _connected || client.fallbackAvailable;

  /// Instant of the last connectivity flip, for "online since"/"offline
  /// since" UI copy.
  DateTime? lastChangeAt;

  /// Start keeping the push socket up (call after login). Idempotent.
  void start() {
    if (_running) return;
    _running = true;
    _pollTimer = Timer.periodic(onlinePollInterval, (_) => _poll());
    unawaited(_poll());
    unawaited(_connect());
  }

  /// Tear down (logout). The next [start] begins a fresh session.
  void stop() {
    _running = false;
    _reconnectTimer?.cancel();
    _pollTimer?.cancel();
    _heartbeatTimer?.cancel();
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
      final socket = await WebSocket.connect(
              '$_wsBase/realtime/v1/websocket?apikey=$_anonKey&vsn=1.0.0')
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
      _join(socket, token);
      _heartbeatTimer?.cancel();
      _heartbeatTimer = Timer.periodic(
          _phoenixHeartbeat,
          (_) => _send(socket,
              topic: 'phoenix', event: 'heartbeat', payload: const {}));
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

  /// Subscribe to the RLS-scoped change feed. The access token in the join
  /// payload is what lets WALRUS filter rows to this account.
  void _join(WebSocket socket, String token) {
    _send(socket, topic: 'realtime:online', event: 'phx_join', payload: {
      'config': {
        'broadcast': {'self': false},
        'presence': {'key': ''},
        'postgres_changes': [
          {'event': 'INSERT', 'schema': 'public', 'table': 'relay_messages'},
          {'event': '*', 'schema': 'public', 'table': 'friend_requests'},
        ],
      },
      'access_token': token,
    });
  }

  void _send(WebSocket socket,
      {required String topic,
      required String event,
      required Map<String, dynamic> payload}) {
    try {
      socket.add(jsonEncode({
        'topic': topic,
        'event': event,
        'payload': payload,
        'ref': '${_ref++}',
      }));
    } catch (_) {
      // A dying socket surfaces through onDone/onError; nothing to do here.
    }
  }

  void _onSocketClosed() {
    _socket = null;
    _heartbeatTimer?.cancel();
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
    final Map<String, dynamic> envelope;
    try {
      envelope = jsonDecode(frame as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (envelope['event'] != 'postgres_changes') return;
    final payload = envelope['payload'];
    final data = payload is Map<String, dynamic> ? payload['data'] : null;
    final table = data is Map<String, dynamic> ? data['table'] : null;
    switch (table) {
      case 'relay_messages':
        // The event carries the row, but the inbox poll is the
        // delivery-guaranteed path (fetch + ack); use the push as a trigger.
        unawaited(_poll());
      case 'friend_requests':
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
    if (h == null || !canRequest || _polling) return;
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
