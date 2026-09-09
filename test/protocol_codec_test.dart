import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:itantra/core/protocol/message.dart';
import 'package:itantra/core/protocol/protocol_codec.dart';

void main() {
  const ProtocolCodec codec = ProtocolCodec();

  group('ProtocolCodec', () {
    test('round-trips a text message', () {
      final TextMessage original = TextMessage(
        messageId: 'abc123',
        senderId: 'phone-a',
        languageTag: 'hi-IN',
        text: 'madad chahiye',
        confidencePercent: 87,
      );

      final WireMessage decoded = codec.decode(codec.encode(original));
      expect(decoded, isA<TextMessage>());
      final TextMessage text = decoded as TextMessage;
      expect(text.messageId, 'abc123');
      expect(text.text, 'madad chahiye');
      expect(text.languageTag, 'hi-IN');
      expect(text.confidencePercent, 87);
    });

    test('round-trips an alert with its severity and repeat count', () {
      final AlertMessage original = AlertMessage(
        messageId: 'alert1',
        senderId: 'phone-a',
        languageTag: 'ta-IN',
        text: 'help',
        severity: AlertSeverity.distress,
        repeatCount: 3,
      );

      final AlertMessage decoded =
          codec.decode(codec.encode(original)) as AlertMessage;
      expect(decoded.severity, AlertSeverity.distress);
      expect(decoded.repeatCount, 3);
    });

    test('round-trips a receipt', () {
      final ReceiptMessage original = ReceiptMessage(
        messageId: 'r1',
        senderId: 'phone-b',
        acknowledgedId: 'abc123',
        status: ReceiptStatus.played,
      );

      final ReceiptMessage decoded =
          codec.decode(codec.encode(original)) as ReceiptMessage;
      expect(decoded.acknowledgedId, 'abc123');
      expect(decoded.status, ReceiptStatus.played);
    });

    test('keeps a short message small on the wire', () {
      // The whole premise is a low bitrate link: a short utterance has to fit
      // comfortably inside a couple of hundred bytes, or Bluetooth LE
      // bridging becomes impossible.
      final Uint8List encoded = codec.encode(TextMessage(
        messageId: 'abc123',
        senderId: 'phone-a',
        languageTag: 'hi-IN',
        text: 'aa jao',
        confidencePercent: 90,
      ));
      expect(encoded.length, lessThan(160));
    });

    test('preserves non-Latin text exactly', () {
      // \u0939\u093F\u0928\u094D\u0926\u0940 is "Hindi" in Devanagari.
      const String native = '\u0939\u093F\u0928\u094D\u0926\u0940';
      final TextMessage decoded = codec.decode(codec.encode(TextMessage(
        messageId: 'u1',
        senderId: 'phone-a',
        languageTag: 'hi-IN',
        text: native,
        confidencePercent: 99,
      ))) as TextMessage;
      expect(decoded.text, native);
    });

    test('rejects malformed bytes', () {
      expect(
        () => codec.decode(Uint8List.fromList(<int>[0x7B, 0x00, 0x01])),
        throwsA(isA<CodecException>()),
      );
    });
  });
}
