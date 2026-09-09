/// Which way a message travelled.
enum MessageDirection { outgoing, incoming }

/// Delivery lifecycle. Kept explicit rather than a boolean pair because
/// "sent" and "heard by a human" are very different states in an emergency,
/// and the UI must not conflate them.
enum DeliveryState { pending, sent, delivered, played, failed }

/// A stored transcript row.
class StoredMessage {
  const StoredMessage({
    required this.id,
    required this.direction,
    required this.languageTag,
    required this.text,
    required this.createdAtMs,
    required this.state,
    this.confidence = 1.0,
    this.isAlert = false,
    this.severity,
    this.peerId,
    this.latencyMs,
  });

  final String id;
  final MessageDirection direction;
  final String languageTag;
  final String text;
  final int createdAtMs;
  final DeliveryState state;

  /// 0..1 recogniser confidence.
  final double confidence;

  final bool isAlert;
  final String? severity;
  final String? peerId;
  final double? latencyMs;

  /// Below this the transcript is shown with a warning marker so the reader
  /// treats it with suspicion instead of acting on a misheard place name.
  static const double lowConfidenceThreshold = 0.55;

  bool get isLowConfidence => confidence < lowConfidenceThreshold;

  StoredMessage copyWith({
    DeliveryState? state,
    double? latencyMs,
    String? text,
  }) =>
      StoredMessage(
        id: id,
        direction: direction,
        languageTag: languageTag,
        text: text ?? this.text,
        createdAtMs: createdAtMs,
        state: state ?? this.state,
        confidence: confidence,
        isAlert: isAlert,
        severity: severity,
        peerId: peerId,
        latencyMs: latencyMs ?? this.latencyMs,
      );

  Map<String, Object?> toRow() => <String, Object?>{
        'id': id,
        'direction': direction.name,
        'language_tag': languageTag,
        'text': text,
        'created_at_ms': createdAtMs,
        'state': state.name,
        'confidence': confidence,
        'is_alert': isAlert ? 1 : 0,
        'severity': severity,
        'peer_id': peerId,
        'latency_ms': latencyMs,
      };

  static StoredMessage fromRow(Map<String, Object?> row) => StoredMessage(
        id: row['id']! as String,
        direction: MessageDirection.values.firstWhere(
          (MessageDirection d) => d.name == row['direction'],
          orElse: () => MessageDirection.incoming,
        ),
        languageTag: row['language_tag']! as String,
        text: row['text']! as String,
        createdAtMs: row['created_at_ms']! as int,
        state: DeliveryState.values.firstWhere(
          (DeliveryState s) => s.name == row['state'],
          orElse: () => DeliveryState.pending,
        ),
        confidence: (row['confidence'] as num?)?.toDouble() ?? 1.0,
        isAlert: (row['is_alert'] as int?) == 1,
        severity: row['severity'] as String?,
        peerId: row['peer_id'] as String?,
        latencyMs: (row['latency_ms'] as num?)?.toDouble(),
      );
}

/// A remembered peer, so re-pairing after a battery swap is one tap.
class StoredPeer {
  const StoredPeer({
    required this.id,
    required this.label,
    required this.transport,
    required this.address,
    required this.lastSeenMs,
    this.ttsLanguages = const <String>[],
  });

  final String id;
  final String label;
  final String transport;
  final String address;
  final int lastSeenMs;

  /// What the peer said it can speak, so the sender can warn before talking
  /// into a language the far end cannot voice.
  final List<String> ttsLanguages;

  Map<String, Object?> toRow() => <String, Object?>{
        'id': id,
        'label': label,
        'transport': transport,
        'address': address,
        'last_seen_ms': lastSeenMs,
        'tts_languages': ttsLanguages.join(','),
      };

  static StoredPeer fromRow(Map<String, Object?> row) {
    final String raw = (row['tts_languages'] as String?) ?? '';
    return StoredPeer(
      id: row['id']! as String,
      label: (row['label'] as String?) ?? 'peer',
      transport: (row['transport'] as String?) ?? 'wifi',
      address: (row['address'] as String?) ?? '',
      lastSeenMs: (row['last_seen_ms'] as int?) ?? 0,
      ttsLanguages: raw.isEmpty ? const <String>[] : raw.split(','),
    );
  }
}
