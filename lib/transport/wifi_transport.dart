import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../config/wifi_config.dart';
import '../debug/debug_log.dart' as dbg;
import 'transport.dart';
import 'wifi/wifi_join.dart';

/// Concrete WiFi transport — the second `Transport` implementation after
/// [BleTransport], and the direct test of the Phase 0 abstraction: the relay
/// pipeline uses it with zero changes.
///
/// Interface → WiFi mapping:
///  - `start()` — joins the mesh SSID via the platform's app-scoped join API
///    ([WifiJoin]), then holds one TCP connection to the serving node's
///    listener (meshlink-node node/transport/wifi_transport.py). Reconnects
///    with a short backoff while running — roaming to another node's BSSID
///    lands on the same 10.78.0.1 address on the new node's subnet.
///  - `send()`/`onReceive()` — packets in both directions carry the same
///    2-byte big-endian length prefix as the BLE path; one TCP stream
///    replaces notify/write.
///  - `listPeers()` — the single serving node, present only while the
///    connection is up. There are no phone-to-phone WiFi peers.
class WifiTransport implements Transport {
  WifiTransport({
    required this.config,
    WifiJoin? join,
    this.reconnectDelay = const Duration(seconds: 3),
  }) : _join = join ?? WifiJoin.forPlatform();

  final WifiConfig config;
  final WifiJoin _join;
  final Duration reconnectDelay;

  ReceiveCallback? _callback;
  bool _running = false;
  Socket? _socket;
  StreamSubscription<Uint8List>? _socketSub;
  Timer? _reconnectTimer;
  final BytesBuilder _rxBuffer = BytesBuilder();

  String get _peerId => 'wifi:${config.nodeHost}:${config.nodePort}';

  /// Exposed for the toggle's pre-join state check (current SSID / WiFi
  /// Calling), which must run before this transport joins the mesh.
  WifiJoin get join => _join;

  /// True while the node connection is up — the "healthy" signal the
  /// failover transport keys off.
  bool get connected => _socket != null;

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    dbg.DebugLog.instance.log('wifi', 'starting WiFi transport');
    _join.onLost(() {
      // OS dropped the mesh network (out of range / radio off): tear down
      // the socket now; the reconnect loop keeps trying while running, so a
      // transient loss (roaming gap) heals itself. BLE covers the gap.
      _teardownSocket();
      _scheduleReconnect();
    });
    await _join.join(config.ssid, config.passphrase);
    // Joining the SSID is what start() guarantees; the node connection
    // establishes in the background (with retries) — BLE keeps relaying
    // until it's up, per the fallback design rule.
    unawaited(_connect());
  }

  @override
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _teardownSocket();
    await _join.leave();
    dbg.DebugLog.instance.log('wifi', 'WiFi transport stopped');
  }

  @override
  Future<void> send(String peerId, Uint8List data) async {
    final socket = _socket;
    if (peerId != _peerId || socket == null) {
      throw StateError('unknown or disconnected peer: $peerId');
    }
    dbg.DebugLog.instance.log('tx', '${data.length}B → $peerId (wifi)');
    final framed = Uint8List(2 + data.length);
    ByteData.sublistView(framed).setUint16(0, data.length);
    framed.setRange(2, framed.length, data);
    socket.add(framed);
  }

  @override
  void onReceive(ReceiveCallback callback) {
    _callback = callback;
  }

  @override
  List<String> listPeers() => connected ? [_peerId] : [];

  // ---- node connection ----

  Future<void> _connect() async {
    if (!_running || _socket != null) return;
    try {
      final socket = await Socket.connect(
        config.nodeHost,
        config.nodePort,
        timeout: const Duration(seconds: 5),
      );
      if (!_running) {
        // stop() raced the connect: don't resurrect the connection.
        socket.destroy();
        return;
      }
      socket.setOption(SocketOption.tcpNoDelay, true);
      _socket = socket;
      _rxBuffer.clear();
      _socketSub = socket.listen(
        _onBytes,
        onDone: _onSocketClosed,
        onError: (_) => _onSocketClosed(),
      );
      dbg.DebugLog.instance.log('wifi', 'connected to node $_peerId');
    } catch (_) {
      dbg.DebugLog.instance.log(
          'wifi', 'node connect failed, retrying in ${reconnectDelay.inSeconds}s',
          level: dbg.LogLevel.warn);
      _scheduleReconnect();
    }
  }

  void _onSocketClosed() {
    dbg.DebugLog.instance
        .log('wifi', 'node connection lost', level: dbg.LogLevel.warn);
    _teardownSocket();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!_running || _reconnectTimer != null) return;
    _reconnectTimer = Timer(reconnectDelay, () {
      _reconnectTimer = null;
      _connect();
    });
  }

  void _teardownSocket() {
    _socketSub?.cancel();
    _socketSub = null;
    _socket?.destroy();
    _socket = null;
    _rxBuffer.clear();
  }

  void _onBytes(Uint8List chunk) {
    _rxBuffer.add(chunk);
    while (true) {
      final bytes = _rxBuffer.toBytes();
      if (bytes.length < 2) return;
      final total = ByteData.sublistView(bytes).getUint16(0);
      if (bytes.length < 2 + total) return;
      final packet = Uint8List.sublistView(bytes, 2, 2 + total);
      _rxBuffer
        ..clear()
        ..add(Uint8List.sublistView(bytes, 2 + total));
      dbg.DebugLog.instance.log('rx', '${packet.length}B ← $_peerId (wifi)');
      _callback?.call(_peerId, packet);
    }
  }
}
