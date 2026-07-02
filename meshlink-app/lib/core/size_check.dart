import 'dart:typed_data';

import 'message.dart';

/// Step 1: drop packets outside [131, 460] bytes before any parsing.
/// Mirrors meshlink-core/pipeline/size_check.py.
String? checkSize(Uint8List raw) {
  final n = raw.length;
  if (n < minPacket) {
    return 'packet too small: $n bytes (min $minPacket)';
  }
  if (n > maxPacket) {
    return 'packet too large: $n bytes (max $maxPacket)';
  }
  return null;
}
