import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../debug/debug_log.dart' as dbg;

/// Android notification channel for friend messaging. One channel: DMs and
/// friend requests are the only things MeshLink ever notifies about.
const String _channelId = 'meshlink_messages';
const String _channelName = 'Messages';
const String _channelDescription = 'Direct messages and friend requests';

/// User-facing notifications for friend messaging, fed by three sources that
/// can all fire for the SAME message:
///
///  * the mesh receive path (a DM decoded off BLE/WiFi),
///  * the online receive path (socket push / inbox poll), and
///  * an FCM data push from the backend (app killed or backgrounded).
///
/// De-duplication: every source carries the message's dedup key (the
/// ciphertext SHA-256 the receiver also dedups storage on). The key seeds
/// both an in-memory seen-set and the OS notification id, so a copy arriving
/// through a second path — even in the FCM background isolate, which shares
/// no memory with the app — replaces the existing notification instead of
/// stacking a duplicate.
///
/// FCM is optional: without Firebase config files the init fails softly and
/// mesh/online local notifications keep working alone.
class NotificationService {
  static final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();

  /// Dedup keys already notified this app run (bounded).
  final Set<String> _notified = {};
  static const int _maxNotified = 256;

  bool _localReady = false;
  bool _fcmReady = false;

  /// Whether Firebase initialized — the gate for [fcmToken]/[deleteToken].
  bool get fcmAvailable => _fcmReady;

  /// A push arrived while the app is in the foreground: the payload is
  /// E2EE so the push is only a wake-up — the owner should poll the inbox.
  void Function()? onForegroundPush;

  Future<void> init() async {
    try {
      const androidInit =
          AndroidInitializationSettings('@mipmap/launcher_icon');
      const darwinInit = DarwinInitializationSettings();
      await _local.initialize(
          settings: const InitializationSettings(
              android: androidInit, iOS: darwinInit, macOS: darwinInit));
      await _local
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      _localReady = true;
    } catch (e) {
      _log('local notifications unavailable: $e');
    }
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(
          firebaseMessagingBackgroundHandler);
      // Foreground pushes: no banner (the user is looking at the app and the
      // socket/poll delivers the content) — just make the poll happen now.
      FirebaseMessaging.onMessage.listen((_) => onForegroundPush?.call());
      await FirebaseMessaging.instance.requestPermission();
      _fcmReady = true;
      _log('FCM ready');
    } catch (e) {
      // No google-services.json / GoogleService-Info.plist yet: local
      // notifications still cover mesh and foreground-online arrivals.
      _log('FCM unavailable (Firebase not configured?): $e');
    }
  }

  /// This device's FCM registration token, for the backend's push_tokens
  /// table. Null when Firebase isn't configured or FCM has no token yet.
  Future<String?> fcmToken() async {
    if (!_fcmReady) return null;
    try {
      return await FirebaseMessaging.instance.getToken();
    } catch (e) {
      _log('FCM token fetch failed: $e');
      return null;
    }
  }

  /// Fires when FCM rotates the registration token — re-register with the
  /// backend. Empty stream when Firebase isn't configured.
  Stream<String> get onTokenRefresh => _fcmReady
      ? FirebaseMessaging.instance.onTokenRefresh
      : const Stream.empty();

  /// Logout: invalidate this device's FCM token entirely. Works without the
  /// (now gone) account session — pushes to the dead token fail server-side
  /// and the backend prunes it from push_tokens.
  Future<void> deleteToken() async {
    if (!_fcmReady) return;
    try {
      await FirebaseMessaging.instance.deleteToken();
    } catch (e) {
      _log('FCM token delete failed: $e');
    }
  }

  bool get _appVisible =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  /// An inbound DM landed (mesh or online receive path). Shows a local
  /// notification unless the app is visible or this message was already
  /// notified through another path.
  Future<void> notifyDm(
      {required String fromUser,
      required String text,
      required String dedupKey}) async {
    if (!_markNotified(dedupKey) || _appVisible) return;
    await _show(
      id: _idFor(dedupKey),
      title: 'New message from @$fromUser',
      body: text,
    );
  }

  /// An inbound friend request landed (mesh or online receive path).
  Future<void> notifyFriendRequest(String fromUser) async {
    if (!_markNotified('fr:$fromUser') || _appVisible) return;
    await _show(
      id: _idFor('fr:$fromUser'),
      title: 'Friend request',
      body: '@$fromUser wants to be your friend',
    );
  }

  bool _markNotified(String key) {
    if (_notified.contains(key)) return false;
    if (_notified.length >= _maxNotified) _notified.clear();
    _notified.add(key);
    return true;
  }

  Future<void> _show(
      {required int id, required String title, required String body}) async {
    if (!_localReady) return;
    try {
      await _local.show(
          id: id, title: title, body: body, notificationDetails: _details());
    } catch (e) {
      _log('notification show failed: $e');
    }
  }

  void _log(String message) =>
      dbg.DebugLog.instance.log('notify', message);
}

NotificationDetails _details() => const NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDescription,
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.message,
      ),
      iOS: DarwinNotificationDetails(),
    );

/// Stable OS notification id from a dedup key, so the same message notified
/// from two isolates replaces itself instead of duplicating.
int _idFor(String key) => key.hashCode & 0x7fffffff;

/// FCM background/terminated handler — runs in its own isolate with no app
/// state, so it re-initializes Firebase + the local-notifications plugin and
/// renders straight from the data payload. The payload is metadata only
/// (kind, from_user, dedup_key): message content is E2EE and never leaves
/// the phones in the clear, so the banner names the sender, not the text.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
    final data = message.data;
    final kind = data['kind'];
    final from = data['from_user'] ?? 'a friend';
    final dedupKey = data['dedup_key'] ?? '${data.hashCode}';
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(
        settings: const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/launcher_icon'),
      iOS: DarwinInitializationSettings(),
    ));
    switch (kind) {
      case 'friend_request':
        await plugin.show(
            id: _idFor('fr:$from'),
            title: 'Friend request',
            body: '@$from wants to be your friend',
            notificationDetails: _details());
      default: // 'dm' and anything a newer backend might add
        await plugin.show(
            id: _idFor(dedupKey),
            title: 'New message from @$from',
            body: 'Open MeshLink to read it',
            notificationDetails: _details());
    }
  } catch (_) {
    // Background isolate: nowhere to report; the message still lands via
    // the inbox poll when the app next runs.
  }
}
