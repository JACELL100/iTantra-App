import 'dart:async';
import 'dart:typed_data';

/// Request for speech synthesis.
class SynthesisRequest {
  const SynthesisRequest({
    required this.text,
    required this.languageTag,
    this.speakerId,
    this.speed = 1.0,
    this.isAlert = false,
  });

  final String text;
  final String languageTag;
  final String? speakerId;
  final double speed;
  final bool isAlert;
}

/// A chunk of synthesized PCM audio.
class SynthesisChunk {
  const SynthesisChunk({
    required this.samples,
    required this.sampleRateHz,
    required this.isLast,
  });

  final Float32List samples;
  final int sampleRateHz;
  final bool isLast;
}

/// Exception thrown by TTS engines.
class TtsException implements Exception {
  const TtsException(this.message, {this.isMissingModel = false});

  final String message;
  final bool isMissingModel;

  @override
  String toString() => 'TtsException: $message';
}

/// Text to speech.
abstract class TtsEngine {
  /// Languages this engine can currently serve.
  Set<String> get availableLanguages;

  /// Synthesizes text to a stream of PCM chunks.
  Stream<SynthesisChunk> synthesize(SynthesisRequest request);

  /// Loads a model ahead of first use.
  Future<void> warmUp(String languageTag);

  Future<void> dispose();
}