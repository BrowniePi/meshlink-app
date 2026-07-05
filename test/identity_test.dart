import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshlink_app/identity/device_identity.dart';
import 'package:meshlink_app/identity/secure_storage.dart';

/// Keygen task DoD: keys are valid Ed25519 (correct length), two generations
/// differ, and loadOrGenerate persists exactly one identity per install.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('generated key has valid Ed25519 shape', () async {
    final identity = await DeviceIdentity.generate();
    expect(identity.publicKey.length, 32);
    final seed = await identity.keyPair.extractPrivateKeyBytes();
    expect(seed.length, 32);
  });

  test('two generations produce different keypairs', () async {
    final a = await DeviceIdentity.generate();
    final b = await DeviceIdentity.generate();
    expect(a.publicKey, isNot(equals(b.publicKey)));
  });

  test('loadOrGenerate persists the seed and reloads the same identity',
      () async {
    // Fake Keychain/Keystore: an in-memory map behind the platform channel.
    final store = <String, String>{};
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

    final first = await DeviceIdentity.loadOrGenerate(SecureStorage());
    expect(store.length, 1, reason: 'seed persisted on first launch');
    final second = await DeviceIdentity.loadOrGenerate(SecureStorage());
    expect(second.publicKey, equals(first.publicKey),
        reason: 'same identity across restarts, not regenerated');

    // Reinstall model: wiping the store yields a brand-new identity.
    store.clear();
    final reinstalled = await DeviceIdentity.loadOrGenerate(SecureStorage());
    expect(reinstalled.publicKey, isNot(equals(first.publicKey)));
  });
}
