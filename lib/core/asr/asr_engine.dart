import 'dart:typed_data';

/// Recognition result for one utterance.
class AsrResult {
  const AsrResult({
    required this.text,
    required this.confidence,
    required this.languageTag,
    required this.audioMs,
    required this.computeMs,
    this.translatedText,
    this.targetLanguageTag,
  });

  final String text;

  /// 0..1. Derived from the mean per-frame probability of the emitted path,
  /// which is crude but monotonic: it reliably separates "clean speech" from
  /// "wind noise the model guessed at", and that is all the UI needs it for.
  final double confidence;

  final String languageTag;
  final int audioMs;
  final int computeMs;

  /// Optional translation (when ASR engine supports it, e.g., Gemma 4 E2B).
  final String? translatedText;

  /// Target language for translation (if translatedText is present).
  final String? targetLanguageTag;

  /// Real-time factor: compute time over audio duration. Below 1.0 means
  /// faster than real time. This is a scored metric, so it is measured, not
  /// estimated.
  double get realTimeFactor => audioMs == 0 ? 0 : computeMs / audioMs;

  bool get isEmpty => text.trim().isEmpty;

  bool get hasTranslation => translatedText != null && translatedText!.isNotEmpty;

  static const AsrResult empty = AsrResult(
    text: '',
    confidence: 0,
    languageTag: '',
    audioMs: 0,
    computeMs: 0,
  );
}

class AsrException implements Exception {
  const AsrException(this.message, {this.isMissingModel = false});

  final String message;

  /// Distinguished so the UI can say "install the Tamil pack" rather than
  /// "recognition failed", which would send a user hunting for a bug that
  /// does not exist.
  final bool isMissingModel;

  @override
  String toString() => 'AsrException: $message';
}

/// Speech to text.
///
/// Deliberately utterance-at-a-time rather than streaming. The endpointer
/// already decides where sentences end, and a single forward pass over a
/// closed 2-4 second utterance is both more accurate and cheaper on a low-end
/// CPU than re-running a streaming decoder every 200 ms - and idle CPU is
/// explicitly scored.
abstract class AsrEngine {
  /// Languages this engine can currently serve.
  Set<String> get availableLanguages;

  /// Transcribes 16 kHz mono PCM.
  /// Optionally translates to targetLanguageTag if supported.
  Future<AsrResult> transcribe({
    required Int16List pcm,
    required String languageTag,
    String? targetLanguageTag,
  });

  /// Loads a model ahead of first use, so the first message of a session does
  /// not pay a second of session-creation cost.
  Future<void> warmUp(String languageTag);

  Future<void> dispose();
}
