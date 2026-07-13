import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshlink_app/config/backend_config.dart';
import 'package:meshlink_app/onboarding/attestation_flow.dart';

const _config = BackendConfig(baseUrl: 'http://test', eventId: 'evt-1');
final _pubkey = 'aa' * 32; // 64 hex chars

AttestationFlow _flow(MockClient client) => AttestationFlow(
      config: _config,
      client: client,
      baseBackoff: Duration.zero, // no real waiting in tests
    );

void main() {
  test('walks tickets → token and returns the token', () async {
    final paths = <String>[];
    final client = MockClient((req) async {
      paths.add(req.url.path);
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      if (req.url.path == '/functions/v1/tickets') {
        expect(body['event_id'], 'evt-1');
        expect(body['buyer_pubkey'], _pubkey);
        return http.Response(
            jsonEncode({'ticket_id': 'tk-9'}), 201);
      }
      // /functions/v1/attestation-token
      expect(body['ticket_id'], 'tk-9');
      expect(body['device_pubkey'], _pubkey);
      return http.Response(
          jsonEncode({'token': 'j.w.t', 'expires_at': 1800000000}), 200);
    });

    final token = await _flow(client).fetchToken(_pubkey);

    expect(paths, ['/functions/v1/tickets', '/functions/v1/attestation-token']);
    expect(token.token, 'j.w.t');
    expect(token.expiresAt,
        DateTime.fromMillisecondsSinceEpoch(1800000000 * 1000));
  });

  test('retries a transient 500 then succeeds', () async {
    var ticketCalls = 0;
    final client = MockClient((req) async {
      if (req.url.path == '/functions/v1/tickets') {
        ticketCalls++;
        if (ticketCalls == 1) return http.Response('upstream', 500);
        return http.Response(jsonEncode({'ticket_id': 'tk'}), 201);
      }
      return http.Response(
          jsonEncode({'token': 't', 'expires_at': 1}), 200);
    });

    final token = await _flow(client).fetchToken(_pubkey);
    expect(ticketCalls, 2, reason: 'first attempt 500, retried');
    expect(token.token, 't');
  });

  test('a 403 rejection is non-retryable and surfaces the backend reason',
      () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      if (req.url.path == '/functions/v1/tickets') {
        return http.Response(jsonEncode({'ticket_id': 'tk'}), 201);
      }
      return http.Response(
          jsonEncode({'detail': 'device_pubkey does not match ticket buyer'}),
          403);
    });

    final err = await _flow(client)
        .fetchToken(_pubkey)
        .then<Object?>((_) => null, onError: (Object e) => e);

    expect(err, isA<AttestationException>());
    final e = err! as AttestationException;
    expect(e.retryable, isFalse);
    expect(e.message, contains('does not match ticket buyer'));
    expect(calls, 2, reason: 'ticket ok once, token 403 not retried');
  });

  test('gives up after maxAttempts on persistent network failure', () async {
    var calls = 0;
    final client = MockClient((req) async {
      calls++;
      throw Exception('connection refused');
    });
    final flow = AttestationFlow(
      config: _config,
      client: client,
      baseBackoff: Duration.zero,
      maxAttempts: 3,
    );

    final err = await flow
        .fetchToken(_pubkey)
        .then<Object?>((_) => null, onError: (Object e) => e);

    expect(err, isA<AttestationException>());
    expect((err! as AttestationException).retryable, isTrue);
    expect(calls, 3, reason: 'three attempts at the first (ticket) call');
  });
}
