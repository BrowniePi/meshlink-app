import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshlink_app/core/capability_token.dart';
import 'package:meshlink_app/core/friend_wire.dart';
import 'package:meshlink_app/core/message.dart';
import 'package:meshlink_app/core/message_factory.dart';
import 'package:meshlink_app/core/sealed.dart';

import 'helpers/test_identity.dart';

void main() {
  late SimpleKeyPair recipientCurveKp;
  late Uint8List recipientCurvePub;
  late Uint8List senderCurvePub;
  late Uint8List senderEdPub;
  final hint = Uint8List.fromList(List.filled(recipientHintSize, 0x42));

  setUpAll(() async {
    recipientCurveKp = await X25519().newKeyPair();
    recipientCurvePub =
        Uint8List.fromList((await recipientCurveKp.extractPublicKey()).bytes);
    final senderCurveKp = await X25519().newKeyPair();
    senderCurvePub =
        Uint8List.fromList((await senderCurveKp.extractPublicKey()).bytes);
    senderEdPub = (await testIdentity()).publicKey;
  });

  test('FRIEND_REQUEST round-trips and carries the recipient hint', () async {
    final payload = FriendRequestPayload('ada-l', senderCurvePub, senderEdPub);
    final raw = await encodeFriendRequest(payload, hint, recipientCurvePub);

    expect(recipientHintOf(raw), hint);
    final decoded = await decodeFriendRequest(raw, recipientCurveKp);
    expect(decoded.username, 'ada-l');
    expect(decoded.curve25519Pub, senderCurvePub);
    expect(decoded.ed25519Pub, senderEdPub);
  });

  test('FRIEND_ACCEPT round-trips with and without an embedded token',
      () async {
    final identity = await testIdentity();
    final token = await issueToken(
      issuerKeyPair: identity.keyPair,
      issuerPub: identity.publicKey,
      granteeEd25519Pub: senderEdPub,
    );

    for (final embedded in [token, null]) {
      final raw = await encodeFriendAccept(
        FriendAcceptPayload('ada-l', senderCurvePub, senderEdPub, embedded),
        hint,
        recipientCurvePub,
      );
      final decoded = await decodeFriendAccept(raw, recipientCurveKp);
      expect(decoded.username, 'ada-l');
      expect(decoded.capabilityToken, embedded);
    }
  });

  test('FRIEND_DECLINE round-trips the declined msg_id', () {
    final msgId = Uint8List.fromList(List.generate(16, (i) => i));
    final raw = encodeFriendDecline(msgId, hint);
    expect(recipientHintOf(raw), hint);
    expect(decodeFriendDecline(raw), msgId);
  });

  test('LOCATION_RESPONSE decodes only for the requester (invariant 4)',
      () async {
    // Build the sealed response the way the node does: hint + sealed 16-byte
    // fixed struct (lat, lon, accuracy, beacon_age_s, zone_id).
    final body = Uint8List(16);
    final bd = ByteData.sublistView(body);
    bd.setInt32(0, 37774900);
    bd.setInt32(4, -122419400);
    bd.setUint16(8, 12);
    bd.setUint32(10, 40);
    bd.setUint16(14, 0xFFFF);
    final raw =
        Uint8List.fromList([...hint, ...await seal(body, recipientCurvePub)]);

    final decoded = await decodeLocationResponse(raw, recipientCurveKp);
    expect(decoded.latMicrodeg, 37774900);
    expect(decoded.lonMicrodeg, -122419400);
    expect(decoded.accuracyM, 12);
    expect(decoded.beaconAgeS, 40);
    expect(decoded.zoneId, 0xFFFF);

    final stranger = await X25519().newKeyPair();
    expect(() => decodeLocationResponse(raw, stranger),
        throwsA(isA<SealedEnvelopeError>()));
  });

  test(
      'LOCATION_RESPONSE carries exactly one coordinate — no history by '
      'construction (invariant 3)', () async {
    // The sealed body is a fixed 16-byte struct: there is physically no
    // room for a second coordinate or a trajectory. Anything else is
    // rejected as malformed.
    final oversize = Uint8List(32); // two coordinates' worth
    final raw = Uint8List.fromList(
        [...hint, ...await seal(oversize, recipientCurvePub)]);
    expect(() => decodeLocationResponse(raw, recipientCurveKp),
        throwsA(isA<FormatException>()));
  });

  test('LOCATION_QUERY payload is exactly the 98-byte token', () async {
    final identity = await testIdentity();
    final token = await issueToken(
      issuerKeyPair: identity.keyPair,
      issuerPub: identity.publicKey,
      granteeEd25519Pub: senderEdPub,
    );
    expect(encodeLocationQuery(token), token);
    expect(() => encodeLocationQuery(Uint8List(97)), throwsArgumentError);
  });

  test('LOCATION_REVOKE encodes the 28-byte revocation key', () {
    final raw = encodeLocationRevoke(
      issuerPubkeyId: Uint8List.fromList(List.filled(8, 1)),
      granteePubkeyId: Uint8List.fromList(List.filled(8, 2)),
      issuedAt: 1751400000,
      nonce: Uint8List.fromList(List.filled(8, 3)),
    );
    expect(raw.length, 28);
    expect(ByteData.sublistView(raw).getUint32(16), 1751400000);
  });

  test('DIRECT_MESSAGE round-trips and opens only for the recipient',
      () async {
    final raw =
        await encodeDirectMessage('meet at gate B ☕', hint, recipientCurvePub);
    expect(recipientHintOf(raw), hint);
    expect(await decodeDirectMessage(raw, recipientCurveKp), 'meet at gate B ☕');

    final stranger = await X25519().newKeyPair();
    expect(() => decodeDirectMessage(raw, stranger),
        throwsA(isA<SealedEnvelopeError>()));
  });

  test('DIRECT_MESSAGE enforces the 1–265 byte text bounds', () async {
    expect(() => encodeDirectMessage('', hint, recipientCurvePub),
        throwsArgumentError);
    // 133 three-byte runes = 399 bytes: over the cap despite < 265 chars.
    expect(() => encodeDirectMessage('☕' * 133, hint, recipientCurvePub),
        throwsArgumentError);
    final max = 'm' * maxDmTextBytes;
    final raw = await encodeDirectMessage(max, hint, recipientCurvePub);
    expect(await decodeDirectMessage(raw, recipientCurveKp), max);
  });

  test('every friendship payload fits the §2 envelope bounds', () async {
    // Envelope overhead is 75 (header) + 64 (signature) = 139 bytes; max
    // packet 460 → max payload 321. Use the largest legal username.
    final longName = 'x' * maxUsernameBytes;
    final identity = await testIdentity();
    final token = await issueToken(
      issuerKeyPair: identity.keyPair,
      issuerPub: identity.publicKey,
      granteeEd25519Pub: senderEdPub,
    );

    final payloads = <String, Uint8List>{
      'FRIEND_REQUEST': await encodeFriendRequest(
          FriendRequestPayload(longName, senderCurvePub, senderEdPub),
          hint,
          recipientCurvePub),
      'FRIEND_ACCEPT+token': await encodeFriendAccept(
          FriendAcceptPayload(longName, senderCurvePub, senderEdPub, token),
          hint,
          recipientCurvePub),
      'FRIEND_DECLINE': encodeFriendDecline(Uint8List(16), hint),
      'LOCATION_QUERY': encodeLocationQuery(token),
      'LOCATION_REVOKE': encodeLocationRevoke(
          issuerPubkeyId: Uint8List(8),
          granteePubkeyId: Uint8List(8),
          issuedAt: 0,
          nonce: Uint8List(8)),
      'LOCATION beacon': encodeLocationBeacon(0, 0, 0),
      'DIRECT_MESSAGE max': await encodeDirectMessage(
          'm' * maxDmTextBytes, hint, recipientCurvePub),
    };
    for (final entry in payloads.entries) {
      expect(entry.value.length, lessThanOrEqualTo(maxPayload),
          reason: '${entry.key} exceeds the max payload');
      // And as a whole signed packet it must sit inside [131, 460].
      final packet = await buildSignedPacket(
        identity: identity,
        ephemId: Uint8List(16),
        payload: entry.value,
        msgType: msgTypeLocationQuery,
        zoneId: broadcastZone,
      );
      expect(packet.length, inInclusiveRange(131, 460), reason: entry.key);
    }
  });
}
