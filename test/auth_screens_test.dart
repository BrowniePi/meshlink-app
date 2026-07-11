import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:meshlink_app/auth/auth_chrome.dart';
import 'package:meshlink_app/auth/auth_client.dart';
import 'package:meshlink_app/auth/auth_service.dart';
import 'package:meshlink_app/auth/login_screen.dart';
import 'package:meshlink_app/auth/session_storage.dart';
import 'package:meshlink_app/auth/signup_screen.dart';
import 'package:meshlink_app/auth/verify_pending_screen.dart';
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

Future<AuthService> _auth({Duration backendDelay = Duration.zero}) async {
  final storage = _FakeStorage();
  return AuthService(
    client: AuthClient(
        config: const BackendConfig(baseUrl: 'http://test', eventId: 'e'),
        client: MockClient((_) async {
          await Future<void>.delayed(backendDelay);
          return http.Response('{}', 500);
        })),
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

  testWidgets('login keeps no back button after a pushed screen pops',
      (tester) async {
    final auth = await _auth();
    await tester.pumpWidget(MaterialApp(home: LoginScreen(auth: auth)));
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    nav.push(MaterialPageRoute(
        builder: (_) => VerifyPendingScreen(
            auth: auth, email: 'a@b.c', password: 'pw')));
    await tester.pumpAndSettle();

    // Rebuild the login route while it sits under the pushed one — this is
    // where a navigator-wide canPop check would latch a back button on.
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpAndSettle();

    nav.pop();
    await tester.pumpAndSettle();
    expect(find.text('Log in'), findsNWidgets(2));
    expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
  });

  testWidgets('a slow login says the server is waking, not that it failed',
      (tester) async {
    final auth = await _auth(backendDelay: const Duration(seconds: 30));
    await tester.pumpWidget(MaterialApp(home: LoginScreen(auth: auth)));
    await tester.enterText(find.byType(TextField).first, 'ada@example.com');
    await tester.enterText(find.byType(TextField).last, 'password123');
    await tester.tap(find.text('Log in').last);

    await tester.pump(const Duration(seconds: 5));
    expect(find.text(authWakingMessage), findsNothing,
        reason: 'a healthy backend answers well inside this');

    await tester.pump(authWakingAfter);
    expect(find.text(authWakingMessage), findsOneWidget);

    // Server finally answers (500 here) — the notice gives way to the error.
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(find.text(authWakingMessage), findsNothing);
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
