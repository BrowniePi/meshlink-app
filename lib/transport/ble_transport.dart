import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../debug/debug_log.dart' as dbg;
import 'transport.dart';

/// MeshLink GATT layout — must match ios/Runner/BleManager.swift and any
/// future Android peripheral implementation.
const String meshServiceUuid = '4d455348-4c49-4e4b-0001-000000000001';

/// Remote centrals write inbound packets here (we write when acting as central).
const String rxCharUuid = '4d455348-4c49-4e4b-0002-000000000002';

/// Peripheral notifies outbound packets here (we subscribe when acting as central).
const String txCharUuid = '4d455348-4c49-4e4b-0003-000000000003';

/// Concrete BLE transport satisfying the Phase 0 `Transport` contract
/// (mirror of meshlink-core/transport/base.py). Swapping the Phase 0
/// socket transport for this class is the only change the relay pipeline
/// sees — pipeline and routing logic are untouched.
///
/// Interface → BLE mapping:
///  - `start()` — starts native peripheral advertising (GATT server via the
///    `meshlink/ble_peripheral` platform channel; iOS: CBPeripheralManager)
///    and a flutter_blue_plus central scan loop for the MeshLink service
///    UUID, connecting to every peer found.
///  - `send()` — central-role peers: GATT characteristic write
///    (write-without-response) to the peer's RX characteristic, fragmented
///    to the negotiated MTU; peripheral-role peers (centrals connected to
///    us): a notify on our TX characteristic via the platform channel.
///  - `onReceive()` — invoked on reassembled packets arriving either as
///    notifications from a connected peripheral or as writes from a remote
///    central (via the platform channel).
///  - `listPeers()` — union of connected peripherals (central role) and
///    subscribed centrals (peripheral role).
///
/// Framing: BLE 5.0 with negotiated MTU 247 carries 244-byte fragments, so a
/// max 460-byte MeshLink packet needs at most two writes (spec §1). Each
/// packet is prefixed with a 2-byte big-endian total length; the receiver
/// buffers per peer until that many bytes have arrived.
class BleTransport implements Transport {
  BleTransport({this.scanInterval = const Duration(seconds: 20)});

  final Duration scanInterval;

  static const MethodChannel _peripheral =
      MethodChannel('meshlink/ble_peripheral');

  ReceiveCallback? _callback;
  bool _running = false;
  Timer? _scanTimer;
  StreamSubscription<List<ScanResult>>? _scanSub;

  /// Peripherals we connected to as a central: peerId -> characteristic to
  /// write outbound packets to.
  final Map<String, BluetoothCharacteristic> _centralLinks = {};
  final Map<String, StreamSubscription<BluetoothConnectionState>> _connSubs = {};
  final Map<String, StreamSubscription<List<int>>> _notifySubs = {};
  final Set<String> _connecting = {};

  /// Centrals subscribed to our native peripheral: bare central UUIDs.
  final Set<String> _peripheralLinks = {};

  /// Per-peer reassembly buffers (2-byte BE length prefix framing).
  final Map<String, BytesBuilder> _rxBuffers = {};

  static const String _centralPrefix = 'central:'; // peers linked to our GATT server
  static const String _blePrefix = 'ble:'; // peripherals we connected to

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    dbg.DebugLog.instance.log('transport', 'starting BLE transport');

    if (await FlutterBluePlus.isSupported == false) {
      _running = false;
      dbg.DebugLog.instance.log('transport', 'BLE not supported on this device',
          level: dbg.LogLevel.error);
      throw StateError('BLE not supported on this device');
    }

    if (Platform.isIOS) {
      // CBCentralManagerOptionRestoreIdentifierKey for the plugin's central —
      // see ios/README.md. Must be set before any other plugin call.
      await FlutterBluePlus.setOptions(restoreState: true);
    }

    // Peripheral role: publish GATT server + advertise (native side).
    _peripheral.setMethodCallHandler(_onPeripheralEvent);
    try {
      await _peripheral.invokeMethod<void>('start');
      dbg.DebugLog.instance.log('peripheral', 'GATT server advertising started');
    } on MissingPluginException {
      // No native peripheral on this platform yet (e.g. Android peripheral
      // lands with the two-phone demo hardening) — central role still works.
      dbg.DebugLog.instance.log(
          'peripheral', 'no native peripheral on this platform (central only)',
          level: dbg.LogLevel.warn);
    }

    // Central role: scan for the MeshLink service and connect to peers.
    _scanSub = FlutterBluePlus.scanResults.listen(_onScanResults);
    await _startScan();
    _scanTimer = Timer.periodic(scanInterval, (_) => _startScan());
  }

  @override
  Future<void> stop() async {
    _running = false;
    _scanTimer?.cancel();
    _scanTimer = null;
    await _scanSub?.cancel();
    _scanSub = null;
    await FlutterBluePlus.stopScan();
    try {
      await _peripheral.invokeMethod<void>('stop');
    } on MissingPluginException {
      // ignore: platform has no peripheral side
    }
    for (final sub in _notifySubs.values) {
      await sub.cancel();
    }
    _notifySubs.clear();
    for (final sub in _connSubs.values) {
      await sub.cancel();
    }
    _connSubs.clear();
    for (final device in FlutterBluePlus.connectedDevices) {
      await device.disconnect();
    }
    _centralLinks.clear();
    _peripheralLinks.clear();
    _rxBuffers.clear();
    _connecting.clear();
  }

  @override
  Future<void> send(String peerId, Uint8List data) async {
    dbg.DebugLog.instance.log('tx', '${data.length}B → $peerId');
    final framed = _frame(data);
    if (peerId.startsWith(_centralPrefix)) {
      // Peer is a central subscribed to our GATT server: notify natively.
      await _peripheral.invokeMethod<void>('notify', {
        'centralId': peerId.substring(_centralPrefix.length),
        'data': framed,
      });
      return;
    }
    final characteristic = _centralLinks[peerId];
    if (characteristic == null) {
      throw StateError('unknown or disconnected peer: $peerId');
    }
    // MTU minus 3 bytes ATT header; at MTU 247 a 460-byte packet is 2 writes.
    final mtu = characteristic.device.mtuNow;
    final chunkSize = (mtu - 3).clamp(20, 244);
    for (var off = 0; off < framed.length; off += chunkSize) {
      final end =
          off + chunkSize < framed.length ? off + chunkSize : framed.length;
      await characteristic.write(
        framed.sublist(off, end),
        withoutResponse: characteristic.properties.writeWithoutResponse,
      );
    }
  }

  @override
  void onReceive(ReceiveCallback callback) {
    _callback = callback;
  }

  @override
  List<String> listPeers() => [
        ..._centralLinks.keys,
        ..._peripheralLinks.map((id) => '$_centralPrefix$id'),
      ];

  // ---- peripheral role (native GATT server) events ----

  Future<dynamic> _onPeripheralEvent(MethodCall call) async {
    switch (call.method) {
      case 'onWrite':
        final args = (call.arguments as Map).cast<String, dynamic>();
        final id = '$_centralPrefix${args['centralId'] as String}';
        _onChunk(id, args['data'] as Uint8List);
      case 'onSubscribe':
        final id = call.arguments as String;
        _peripheralLinks.add(id);
        dbg.DebugLog.instance.log('conn', 'central subscribed: $id');
      case 'onUnsubscribe':
        final id = call.arguments as String;
        _peripheralLinks.remove(id);
        _rxBuffers.remove('$_centralPrefix$id');
        dbg.DebugLog.instance.log('conn', 'central unsubscribed: $id');
      case 'onRestored':
      case 'onStateChanged':
        // Informational; advertising restart is handled natively.
        break;
    }
    return null;
  }

  // ---- central role (flutter_blue_plus) ----

  Future<void> _startScan() async {
    if (!_running || FlutterBluePlus.isScanningNow) return;
    try {
      await FlutterBluePlus.startScan(
        withServices: [Guid(meshServiceUuid)],
        timeout: const Duration(seconds: 10),
      );
      dbg.DebugLog.instance.log('scan', 'scanning for MeshLink service');
    } catch (_) {
      // Bluetooth off / permission denied: retry on the next scan tick
      // rather than crashing the relay loop.
      dbg.DebugLog.instance.log(
          'scan', 'scan failed (Bluetooth off or permission denied)',
          level: dbg.LogLevel.warn);
    }
  }

  void _onScanResults(List<ScanResult> results) {
    for (final result in results) {
      _connectTo(result.device);
    }
  }

  Future<void> _connectTo(BluetoothDevice device) async {
    final peerId = '$_blePrefix${device.remoteId.str}';
    if (_centralLinks.containsKey(peerId) || !_connecting.add(peerId)) {
      return;
    }
    dbg.DebugLog.instance.log('conn', 'connecting to $peerId');
    try {
      _connSubs[peerId] ??= device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          dbg.DebugLog.instance.log('conn', 'disconnected: $peerId');
          _dropPeer(peerId);
        }
      });
      // License.nonprofit: MeshLink is a non-commercial student project,
      // per flutter_blue_plus's dual-license terms.
      await device.connect(mtu: 247, license: License.nonprofit);

      final services = await device.discoverServices();
      BluetoothCharacteristic? rx;
      BluetoothCharacteristic? tx;
      for (final service in services) {
        if (service.uuid != Guid(meshServiceUuid)) continue;
        for (final c in service.characteristics) {
          if (c.uuid == Guid(rxCharUuid)) rx = c;
          if (c.uuid == Guid(txCharUuid)) tx = c;
        }
      }
      if (rx == null || tx == null) {
        dbg.DebugLog.instance.log(
            'conn', 'peer missing MeshLink characteristics: $peerId',
            level: dbg.LogLevel.warn);
        await device.disconnect();
        return;
      }

      await tx.setNotifyValue(true);
      _notifySubs[peerId] = tx.onValueReceived.listen((value) {
        _onChunk(peerId, Uint8List.fromList(value));
      });
      _centralLinks[peerId] = rx;
      dbg.DebugLog.instance
          .log('conn', 'connected to $peerId (mtu ${device.mtuNow})');
    } catch (_) {
      // Peer went out of range mid-handshake or GATT error: forget it; the
      // scan loop will find it again if it comes back.
      dbg.DebugLog.instance
          .log('conn', 'connect failed: $peerId', level: dbg.LogLevel.warn);
      _dropPeer(peerId);
    } finally {
      _connecting.remove(peerId);
    }
  }

  void _dropPeer(String peerId) {
    _centralLinks.remove(peerId);
    _rxBuffers.remove(peerId);
    _notifySubs.remove(peerId)?.cancel();
    _connSubs.remove(peerId)?.cancel();
  }

  // ---- framing ----

  Uint8List _frame(Uint8List packet) {
    final framed = Uint8List(2 + packet.length);
    ByteData.sublistView(framed).setUint16(0, packet.length);
    framed.setRange(2, framed.length, packet);
    return framed;
  }

  void _onChunk(String peerId, Uint8List chunk) {
    final buffer = _rxBuffers.putIfAbsent(peerId, BytesBuilder.new)..add(chunk);
    while (true) {
      final bytes = buffer.toBytes();
      if (bytes.length < 2) return;
      final total = ByteData.sublistView(bytes).getUint16(0);
      if (bytes.length < 2 + total) return;
      final packet = Uint8List.sublistView(bytes, 2, 2 + total);
      buffer
        ..clear()
        ..add(Uint8List.sublistView(bytes, 2 + total));
      dbg.DebugLog.instance.log('rx', '${packet.length}B ← $peerId');
      _callback?.call(peerId, packet);
    }
  }
}
