import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:meshlink_app/auth/auth_client.dart';
import 'package:meshlink_app/auth/auth_service.dart';
import 'package:meshlink_app/auth/login_screen.dart';
import 'package:meshlink_app/auth/session_storage.dart';
import 'package:meshlink_app/auth/signup_screen.dart';
import 'package:meshlink_app/auth/welcome_screen.dart';
import 'package:meshlink_app/config/backend_config.dart';
import 'package:meshlink_app/identity/device_identity.dart';
import 'package:meshlink_app/identity/encryption_identity.dart';
import 'package:meshlink_app/identity/secure_storage.dart';
import 'package:meshlink_app/identity/token_storage.dart';

/// Render smoke tests for the Firefly-styled auth screens: the screens
/// provide their own FireflyTheme (they live outside FireflyHome), so a
/// wiring mistake there is a runtime crash no analyzer catches.
class _FakeStorage implements SecureStorage {
  final Map<String, String> _m = {};
  @override
  Future<String?> read(String key) async => _m[key];
  @override
  Future<void> write(String key, String value) async => _m[key] = value;
  @override
  Future<void> delete(String key) async => _m.remove(key);
}

Future<AuthService> _auth() async {
  final storage = _FakeStorage();
  return AuthService(
    client: AuthClient(
        config: const BackendConfig(baseUrl: 'http://test', eventId: 'e'),
        client: MockClient((_) async => http.Response('{}', 500))),
    sessionStorage: SessionStorage(storage),
    identity: await DeviceIdentity.loadOrGenerate(storage),
    encryption: await EncryptionIdentity.loadOrGenerate(storage),
    tokenStorage: TokenStorage(storage),
  );
}

void main() {
  testWidgets('login screen renders with fields and links', (tester) async {
    await tester.pumpWidget(MaterialApp(home: LoginScreen(auth: await _auth())));
    expect(find.text('FIREFLY'), findsOneWidget);
    expect(find.text('Log in'), findsNWidgets(2)); // title + button
    expect(find.text('Create an account'), findsOneWidget);
    expect(find.text('Forgot password?'), findsOneWidget);
  });

  testWidgets('signup screen renders its three fields', (tester) async {
    await tester.pumpWidget(
        MaterialApp(home: SignupScreen(auth: await _auth())));
    expect(find.text('Create account'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(3));
    expect(find.text('Sign up'), findsOneWidget);
  });

  testWidgets('welcome screen greets by username', (tester) async {
    var advanced = false;
    await tester.pumpWidget(MaterialApp(
        home: WelcomeScreen(username: 'ada', onContinue: () => advanced = true)));
    expect(find.text('Welcome, ada'), findsOneWidget);
    await tester.tap(find.text('Get started'));
    expect(advanced, isTrue);
  });
}
