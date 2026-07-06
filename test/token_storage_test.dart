import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshlink_app/identity/secure_storage.dart';
import 'package:meshlink_app/identity/token_storage.dart';

/// In-memory fake of the native secure-storage channel.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('round-trips a token through secure storage', () async {
    final store = <String, String>{};
    _fakeStore(store);
    final storage = TokenStorage(SecureStorage());

    expect(await storage.read(), isNull);

    final token = AttestationToken(
      token: 'header.payload.sig',
      expiresAt: DateTime.fromMillisecondsSinceEpoch(1800000000 * 1000),
    );
    await storage.write(token);
    expect(store, hasLength(1), reason: 'persisted to the secure store');

    final loaded = await storage.read();
    expect(loaded!.token, token.token);
    expect(loaded.expiresAt, token.expiresAt);
  });

  test('clear removes the stored token', () async {
    final store = <String, String>{};
    _fakeStore(store);
    final storage = TokenStorage(SecureStorage());
    await storage.write(AttestationToken(
      token: 't', expiresAt: DateTime.fromMillisecondsSinceEpoch(0)));
    await storage.clear();
    expect(await storage.read(), isNull);
  });

  test('isExpiredAt treats the exact expiry instant as expired', () {
    final exp = DateTime.fromMillisecondsSinceEpoch(1000 * 1000);
    final token = AttestationToken(token: 't', expiresAt: exp);
    expect(token.isExpiredAt(exp.subtract(const Duration(seconds: 1))), isFalse);
    expect(token.isExpiredAt(exp), isTrue);
    expect(token.isExpiredAt(exp.add(const Duration(seconds: 1))), isTrue);
  });
}
