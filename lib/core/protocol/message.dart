import 'dart:convert';

/// Wire messages.
///
/// The JSON keys are single letters. On a Bluetooth SPP link at a few
/// kilobytes per second the header is a real fraction of a short message, so
/// "l" instead of "language" is not premature optimisation - it is the
/// difference between a 60-byte frame and a 140-byte one. Constants below
/// give the names back to the code.
enum MessageKind {
  text('x'),
  alert('a'),
  receipt('r'),
  floor('f'),
  capabilities('c'),
  handshake('h');

  const MessageKind(this.code);

  final String code;

  static MessageKind? fromCode(String code) {
    for (final MessageKind kind in MessageKind.values) {
      if (kind.code == code) return kind;
    }
    return null;
  }
}

/// Alert severity. Distress overrides everything, including an in-progress
/// voice note and the user's media volume.
enum AlertSeverity {
  distress('d'),
  warning('w');

  const AlertSeverity(this.code);

  final String code;

  static AlertSeverity fromCode(String code) =>
      code == 'd' ? AlertSeverity.distress : AlertSeverity.warning;
}

/// Receipt kind: parsed/played, or rejected.
enum ReceiptStatus {
  played('p'),
  rejected('r');

  const ReceiptStatus(this.code);

  final String code;

  static ReceiptStatus fromCode(String code) =>
      code == 'p' ? ReceiptStatus.played : ReceiptStatus.rejected;
}

/// Floor control operation for push-to-talk arbitration.
enum FloorOp {
  request('q'),
  grant('g'),
  reject('r'),
  release('d');

  const FloorOp(this.code);

  final String code;

  static FloorOp? fromCode(String code) {
    for (final FloorOp op in FloorOp.values) {
      if (op.code == code) return op;
    }
    return null;
  }
}

/// Limits enforced on both encode and decode.
///
/// A peer is not trusted just because it is on the same hotspot; a malformed
/// or hostile frame must be rejected by size before anything allocates.
class ProtocolLimits {
  const ProtocolLimits._();

  static const int version = 1;
  static const int maxTextBytes = 4096;
  static const int maxMessageBytes = 8192;
}

/// Base class for everything that crosses the link.
sealed class WireMessage {
  const WireMessage({
    required this.messageId,
    required this.senderId,
  });

  /// "i" on the wire. Used for deduplication and to correlate receipts.
  final String messageId;

  /// "s" on the wire.
  final String senderId;

  MessageKind get kind;

  Map<String, Object?> toJson();
}

/// A recognised utterance.
class TextMessage extends WireMessage {
  const TextMessage({
    required super.messageId,
    required super.senderId,
    required this.languageTag,
    required this.text,
    required this.confidencePercent,
    this.isFinal = true,
  });

  final String languageTag;
  final String text;

  /// Percent, as an integer, because a float would cost bytes and nobody
  /// needs two decimal places of recogniser confidence.
  final int confidencePercent;

  final bool isFinal;

  @override
  MessageKind get kind => MessageKind.text;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        't': kind.code,
        'i': messageId,
        's': senderId,
        'l': languageTag,
        'x': text,
        'q': confidencePercent,
        'f': isFinal,
      };

  static TextMessage fromJson(Map<String, Object?> json) => TextMessage(
        messageId: json['i']! as String,
        senderId: json['s']! as String,
        languageTag: json['l']! as String,
        text: json['x']! as String,
        confidencePercent: (json['q'] as int?) ?? 0,
        isFinal: (json['f'] as bool?) ?? true,
      );
}

/// A non-interruptible announcement.
class AlertMessage extends WireMessage {
  const AlertMessage({
    required super.messageId,
    required super.senderId,
    required this.languageTag,
    required this.text,
    required this.severity,
    this.repeatCount = 2,
  });

  final String languageTag;
  final String text;
  final AlertSeverity severity;

  /// Repeats, 1-5. Someone who was not looking at the phone when it started
  /// still needs to hear the whole thing.
  final int repeatCount;

  @override
  MessageKind get kind => MessageKind.alert;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        't': kind.code,
        'i': messageId,
        's': senderId,
        'l': languageTag,
        'x': text,
        'v': severity.code,
        'r': repeatCount,
      };

  static AlertMessage fromJson(Map<String, Object?> json) => AlertMessage(
        messageId: json['i']! as String,
        senderId: json['s']! as String,
        languageTag: json['l']! as String,
        text: json['x']! as String,
        severity: AlertSeverity.fromCode((json['v'] as String?) ?? 'w'),
        repeatCount: ((json['r'] as int?) ?? 2).clamp(1, 5),
      );
}

/// Acknowledgement, which is also the sender's latency probe.
class ReceiptMessage extends WireMessage {
  const ReceiptMessage({
    required super.messageId,
    required super.senderId,
    required this.acknowledgedId,
    required this.status,
  });

  final String acknowledgedId;
  final ReceiptStatus status;

  @override
  MessageKind get kind => MessageKind.receipt;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        't': kind.code,
        'i': messageId,
        's': senderId,
        'a': acknowledgedId,
        'g': status.code,
      };

  static ReceiptMessage fromJson(Map<String, Object?> json) =>
      ReceiptMessage(
        messageId: json['i']! as String,
        senderId: json['s']! as String,
        acknowledgedId: json['a']! as String,
        status: ReceiptStatus.fromCode((json['g'] as String?) ?? 'p'),
      );
}

/// Half-duplex arbitration, so two people talking at once do not interleave.
class FloorMessage extends WireMessage {
  const FloorMessage({
    required super.messageId,
    required super.senderId,
    required this.op,
    this.waitMs,
  });

  final FloorOp op;

  /// On reject, how long the other side should back off.
  final int? waitMs;

  @override
  MessageKind get kind => MessageKind.floor;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        't': kind.code,
        'i': messageId,
        's': senderId,
        'o': op.code,
        if (waitMs != null) 'w': waitMs,
      };

  static FloorMessage fromJson(Map<String, Object?> json) => FloorMessage(
        messageId: json['i']! as String,
        senderId: json['s']! as String,
        op: FloorOp.fromCode((json['o'] as String?) ?? 'q') ??
            FloorOp.request,
        waitMs: json['w'] as int?,
      );
}

/// The key exchange, and the only message ever sent in the clear.
///
/// Two phones that have just met on an untrusted hotspot need to agree on a
/// session key. X25519 over the link gives them that against a passive
/// listener, but nothing at all against an attacker who sits in the middle and
/// runs a separate handshake with each side. There is no certificate authority
/// offline, so the defence has to be a human: both phones derive the same
/// six-digit code from both public keys, and the users compare them out loud.
///
/// This message therefore carries the sender's ephemeral public key *and* its
/// capabilities, so pairing costs one round trip rather than two. It is
/// self-describing and small: a 32-byte key in base64 is 43 characters, and
/// the whole frame is under 200 bytes.
class HandshakeMessage extends WireMessage {
  const HandshakeMessage({
    required super.messageId,
    required super.senderId,
    required this.publicKey,
    required this.role,
    this.asrLanguages = const <String>[],
    this.ttsLanguages = const <String>[],
    this.appVersion = '0',
    this.protocolVersion = ProtocolLimits.version,
    this.displayName,
  });

  /// Raw 32-byte X25519 public key.
  final List<int> publicKey;

  /// 'a' for the side that dialled, 'b' for the side that listened. It decides
  /// which direction uses which nonce prefix, so the two ends cannot collide.
  final String role;

  final List<String> asrLanguages;
  final List<String> ttsLanguages;
  final String appVersion;
  final int protocolVersion;

  /// Friendly name shown during verification, e.g. "Android · Ravi".
  final String? displayName;

  bool get isInitiator => role == 'a';

  @override
  MessageKind get kind => MessageKind.handshake;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        't': kind.code,
        'i': messageId,
        's': senderId,
        'k': base64Url.encode(publicKey),
        'o': role,
        'ar': asrLanguages,
        'tr': ttsLanguages,
        'av': appVersion,
        'pv': protocolVersion,
        if (displayName != null) 'n': displayName,
      };

  static HandshakeMessage fromJson(Map<String, Object?> json) {
    final Object? key = json['k'];
    if (key is! String) {
      throw const FormatException('handshake has no public key');
    }
    final List<int> bytes;
    try {
      bytes = base64Url.decode(key);
    } on FormatException {
      throw const FormatException('handshake key is not valid base64url');
    }
    if (bytes.length != 32) {
      throw const FormatException('handshake key is not 32 bytes');
    }

    final Object? role = json['o'];
    return HandshakeMessage(
      messageId: json['i']! as String,
      senderId: json['s']! as String,
      publicKey: bytes,
      role: role is String && role == 'b' ? 'b' : 'a',
      asrLanguages: _stringList(json['ar']),
      ttsLanguages: _stringList(json['tr']),
      appVersion: (json['av'] as String?) ?? '0',
      protocolVersion: (json['pv'] as int?) ?? ProtocolLimits.version,
      displayName: json['n'] as String?,
    );
  }

  static List<String> _stringList(Object? raw) {
    if (raw is! List) return const <String>[];
    return raw.whereType<String>().toList(growable: false);
  }
}

/// Exchanged once per link so each side knows which languages the other can
/// actually speak and hear.
class CapabilitiesMessage extends WireMessage {
  const CapabilitiesMessage({
    required super.messageId,
    required super.senderId,
    required this.asrLanguages,
    required this.ttsLanguages,
    required this.appVersion,
    required this.protocolVersion,
  });

  final List<String> asrLanguages;
  final List<String> ttsLanguages;
  final String appVersion;
  final int protocolVersion;

  @override
  MessageKind get kind => MessageKind.capabilities;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        't': kind.code,
        'i': messageId,
        's': senderId,
        'ar': asrLanguages,
        'tr': ttsLanguages,
        'av': appVersion,
        'pv': protocolVersion,
      };

  static CapabilitiesMessage fromJson(Map<String, Object?> json) =>
      CapabilitiesMessage(
        messageId: json['i']! as String,
        senderId: json['s']! as String,
        asrLanguages: ((json['ar'] as List<Object?>?) ?? <Object?>[])
            .map((Object? e) => e! as String)
            .toList(growable: false),
        ttsLanguages: ((json['tr'] as List<Object?>?) ?? <Object?>[])
            .map((Object? e) => e! as String)
            .toList(growable: false),
        appVersion: (json['av'] as String?) ?? '0',
        protocolVersion: (json['pv'] as int?) ?? ProtocolLimits.version,
      );
}
