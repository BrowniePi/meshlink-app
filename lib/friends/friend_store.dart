import 'dart:convert';
import 'dart:typed_data';

import '../identity/secure_storage.dart';
import 'friend_state.dart';

/// Delivery progress of an outgoing DM. The mesh is best-effort
/// spray-and-wait with no receipts, so the honest ceiling is [relayed]:
/// the packet was handed to at least one peer. There is no "delivered".
enum DmStatus { sending, relayed, failed }

/// One direct message in a conversation, as this phone saw it. DMs live on
/// the phones only — they never touch the backend or the node's storage.
class DirectMessage {
  DirectMessage({
    required this.text,
    required this.outgoing,
    required this.at,
    this.status,
  });
  final String text;
  final bool outgoing;
  final DateTime at;

  /// Only meaningful for outgoing messages; null for incoming.
  DmStatus? status;
}

/// Newest messages kept per friend — bounds the secure-storage blob.
const int maxDmHistory = 200;

/// Persisted state for one friend: the state-machine record plus the two
/// capability tokens in play (mine-to-them, theirs-to-me), the DM
/// conversation, and bookkeeping for accept/decline.
class FriendEntry {
  FriendEntry({
    required this.record,
    this.myTokenToThem,
    this.theirTokenToMe,
    this.pendingRequestMsgId,
    List<DirectMessage>? messages,
  }) : messages = messages ?? [];

  FriendshipRecord record;

  /// DM history with this friend, oldest first, capped at [maxDmHistory].
  final List<DirectMessage> messages;

  void addMessage(DirectMessage message) {
    messages.add(message);
    if (messages.length > maxDmHistory) {
      messages.removeRange(0, messages.length - maxDmHistory);
    }
  }

  /// Token I minted granting THEM my location — resent on refresh.
  Uint8List? myTokenToThem;

  /// Token THEY minted granting ME their location — what a LOCATION_QUERY
  /// carries. Absent until they enable sharing; cleared on their revoke.
  Uint8List? theirTokenToMe;

  /// msg_id of their inbound FRIEND_REQUEST, referenced by a decline.
  Uint8List? pendingRequestMsgId;
}

/// Friends persistence: one JSON blob in the existing Keychain/Keystore
/// secure storage (no second key store). The phone is the authoritative home
/// of friendship/consent state — the backend only mirrors it.
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
        messages: [
          for (final d in (m['messages'] as List? ?? []).cast<Map<String, dynamic>>())
            DirectMessage(
              text: d['text'] as String,
              outgoing: d['out'] as bool,
              at: DateTime.fromMillisecondsSinceEpoch((d['at'] as num).toInt()),
              status: d['status'] == null
                  ? null
                  : DmStatus.values.byName(d['status'] as String),
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

  /// Insert or replace the entry for its username and persist everything.
  Future<void> put(FriendEntry entry) async {
    _entries[entry.record.peerUsername] = entry;
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
          'messages': [
            for (final d in e.messages)
              {
                'text': d.text,
                'out': d.outgoing,
                'at': d.at.millisecondsSinceEpoch,
                'status': d.status?.name,
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
