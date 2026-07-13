# Notifications — app half

Added with the online-messaging rework (2026-07). Backend half:
`Meshlink-backend/docs/push-notifications.md`.

## Three sources, one banner

The same inbound DM can surface through up to three paths, and all three
must resolve to at most ONE notification:

| Source | When it fires | Renders |
|---|---|---|
| Mesh receive path | DM decoded off BLE/WiFi while the app runs (the Android foreground relay keeps it running when backgrounded) | Local notification with the decrypted text |
| Online receive path | Realtime socket push / 45 s inbox poll | Local notification with the decrypted text |
| FCM data push | Backend trigger on `relay_messages` insert — reaches a killed or backgrounded app | "New message from @x" (content is E2EE; the server can't include it) |

De-duplication is the message's **dedup key**: SHA-256 over the relay body
(`[msgType][sealed payload]`), computed identically by the receiving app on
both transports and by the backend trigger (`digest(ciphertext, 'sha256')`).
`NotificationService` keeps a seen-set per run AND derives the OS
notification id from the key, so even the FCM background isolate (which
shares no memory with the app) replaces an existing banner instead of
stacking a duplicate. The same key gates message storage itself
(`FriendEntry.markDmSeen`, persisted), which is what keeps online and mesh
delivery in sync — whichever copy lands second is dropped.

Friend requests notify the same way with key `fr:<username>`.

Suppression: no banner while the app is in the foreground
(`AppLifecycleState.resumed`) — the chat UI updates live. A foreground FCM
push only triggers an immediate inbox poll (`onForegroundPush`).

## Wiring

- `lib/notifications/notification_service.dart` — local banners
  (`flutter_local_notifications`), FCM init/token plumbing
  (`firebase_messaging`), and the background handler
  (`firebaseMessagingBackgroundHandler`, own isolate).
- `FriendService.onDmReceived` / `onFriendRequestReceived` — fired post-dedup
  on either transport; `main.dart` routes them to the service.
- Token lifecycle: registered via the `register_push_token` RPC on login and
  on FCM rotation; on logout the FCM token itself is deleted (the account
  session is already gone, so no authenticated unregister — the backend
  prunes the dead token when the next push at it bounces).

## Firebase setup (required for FCM only)

Local notifications for mesh/online arrivals work with NO Firebase config.
Until the files below exist, `NotificationService.init` logs
"FCM unavailable" and everything else works.

1. Create a Firebase project, add the Android app
   (`com.meshlink.meshlink_app`), download `google-services.json` into
   `android/app/`. The Gradle plugin is applied automatically once the file
   exists (`android/app/build.gradle.kts` checks for it).
2. iOS: add the iOS app, put `GoogleService-Info.plist` in `ios/Runner/`,
   enable Push Notifications + Background Modes (remote notifications) in
   Xcode, and upload an APNs key to Firebase.
3. Give the backend a service-account key — see the backend doc.
