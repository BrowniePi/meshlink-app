import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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

/// Shared fake backend: POST /account registers into [registry], GET
/// /directory/{u} resolves from it, POST /friendships is accepted silently.
MockClient directoryMockClient(Map<String, Map<String, String>> registry) {
  return MockClient((request) async {
    if (request.method == 'POST' && request.url.path == '/account') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final username = body['username'] as String;
      if (registry.containsKey(username)) {
        return http.Response('{"detail":"taken"}', 409);
      }
      registry[username] = {
        'username': username,
        'curve25519_pub': body['curve25519_pub'] as String,
        'ed25519_pub': body['ed25519_pub'] as String,
      };
      return http.Response('{}', 201);
    }
    if (request.method == 'GET' &&
        request.url.path.startsWith('/directory/')) {
      final username = request.url.pathSegments.last;
      final entry = registry[username];
      if (entry == null) return http.Response('{"detail":"unknown"}', 404);
      return http.Response(jsonEncode(entry), 200);
    }
    if (request.method == 'POST' && request.url.path == '/friendships') {
      return http.Response('{}', 200);
    }
    return http.Response('not found', 404);
  });
}

/// One phone: identity + friend stack wired to in-memory fakes.
class FakePhone {
  FakePhone._(this.storage, this.transport, this.pipeline, this.friends);

  final InMemorySecureStorage storage;
  final CapturingTransport transport;
  final RelayPipeline pipeline;
  final FriendService friends;

  ({double lat, double lon, double accuracyM})? position;

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
      directory: DirectoryClient(
        config: const BackendConfig(baseUrl: 'http://test', eventId: 'test'),
        client: directoryMockClient(registry),
      ),
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
