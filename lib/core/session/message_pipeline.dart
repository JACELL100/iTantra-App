import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import '../metrics/metrics.dart';
import '../protocol/message.dart';
import '../protocol/protocol_codec.dart';
import '../security/session_crypto.dart';
import '../transport/transport_adapter.dart';
import '../util/log.dart';

/// What the pipeline reports upward for each received frame.
sealed class Inbound {
  const Inbound();
}

class InboundMessage extends Inbound {
  const InboundMessage(this.message);

  final WireMessage message;
}

/// A frame we have already handled. Reported rather than dropped silently so
/// the diagnostics screen can show that a link is retransmitting.
class InboundDuplicate extends Inbound {
  const InboundDuplicate(this.messageId);

  final String messageId;
}

class InboundRejected extends Inbound {
  const InboundRejected(this.reason);

  final String reason;
}

/// Encode, encrypt, send; receive, decrypt, decode, de-duplicate.
///
/// This is the only place that knows about both the codec and the transport,
/// which keeps the session logic above it free of byte handling and lets the
/// whole stack be exercised over a loopback transport in a unit test.
class MessagePipeline {
  MessagePipeline({
    required TransportAdapter transport,
    required MetricsCollector metrics,
    required this.deviceId,
    SessionCrypto? crypto,
  })  : _transport = transport,
        _metrics = metrics,
        _crypto = crypto;

  final TransportAdapter _transport;
  final MetricsCollector _metrics;
  final String deviceId;

  SessionCrypto? _crypto;

  static const ProtocolCodec _codec = ProtocolCodec();

  /// Bounded set of seen ids, oldest evicted first.
  ///
  /// Deduplication matters because a lossy link means retransmission, and
  /// announcing the same distress alert twice at full volume would be taken
  /// as two separate emergencies.
  final LinkedHashSet<String> _seen = LinkedHashSet<String>();
  static const int _seenCapacity = 256;

  final Random _random = Random.secure();

  /// Attaches keys after pairing completes. Until then the link is plaintext,
  /// which is only ever the case for the loopback demo transport.
  void attachCrypto(SessionCrypto crypto) {
    _crypto = crypto;
  }

  bool get isEncrypted => _crypto != null;

  /// 96 bits of randomness, base-36. Short enough to keep the frame small,
  /// wide enough that two phones never collide.
  String newMessageId() {
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < 4; i++) {
      out.write(_random.nextInt(1 << 24).toRadixString(36));
    }
    return out.toString();
  }

  Stream<Inbound> inbound() async* {
    await for (final Uint8List frame in _transport.inbound) {
      final int receivedMicros = MetricsCollector.nowMicros();

      Uint8List payload = frame;
      final SessionCrypto? crypto = _crypto;
      if (crypto != null) {
        try {
          payload = await crypto.open(frame);
        } on CryptoException catch (e) {
          _metrics.increment('inbound_crypto_failures');
          ItLog.w('pipeline', 'rejected frame: ${e.message}');
          yield InboundRejected(e.message);
          continue;
        }
      }

      WireMessage message;
      try {
        message = _codec.decode(payload);
      } on CodecException catch (e) {
        _metrics.increment('inbound_decode_failures');
        yield InboundRejected(e.message);
        continue;
      }

      if (_seen.contains(message.messageId)) {
        _metrics.increment('inbound_duplicates');
        yield InboundDuplicate(message.messageId);
        continue;
      }
      _seen.add(message.messageId);
      while (_seen.length > _seenCapacity) {
        _seen.remove(_seen.first);
      }

      _metrics.increment('inbound_messages');
      _metrics.mark(message.messageId, Stage.b0Received, receivedMicros);
      yield InboundMessage(message);
    }
  }

  Future<void> send(WireMessage message) async {
    _metrics.mark(message.messageId, Stage.a3Queued);

    Uint8List payload = _codec.encode(message);
    final SessionCrypto? crypto = _crypto;
    if (crypto != null) {
      payload = await crypto.seal(payload);
    }

    await _transport.send(payload);

    _metrics.mark(message.messageId, Stage.a4Sent);
    _metrics.increment('outbound_messages');
    _metrics.increment('outbound_bytes', payload.length);
  }

  Future<TextMessage> sendText({
    required String text,
    required String languageTag,
    required double confidence,
    String? messageId,
  }) async {
    final TextMessage message = TextMessage(
      messageId: messageId ?? newMessageId(),
      senderId: deviceId,
      languageTag: languageTag,
      text: text,
      confidencePercent: (confidence * 100).round().clamp(0, 100),
    );
    await send(message);
    return message;
  }

  Future<AlertMessage> sendAlert({
    required String text,
    required String languageTag,
    required AlertSeverity severity,
    int repeatCount = 2,
  }) async {
    final AlertMessage message = AlertMessage(
      messageId: newMessageId(),
      senderId: deviceId,
      languageTag: languageTag,
      text: text,
      severity: severity,
      repeatCount: repeatCount,
    );
    await send(message);
    return message;
  }

  Future<void> sendReceipt(
    String acknowledgedId, {
    ReceiptStatus status = ReceiptStatus.played,
  }) =>
      send(ReceiptMessage(
        messageId: newMessageId(),
        senderId: deviceId,
        acknowledgedId: acknowledgedId,
        status: status,
      ));

  Future<void> sendFloor(FloorOp op, {int? waitMs}) => send(FloorMessage(
        messageId: newMessageId(),
        senderId: deviceId,
        op: op,
        waitMs: waitMs,
      ));
}
