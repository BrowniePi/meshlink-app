import 'dart:typed_data';

import 'package:blake3_dart/blake3_dart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshlink_app/core/message_factory.dart';

/// msg_id must be BLAKE3(sender_key ‖ timestamp_be4 ‖ msg_type_byte ‖
/// payload)[0:16], byte-for-byte identical to the Python core (blake3 PyPI
/// package there). Pin blake3_dart against official BLAKE3 vectors so a
/// package swap or regression can't silently fork the wire format.
void main() {
  test('blake3_dart matches official BLAKE3 test vectors', () {
    // https://github.com/BLAKE3-team/BLAKE3/blob/master/test_vectors —
    // input is bytes 0,1,2,…,249,0,1,… truncated to input_len.
    Uint8List input(int len) =>
        Uint8List.fromList(List.generate(len, (i) => i % 251));

    expect(blake3Hex(input(0)),
        'af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262');
    expect(blake3Hex(input(1)),
        '2d3adedff11b61f14c886e35afa036736dcd87a74d27b5c1510225d0f592e213');
    expect(blake3Hex(input(1024)),
        '42214739f095a406f3fc83deb889744ac00df831c10daa55189b5d121c855af7');
  });

  test('16-byte truncation equals the 32-byte digest prefix', () {
    final data = Uint8List.fromList([1, 2, 3]);
    expect(blake3(data, 16), blake3(data, 32).sublist(0, 16));
  });

  test('deriveMsgId hashes the documented preimage', () {
    final senderKey = Uint8List.fromList(List.generate(32, (i) => i));
    final payload = Uint8List.fromList([0xde, 0xad, 0xbe, 0xef]);
    const timestamp = 0x01020304;
    const msgType = 0x01;

    final preimage = Uint8List.fromList([
      ...senderKey,
      0x01, 0x02, 0x03, 0x04, // timestamp, big-endian uint32
      msgType,
      ...payload,
    ]);
    expect(
      deriveMsgId(
        senderKey: senderKey,
        timestamp: timestamp,
        msgType: msgType,
        payload: payload,
      ),
      blake3(preimage, 16),
    );
  });
}
