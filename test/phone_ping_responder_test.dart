import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshlink_app/telemetry/phone_ping_responder.dart';

Uint8List _frame(String jsonAfterMagic) =>
    Uint8List.fromList([...phonePingMagic, ...utf8.encode(jsonAfterMagic)]);

void main() {
  group('demux rule (spec §2)', () {
    test('MLPP1-prefixed frames are telemetry', () {
      expect(isTelemetryFrame(_frame('{"t":"ping"}')), isTrue);
      expect(isTelemetryFrame(Uint8List.fromList('MLPP1'.codeUnits)), isTrue);
    });

    test('mesh-like packets and short frames are not telemetry', () {
      expect(isTelemetryFrame(Uint8List(131)), isFalse); // random msg_id start
      expect(isTelemetryFrame(Uint8List.fromList('MLP'.codeUnits)), isFalse);
      expect(isTelemetryFrame(Uint8List(0)), isFalse);
    });
  });

  group('encodePong (spec §3 wire format)', () {
    test('full reading matches the spec example byte-for-byte', () {
      final pong = encodePong(
          lat: 51.5074, lon: -0.1278, battery: 84, charging: true);
      expect(
        utf8.decode(pong),
        'MLPP1{"t":"pong","lat":51.5074,"lon":-0.1278,"battery":84,'
        '"charging":true}',
      );
    });

    test('nullable fields are sent as null; unknown charging is omitted', () {
      final pong = encodePong();
      expect(utf8.decode(pong),
          'MLPP1{"t":"pong","lat":null,"lon":null,"battery":null}');
    });
  });

  group('PhonePingResponder.handle', () {
    test('a ping triggers exactly one pong to the same peer', () async {
      final responder = PhonePingResponder(
        reader: () async => const TelemetryReading(
            lat: 1.5, lon: 2.5, battery: 77, charging: false),
      );
      final sent = <(String, Uint8List)>[];
      await responder.handle('ble:node', _frame('{"t":"ping"}'),
          (peer, frame) async => sent.add((peer, frame)));

      expect(sent, hasLength(1));
      expect(sent.single.$1, 'ble:node');
      expect(
        utf8.decode(sent.single.$2),
        'MLPP1{"t":"pong","lat":1.5,"lon":2.5,"battery":77,"charging":false}',
      );
    });

    test('unknown extra keys in the ping are tolerated (spec §3)', () async {
      final responder =
          PhonePingResponder(reader: () async => const TelemetryReading());
      final sent = <Uint8List>[];
      await responder.handle('wifi:node', _frame('{"t":"ping","v":2}'),
          (_, frame) async => sent.add(frame));
      expect(sent, hasLength(1));
    });

    test('invalid JSON, missing t, and non-ping types are dropped silently',
        () async {
      final responder =
          PhonePingResponder(reader: () async => const TelemetryReading());
      final sent = <Uint8List>[];
      Future<void> send(String peer, Uint8List frame) async => sent.add(frame);

      await responder.handle('p', _frame('not json'), send);
      await responder.handle('p', _frame('{"x":1}'), send);
      await responder.handle('p', _frame('{"t":"pong"}'), send);
      await responder.handle('p', _frame('[1,2]'), send);
      expect(sent, isEmpty);
    });

    test('a second ping while one is in flight coalesces to one pong (spec §4)',
        () async {
      final gate = Completer<TelemetryReading>();
      final responder = PhonePingResponder(reader: () => gate.future);
      final sent = <Uint8List>[];
      Future<void> send(String peer, Uint8List frame) async => sent.add(frame);

      final first = responder.handle('p', _frame('{"t":"ping"}'), send);
      final second = responder.handle('p', _frame('{"t":"ping"}'), send);
      gate.complete(const TelemetryReading(battery: 50));
      await Future.wait([first, second]);

      expect(sent, hasLength(1));

      // ...and the responder isn't stuck: the next ping is answered.
      await responder.handle('p', _frame('{"t":"ping"}'), send);
      expect(sent, hasLength(2));
    });

    test('node identity riding on the ping is captured for the UI', () async {
      final responder =
          PhonePingResponder(reader: () async => const TelemetryReading());
      Future<void> send(String peer, Uint8List frame) async {}

      // Plain ping (node unconfigured): nothing captured.
      await responder.handle('ble:node', _frame('{"t":"ping"}'), send);
      expect(responder.nodeInfo.value, isNull);

      await responder.handle(
          'ble:node',
          _frame('{"t":"ping","node_name":"Gate N","node_lat":18.94,'
              '"node_lon":72.83}'),
          send);
      final info = responder.nodeInfo.value!;
      expect(info.peerId, 'ble:node');
      expect(info.name, 'Gate N');
      expect(info.lat, 18.94);
      expect(info.lon, 72.83);

      // A later plain ping doesn't clobber the captured identity.
      await responder.handle('ble:node', _frame('{"t":"ping"}'), send);
      expect(responder.nodeInfo.value?.name, 'Gate N');
    });

    test('a send failure never escapes (node ages the report out)', () async {
      final responder =
          PhonePingResponder(reader: () async => const TelemetryReading());
      await responder.handle('p', _frame('{"t":"ping"}'),
          (_, _) async => throw StateError('peer gone'));
      // No throw — and the in-flight slot was released.
      final sent = <Uint8List>[];
      await responder.handle('p', _frame('{"t":"ping"}'),
          (_, frame) async => sent.add(frame));
      expect(sent, hasLength(1));
    });
  });
}
