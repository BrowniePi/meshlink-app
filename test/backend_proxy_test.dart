import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshlink_app/transport/backend_proxy.dart';
import 'package:meshlink_app/transport/transport.dart';

/// In-memory Transport: captures sends, delivers replies synchronously.
class FakeNodeTransport implements Transport {
  FakeNodeTransport({this.peers = const ['node-1']});

  List<String> peers;
  final List<(String, Map<String, dynamic>)> requests = [];
  ReceiveCallback? _callback;

  /// Auto-reply builder; null → request left unanswered (timeout tests).
  Map<String, dynamic>? Function(Map<String, dynamic> req)? responder;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> send(String peerId, Uint8List data) async {
    final req = jsonDecode(utf8.decode(data.sublist(5)))
        as Map<String, dynamic>;
    requests.add((peerId, req));
    final res = responder?.call(req);
    if (res != null) {
      _callback!(peerId,
          Uint8List.fromList(utf8.encode('MLBP1${jsonEncode(res)}')));
    }
  }

  @override
  void onReceive(ReceiveCallback callback) => _callback = callback;

  @override
  List<String> listPeers() => List.of(peers);
}

NodeBackendChannel attachedChannel(FakeNodeTransport transport) {
  final channel = NodeBackendChannel();
  channel.attach(transport);
  transport.onReceive((peer, data) {
    if (isBackendProxyFrame(data)) channel.handleFrame(peer, data);
  });
  return channel;
}

void main() {
  test('frame demux matches only the MLBP1 magic', () {
    Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));
    expect(isBackendProxyFrame(bytes('MLBP1{"t":"res"}')), isTrue);
    expect(isBackendProxyFrame(bytes('MLPP1{"t":"ping"}')), isFalse);
    expect(isBackendProxyFrame(Uint8List(3)), isFalse);
  });

  group('NodeBackendChannel', () {
    test('round-trips a request to the first peer and correlates the reply',
        () async {
      final transport = FakeNodeTransport();
      final channel = attachedChannel(transport);
      transport.responder = (req) => {
            't': 'res',
            'id': req['id'],
            'status': 201,
            'body': '{"ticket_id":"tk"}',
          };

      final res = await channel.request(
        method: 'POST',
        path: '/tickets',
        body: '{"event_id":"e"}',
        headers: {'authorization': 'Bearer tok'},
      );

      expect(res.status, 201);
      expect(res.body, '{"ticket_id":"tk"}');
      final (peer, sent) = transport.requests.single;
      expect(peer, 'node-1');
      expect(sent['t'], 'req');
      expect(sent['method'], 'POST');
      expect(sent['path'], '/tickets');
      expect(sent['body'], '{"event_id":"e"}');
      expect(sent['headers'], {'authorization': 'Bearer tok'});
    });

    test('node uplink failure (status 0) surfaces as ProxyException',
        () async {
      final transport = FakeNodeTransport();
      final channel = attachedChannel(transport);
      transport.responder = (req) => {
            't': 'res',
            'id': req['id'],
            'status': 0,
            'error': 'backend unreachable',
          };

      expect(channel.request(method: 'GET', path: '/events'),
          throwsA(isA<ProxyException>()));
    });

    test('no reply within the timeout throws and clears the pending entry',
        () async {
      final transport = FakeNodeTransport(); // responder null: no answer
      final channel = attachedChannel(transport);

      await expectLater(
        channel.request(
            method: 'GET',
            path: '/events',
            timeout: const Duration(milliseconds: 20)),
        throwsA(isA<ProxyException>()),
      );
    });

    test('unavailable without a transport or without peers', () {
      final channel = NodeBackendChannel();
      expect(channel.available, isFalse);

      final transport = FakeNodeTransport(peers: []);
      channel.attach(transport);
      expect(channel.available, isFalse);
      expect(channel.request(method: 'GET', path: '/events'),
          throwsA(isA<ProxyException>()));

      transport.peers = ['node-1'];
      expect(channel.available, isTrue);
    });
  });

  group('MeshBackendClient', () {
    test('uses the direct client while the internet is reachable', () async {
      final transport = FakeNodeTransport();
      final channel = attachedChannel(transport);
      final client = MeshBackendClient(
        channel: channel,
        direct: MockClient((req) async => http.Response('{"ok":1}', 200)),
      );

      final res = await client.get(Uri.parse('http://backend/events'));
      expect(res.statusCode, 200);
      expect(transport.requests, isEmpty, reason: 'no proxy needed');
    });

    test('falls back to the node when the direct client fails', () async {
      final transport = FakeNodeTransport();
      final channel = attachedChannel(transport);
      transport.responder = (req) => {
            't': 'res',
            'id': req['id'],
            'status': 200,
            'body': '{"events":[]}',
          };
      final client = MeshBackendClient(
        channel: channel,
        direct: MockClient((req) async => throw http.ClientException('down')),
      );

      final res = await client.post(
        Uri.parse('http://backend/events?x=1'),
        headers: {'Authorization': 'Bearer t'},
        body: '{"a":1}',
      );

      expect(res.statusCode, 200);
      expect(res.body, '{"events":[]}');
      final (_, sent) = transport.requests.single;
      expect(sent['path'], '/events?x=1');
      expect(sent['method'], 'POST');
      expect(sent['body'], '{"a":1}');
      expect(sent['headers'], {'authorization': 'Bearer t'});
    });

    test('backend rejections proxied through keep their HTTP status',
        () async {
      final transport = FakeNodeTransport();
      final channel = attachedChannel(transport);
      transport.responder = (req) => {
            't': 'res',
            'id': req['id'],
            'status': 403,
            'body': '{"detail":"ticket expired"}',
          };
      final client = MeshBackendClient(
        channel: channel,
        direct: MockClient((req) async => throw http.ClientException('down')),
      );

      final res = await client.post(Uri.parse('http://backend/attestation/token'));
      expect(res.statusCode, 403);
      expect(res.body, '{"detail":"ticket expired"}');
    });

    test('an auth call with no node waits out a cold start; other calls do not',
        () async {
      final transport = FakeNodeTransport(peers: []);
      final channel = attachedChannel(transport);
      // A backend still booting: slower than the normal cap, quicker than the
      // cold-start one.
      final client = MeshBackendClient(
        channel: channel,
        direct: MockClient((req) async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return http.Response('{"ok":1}', 200);
        }),
        directTimeout: const Duration(milliseconds: 20),
        authTimeout: const Duration(milliseconds: 400),
      );

      final res = await client.post(Uri.parse('http://backend/auth/login'));
      expect(res.statusCode, 200, reason: 'waited for the server to wake');

      expect(client.get(Uri.parse('http://backend/events')),
          throwsA(isA<TimeoutException>()),
          reason: 'only /auth/ gets the longer budget');
    });

    test('a connected node still gets the short cap on auth calls', () async {
      final transport = FakeNodeTransport();
      final channel = attachedChannel(transport);
      transport.responder = (req) => {
            't': 'res',
            'id': req['id'],
            'status': 200,
            'body': '{"proxied":1}',
          };
      final client = MeshBackendClient(
        channel: channel,
        direct: MockClient((req) async {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          return http.Response('{"direct":1}', 200);
        }),
        directTimeout: const Duration(milliseconds: 20),
        authTimeout: const Duration(seconds: 30),
      );

      // The cold-start budget must not delay the mesh fallback: with a node
      // there, the direct attempt is still capped at directTimeout.
      final res = await client.post(Uri.parse('http://backend/auth/login'));
      expect(res.body, '{"proxied":1}');
      expect(transport.requests.single.$2['path'], '/auth/login');
    });

    test('rethrows the direct failure when no mesh peer is connected',
        () async {
      final transport = FakeNodeTransport(peers: []);
      final channel = attachedChannel(transport);
      final client = MeshBackendClient(
        channel: channel,
        direct: MockClient((req) async => throw http.ClientException('down')),
      );

      expect(client.get(Uri.parse('http://backend/events')),
          throwsA(isA<http.ClientException>()));
    });
  });
}
