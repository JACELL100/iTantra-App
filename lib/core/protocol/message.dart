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
  capabilities('c');

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
    this.srcLang,
    this.tgtLang,
    this.translatedText,
  });

  /// Source language (BCP-47). For backward compat, equals languageTag.
  final String languageTag;

  /// Transcribed text in source language.
  final String text;

  /// Percent, as an integer, because a float would cost bytes and nobody
  /// needs two decimal places of recogniser confidence.
  final int confidencePercent;

  final bool isFinal;

  /// Source language for translation (may differ from languageTag if LID used).
  final String? srcLang;

  /// Target language for translation (null = same-language mode).
  final String? tgtLang;

  /// Translated text in target language (present when tgtLang != null).
  final String? translatedText;

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
        if (srcLang != null) 'sl': srcLang,
        if (tgtLang != null) 'tl': tgtLang,
        if (translatedText != null) 'tx': translatedText,
      };

  static TextMessage fromJson(Map<String, Object?> json) => TextMessage(
        messageId: json['i']! as String,
        senderId: json['s']! as String,
        languageTag: json['l']! as String,
        text: json['x']! as String,
        confidencePercent: (json['q'] as int?) ?? 0,
        isFinal: (json['f'] as bool?) ?? true,
        srcLang: json['sl'] as String?,
        tgtLang: json['tl'] as String?,
        translatedText: json['tx'] as String?,
      );

  /// Language the receiver should speak (tgtLang if present, else languageTag).
  String get speakLanguage => tgtLang ?? languageTag;

  /// Text the receiver should speak (translatedText if present, else text).
  String get speakText => translatedText ?? text;

  /// Whether this is a cross-language message.
  bool get isCrossLanguage => tgtLang != null && tgtLang != languageTag;
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
