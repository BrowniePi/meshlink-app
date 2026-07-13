import 'dart:convert';
import 'dart:typed_data';

import '../identity/secure_storage.dart';
import 'friend_state.dart';

/// Delivery progress of an outgoing DM. The mesh is best-effort
/// spray-and-wait with no receipts, so the honest ceiling is [relayed]:
/// the packet was handed to at least one peer (or, online, the backend
/// accepted it for store-and-forward). There is no "delivered".
enum DmStatus { sending, relayed, failed }

/// Which transport carried a DM — the per-message half of the online/mesh
/// indicator. Online messages ride the backend relay as sealed ciphertext;
/// mesh messages spray-and-wait over BLE/WiFi. Same crypto either way.
/// [both] = the sealed payload went out on the two transports at once (the
/// receiver dedups on the ciphertext, so it still lands exactly once).
enum DmVia { mesh, online, both }

/// One direct message in a conversation, as this phone saw it. Plaintext
/// lives on the phones only — the backend relay carries sealed ciphertext
/// and deletes it on delivery.
class DirectMessage {
  DirectMessage({
    required this.text,
    required this.outgoing,
    required this.at,
    this.status,
    this.via = DmVia.mesh,
  });
  final String text;
  final bool outgoing;
  final DateTime at;

  /// Only meaningful for outgoing messages; null for incoming.
  DmStatus? status;

  /// Transport that carried (or is carrying) this message.
  DmVia via;
}

/// Newest messages kept per friend — bounds the secure-storage blob.
const int maxDmHistory = 200;

/// Newest inbound DM dedup keys kept per friend. A message sent
/// simultaneously online and over the mesh arrives (up to) twice; the key —
/// a hash of the sealed ciphertext, identical on both transports — lets the
/// second copy be dropped. Bounded well above any realistic in-flight window.
const int maxSeenDmKeys = 64;

/// Persisted state for one friend: the state-machine record plus the two
/// capability tokens in play (mine-to-them, theirs-to-me), the DM
/// conversation, and bookkeeping for accept/decline.
class FriendEntry {
  FriendEntry({
    required this.record,
    this.myTokenToThem,
    this.theirTokenToMe,
    this.pendingRequestMsgId,
    this.requestSentOnline = false,
    List<DirectMessage>? messages,
    List<String>? seenDmKeys,
  })  : messages = messages ?? [],
        seenDmKeys = seenDmKeys ?? [];

  FriendshipRecord record;

  /// DM history with this friend, oldest first, capped at [maxDmHistory].
  final List<DirectMessage> messages;

  /// Dedup keys of recent inbound DMs, oldest first, capped at
  /// [maxSeenDmKeys] — see [markDmSeen].
  final List<String> seenDmKeys;

  void addMessage(DirectMessage message) {
    messages.add(message);
    if (messages.length > maxDmHistory) {
      messages.removeRange(0, messages.length - maxDmHistory);
    }
  }

  /// Record an inbound DM's dedup key. Returns false when the key was
  /// already seen — the same message arrived on the other transport — in
  /// which case the copy must be dropped.
  bool markDmSeen(String key) {
    if (seenDmKeys.contains(key)) return false;
    seenDmKeys.add(key);
    if (seenDmKeys.length > maxSeenDmKeys) {
      seenDmKeys.removeRange(0, seenDmKeys.length - maxSeenDmKeys);
    }
    return true;
  }

  /// Token I minted granting THEM my location — resent on refresh.
  Uint8List? myTokenToThem;

  /// Token THEY minted granting ME their location — what a LOCATION_QUERY
  /// carries. Absent until they enable sharing; cleared on their revoke.
  Uint8List? theirTokenToMe;

  /// msg_id of their inbound FRIEND_REQUEST, referenced by a decline.
  Uint8List? pendingRequestMsgId;

  /// Whether our outbound FRIEND_REQUEST reached the backend (online-primary
  /// path). Distinguishes "vanished from the server's pending list because
  /// it was answered" from "was never delivered online at all" — only the
  /// former may be read as an accept/decline.
  bool requestSentOnline;
}

/// Friends persistence: one JSON blob in the existing Keychain/Keystore
/// secure storage (no second key store).
class FriendStore {
  FriendStore(this._storage);

  static const String _key = 'meshlink_friends_v1';
  static const String _usernameKey = 'meshlink_own_username_v1';

  final SecureStorage _storage;
  final Map<String, FriendEntry> _entries = {};
  String? _ownUsername;

  String? get ownUsername => _ownUsername;
  Iterable<FriendEntry> get entries => _entries.values;

  FriendEntry? byUsername(String username) => _entries[username];

  FriendEntry? byEd25519Pub(Uint8List pub) {
    for (final e in _entries.values) {
      if (_hex(e.record.peerEd25519Pub) == _hex(pub)) return e;
    }
    return null;
  }

  Future<void> load() async {
    _ownUsername = await _storage.read(_usernameKey);
    final raw = await _storage.read(_key);
    if (raw == null) return;
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    _entries.clear();
    for (final m in list) {
      final entry = FriendEntry(
        record: FriendshipRecord(
          peerUsername: m['username'] as String,
          peerCurve25519Pub: _fromHex(m['curve_pub'] as String),
          peerEd25519Pub: _fromHex(m['ed_pub'] as String),
          state: FriendshipState.values.byName(m['state'] as String),
          locationSharingEnabled: m['sharing'] as bool,
        ),
        myTokenToThem: _optBytes(m['my_token']),
        theirTokenToMe: _optBytes(m['their_token']),
        pendingRequestMsgId: _optBytes(m['pending_msg_id']),
        requestSentOnline: m['sent_online'] as bool? ?? false,
        seenDmKeys: (m['seen_dm'] as List? ?? []).cast<String>(),
        messages: [
          for (final d in (m['messages'] as List? ?? []).cast<Map<String, dynamic>>())
            DirectMessage(
              text: d['text'] as String,
              outgoing: d['out'] as bool,
              at: DateTime.fromMillisecondsSinceEpoch((d['at'] as num).toInt()),
              status: d['status'] == null
                  ? null
                  : DmStatus.values.byName(d['status'] as String),
              via: d['via'] == null
                  ? DmVia.mesh
                  : DmVia.values.byName(d['via'] as String),
            ),
        ],
      );
      _entries[entry.record.peerUsername] = entry;
    }
  }

  Future<void> setOwnUsername(String username) async {
    _ownUsername = username;
    await _storage.write(_usernameKey, username);
  }

  /// Remove all account-scoped data while leaving device keypairs intact.
  Future<void> clear() async {
    _ownUsername = null;
    _entries.clear();
    await _storage.delete(_usernameKey);
    await _storage.delete(_key);
  }

  /// Insert or replace the entry for its username and persist everything.
  Future<void> put(FriendEntry entry) async {
    _entries[entry.record.peerUsername] = entry;
    await _persist();
  }

  Future<void> remove(String username) async {
    _entries.remove(username);
    await _persist();
  }

  Future<void> _persist() async {
    final list = [
      for (final e in _entries.values)
        {
          'username': e.record.peerUsername,
          'curve_pub': _hex(e.record.peerCurve25519Pub),
          'ed_pub': _hex(e.record.peerEd25519Pub),
          'state': e.record.state.name,
          'sharing': e.record.locationSharingEnabled,
          'my_token': e.myTokenToThem == null ? null : _hex(e.myTokenToThem!),
          'their_token':
              e.theirTokenToMe == null ? null : _hex(e.theirTokenToMe!),
          'pending_msg_id': e.pendingRequestMsgId == null
              ? null
              : _hex(e.pendingRequestMsgId!),
          'sent_online': e.requestSentOnline,
          'seen_dm': e.seenDmKeys,
          'messages': [
            for (final d in e.messages)
              {
                'text': d.text,
                'out': d.outgoing,
                'at': d.at.millisecondsSinceEpoch,
                'status': d.status?.name,
                'via': d.via.name,
              }
          ],
        }
    ];
    await _storage.write(_key, jsonEncode(list));
  }
}

Uint8List? _optBytes(Object? hex) =>
    hex == null ? null : _fromHex(hex as String);

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _fromHex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
