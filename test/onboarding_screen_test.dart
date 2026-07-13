import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter/services.dart';
import 'package:meshlink_app/config/backend_config.dart';
import 'package:meshlink_app/identity/device_identity.dart';
import 'package:meshlink_app/identity/secure_storage.dart';
import 'package:meshlink_app/identity/token_storage.dart';
import 'package:meshlink_app/onboarding/attestation_flow.dart';
import 'package:meshlink_app/onboarding/onboarding_screen.dart';

const _config = BackendConfig(baseUrl: 'http://test', eventId: 'evt-1');

void _fakeStore(Map<String, String> store) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('meshlink/secure_storage'), (call) async {
    final args = (call.arguments as Map).cast<String, Object?>();
    final key = args['key']! as String;
    switch (call.method) {
      case 'read':
        return store[key];
      case 'write':
        store[key] = args['value']! as String;
        return null;
      case 'delete':
        store.remove(key);
        return null;
    }
    throw MissingPluginException();
  });
}

/// Mirrors main.dart: onboarding is replaced once a token arrives, so the
/// spinner stops and pumpAndSettle can settle.
class _Harness extends StatefulWidget {
  const _Harness({
    required this.identity,
    required this.client,
    required this.storage,
    required this.onComplete,
  });

  final DeviceIdentity identity;
  final MockClient client;
  final TokenStorage storage;
  final ValueChanged<AttestationToken> onComplete;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  bool _done = false;

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: _done
            ? const Scaffold(body: Text('CHAT'))
            : OnboardingScreen(
                identity: widget.identity,
                flow: AttestationFlow(
                    config: _config,
                    client: widget.client,
                    baseBackoff: Duration.zero),
                tokenStorage: widget.storage,
                onComplete: (t) {
                  widget.onComplete(t);
                  setState(() => _done = true);
                },
              ),
      );
}

Widget _harness({
  required DeviceIdentity identity,
  required MockClient client,
  required TokenStorage storage,
  required ValueChanged<AttestationToken> onComplete,
}) =>
    _Harness(
      identity: identity,
      client: client,
      storage: storage,
      onComplete: onComplete,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DeviceIdentity identity;
  setUpAll(() async => identity = await DeviceIdentity.generate());

  testWidgets('successful fetch stores the token and calls onComplete',
      (tester) async {
    final store = <String, String>{};
    _fakeStore(store);
    final storage = TokenStorage(SecureStorage());
    AttestationToken? completed;

    final client = MockClient((req) async {
      if (req.url.path == '/functions/v1/tickets') {
        return http.Response(jsonEncode({'ticket_id': 'tk'}), 201);
      }
      return http.Response(
          jsonEncode({'token': 'the.jwt', 'expires_at': 1800000000}), 200);
    });

    await tester.pumpWidget(_harness(
      identity: identity,
      client: client,
      storage: storage,
      onComplete: (t) => completed = t,
    ));
    await tester.pumpAndSettle();

    expect(completed, isNotNull);
    expect(completed!.token, 'the.jwt');
    expect(await storage.read(), isNotNull,
        reason: 'token persisted for next launch');
  });

  testWidgets('network failure shows a retryable error with a retry button',
      (tester) async {
    _fakeStore(<String, String>{});
    final storage = TokenStorage(SecureStorage());
    var attempts = 0;

    final client = MockClient((req) async {
      attempts++;
      if (attempts <= 3) throw Exception('connection refused');
      if (req.url.path == '/functions/v1/tickets') {
        return http.Response(jsonEncode({'ticket_id': 'tk'}), 201);
      }
      return http.Response(
          jsonEncode({'token': 't', 'expires_at': 1}), 200);
    });

    AttestationToken? completed;
    await tester.pumpWidget(_harness(
      identity: identity,
      client: client,
      storage: storage,
      onComplete: (t) => completed = t,
    ));
    await tester.pumpAndSettle();

    // First run exhausts its 3 attempts and shows the retryable error.
    expect(find.text('Try again'), findsOneWidget);
    expect(completed, isNull);

    // Retry now succeeds (the 4th+ responses are good).
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(completed, isNotNull);
  });

  testWidgets('a 403 refusal is non-retryable — no retry button', (tester) async {
    _fakeStore(<String, String>{});
    final storage = TokenStorage(SecureStorage());

    final client = MockClient((req) async {
      if (req.url.path == '/functions/v1/tickets') {
        return http.Response(jsonEncode({'ticket_id': 'tk'}), 201);
      }
      return http.Response(jsonEncode({'detail': 'ticket expired'}), 403);
    });

    await tester.pumpWidget(_harness(
      identity: identity,
      client: client,
      storage: storage,
      onComplete: (_) {},
    ));
    await tester.pumpAndSettle();

    expect(find.text('Event unavailable'), findsOneWidget);
    expect(find.textContaining('ticket expired'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
  });
}
