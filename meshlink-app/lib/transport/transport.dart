import 'dart:typed_data';

typedef ReceiveCallback = void Function(String peerId, Uint8List data);

/// Abstract transport interface — Dart mirror of
/// meshlink-core/transport/base.py. The relay pipeline and routing logic are
/// written against this contract only; swapping the simulated socket
/// transport for real BLE must not require touching them.
abstract class Transport {
  Future<void> start();

  Future<void> stop();

  /// Send raw bytes to a peer identified by [peerId].
  Future<void> send(String peerId, Uint8List data);

  /// Register a callback invoked as callback(peerId, data) on each received
  /// message.
  void onReceive(ReceiveCallback callback);

  /// Return the peer ids of all known peers.
  List<String> listPeers();
}
