import 'dart:convert';
import 'dart:typed_data';

import 'message.dart';

/// Raised when a frame cannot be turned into a message.
class CodecException implements Exception {
  const CodecException(this.message);

  final String message;

  @override
  String toString() => 'CodecException: $message';
}

/// JSON codec for wire messages.
///
/// JSON rather than protobuf or a hand-rolled binary format, deliberately:
/// the payloads are short text, the compact single-letter keys already remove
/// most of the overhead, and a human being can read a captured frame during a
/// demo without a schema file. That debuggability is worth more here than the
/// remaining few bytes.
class ProtocolCodec {
  const ProtocolCodec();

  Uint8List encode(WireMessage message) {
    final String text = jsonEncode(message.toJson());
    final Uint8List bytes = Uint8List.fromList(utf8.encode(text));
    if (bytes.length > ProtocolLimits.maxMessageBytes) {
      throw CodecException(
          'message ${bytes.length} bytes exceeds ${ProtocolLimits.maxMessageBytes}');
    }
    return bytes;
  }

  WireMessage decode(Uint8List payload) {
    if (payload.length > ProtocolLimits.maxMessageBytes) {
      throw CodecException('payload too large: ${payload.length}');
    }

    final Object? parsed;
    try {
      parsed = jsonDecode(utf8.decode(payload));
    } on FormatException catch (e) {
      throw CodecException('not valid JSON: ${e.message}');
    }

    if (parsed is! Map<String, Object?>) {
      throw const CodecException('top level value is not an object');
    }

    final Object? typeCode = parsed['t'];
    if (typeCode is! String) {
      throw const CodecException('missing message type');
    }
    if (parsed['i'] is! String || parsed['s'] is! String) {
      throw const CodecException('missing message or sender id');
    }

    final MessageKind? kind = MessageKind.fromCode(typeCode);
    if (kind == null) {
      // Forward compatibility: an unknown kind is reported, not fatal, so a
      // future build can add message types without breaking this one.
      throw CodecException('unknown message type "$typeCode"');
    }

    switch (kind) {
      case MessageKind.text:
        _requireText(parsed);
        return TextMessage.fromJson(parsed);
      case MessageKind.alert:
        _requireText(parsed);
        return AlertMessage.fromJson(parsed);
      case MessageKind.receipt:
        if (parsed['a'] is! String) {
          throw const CodecException('receipt missing acknowledged id');
        }
        return ReceiptMessage.fromJson(parsed);
      case MessageKind.floor:
        return FloorMessage.fromJson(parsed);
      case MessageKind.capabilities:
        return CapabilitiesMessage.fromJson(parsed);
    }
  }

  void _requireText(Map<String, Object?> json) {
    final Object? text = json['x'];
    if (text is! String) {
      throw const CodecException('missing text body');
    }
    if (utf8.encode(text).length > ProtocolLimits.maxTextBytes) {
      throw const CodecException('text body exceeds limit');
    }
    if (json['l'] is! String) {
      throw const CodecException('missing language tag');
    }
  }
}
