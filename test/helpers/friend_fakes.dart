import 'dart:typed_data';

import 'package:meshlink_app/config/backend_config.dart';
import 'package:meshlink_app/core/pipeline.dart';
import 'package:meshlink_app/friends/directory_client.dart';
import 'package:meshlink_app/friends/friend_service.dart';
import 'package:meshlink_app/friends/friend_store.dart';
import 'package:meshlink_app/identity/device_identity.dart';
import 'package:meshlink_app/identity/encryption_identity.dart';
import 'package:meshlink_app/identity/secure_storage.dart';
import 'package:meshlink_app/transport/transport.dart';

/// In-memory stand-in for the Keychain/Keystore bridge.
class InMemorySecureStorage implements SecureStorage {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// Transport that records outgoing packets instead of radioing them.
class CapturingTransport implements Transport {
  final List<Uint8List> sent = [];
  ReceiveCallback? receiveCallback;

  /// Who is in radio range. Empty = an empty cell, where a send reaches
  /// nobody and the packet is simply gone.
  List<String> peers = ['node-1'];

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> send(String peerId, Uint8List data) async =>
      sent.add(Uint8List.fromList(data));

  @override
  void onReceive(ReceiveCallback callback) => receiveCallback = callback;

  @override
  List<String> listPeers() => peers;

  List<Uint8List> drain() {
    final out = List<Uint8List>.from(sent);
    sent.clear();
    return out;
  }
}

/// Shared fake directory backed by [registry] directly — the production
/// registration path is the Supabase signup trigger, so the test harness
/// registers keys in-memory instead of over a wire protocol.
class FakeDirectoryClient extends DirectoryClient {
  FakeDirectoryClient(this.registry)
      : super(
          config: const BackendConfig(baseUrl: 'http://test', eventId: 'test'),
        );

  final Map<String, Map<String, String>> registry;

  Future<void> registerAccount({
    required String username,
    required Uint8List curve25519Pub,
    required Uint8List ed25519Pub,
  }) async {
    if (registry.containsKey(username)) {
      throw const DirectoryException('That username is taken',
          usernameTaken: true);
    }
    registry[username] = {
      'username': username,
      'curve25519_pub': _hex(curve25519Pub),
      'ed25519_pub': _hex(ed25519Pub),
    };
  }

  @override
  Future<DirectoryEntry> resolve(String username) async {
    final entry = registry[username];
    if (entry == null) {
      throw DirectoryException('No user named "$username"', notFound: true);
    }
    return DirectoryEntry(
      entry['username']!,
      _unhex(entry['curve25519_pub']!),
      _unhex(entry['ed25519_pub']!),
    );
  }

  @override
  Future<void> mirrorFriendship({
    required String userA,
    required String userB,
    required String state,
    required bool aSharesLoc,
    required bool bSharesLoc,
  }) async {
    // Accepted silently, like the best-effort production mirror.
  }
}

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _unhex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// One phone: identity + friend stack wired to in-memory fakes.
class FakePhone {
  FakePhone._(this.storage, this.transport, this.pipeline, this.friends);

  final InMemorySecureStorage storage;
  final CapturingTransport transport;
  final RelayPipeline pipeline;
  final FriendService friends;

  ({double lat, double lon, double accuracyM})? position;

  Future<void> createAccount(String username) async {
    await (friends.directory as FakeDirectoryClient).registerAccount(
      username: username,
      curve25519Pub: friends.encryption.publicKey,
      ed25519Pub: friends.identity.publicKey,
    );
    await friends.bindAccount(username);
  }

  static Future<FakePhone> create(
    Map<String, Map<String, String>> registry, {
    DateTime Function()? now,
    bool init = true,
  }) =>
      createWithStorage(InMemorySecureStorage(), registry,
          now: now, init: init);

  /// Build a phone on existing storage — simulates an app relaunch when
  /// given a storage that already holds identity/friend state. [init] false
  /// skips FriendService.init so no periodic timers exist (widget tests
  /// fail on timers still pending when the test body ends).
  static Future<FakePhone> createWithStorage(
    InMemorySecureStorage storage,
    Map<String, Map<String, String>> registry, {
    DateTime Function()? now,
    bool init = true,
  }) async {
    final identity = await DeviceIdentity.loadOrGenerate(storage);
    final encryption = await EncryptionIdentity.loadOrGenerate(storage);
    final transport = CapturingTransport();
    final pipeline = RelayPipeline();
    late final FakePhone phone;
    final friends = FriendService(
      store: FriendStore(storage),
      directory: FakeDirectoryClient(registry),
      identity: identity,
      encryption: encryption,
      transport: transport,
      pipeline: pipeline,
      readPosition: () async => phone.position,
      now: now,
    );
    phone = FakePhone._(storage, transport, pipeline, friends);
    if (init) await friends.init();
    return phone;
  }

  /// Deliver every packet [this] has sent into [other]'s pipeline and friend
  /// service — the loopback "mesh".
  Future<void> deliverTo(FakePhone other) async {
    for (final packet in transport.drain()) {
      final result = await other.pipeline.process(packet);
      if (result.outcome == Outcome.deliver) {
        await other.friends.handleMessage(result.message!);
      }
    }
  }
}
