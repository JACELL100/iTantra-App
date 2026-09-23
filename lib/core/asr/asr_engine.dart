import 'dart:typed_data';

/// Recognition result for one utterance.
class AsrResult {
  const AsrResult({
    required this.text,
    required this.confidence,
    required this.languageTag,
    required this.audioMs,
    required this.computeMs,
    this.isSimulated = false,
    this.reportsConfidence = true,
  });

  final String text;

  /// 0..1. Derived from the mean per-frame probability of the emitted path,
  /// which is crude but monotonic: it reliably separates "clean speech" from
  /// "wind noise the model guessed at", and that is all the UI needs it for.
  final double confidence;

  final String languageTag;
  final int audioMs;
  final int computeMs;

  /// True when the text did not come from listening to the audio at all.
  ///
  /// Only the demonstration engine sets this. It is carried all the way to the
  /// screen because a transcript that looks like speech but was not recognised
  /// from speech is the one thing in this app that could mislead somebody.
  final bool isSimulated;

  /// False when the engine has no confidence to report - a hosted endpoint
  /// returns a transcript and nothing else. The UI must then stay silent about
  /// confidence rather than reading 0 as "very unsure".
  final bool reportsConfidence;

  /// Real-time factor: compute time over audio duration. Below 1.0 means
  /// faster than real time. This is a scored metric, so it is measured, not
  /// estimated.
  double get realTimeFactor => audioMs == 0 ? 0 : computeMs / audioMs;

  bool get isEmpty => text.trim().isEmpty;

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
  Future<AsrResult> transcribe({
    required Int16List pcm,
    required String languageTag,
  });

  /// Loads a model ahead of first use, so the first message of a session does
  /// not pay a second of session-creation cost.
  Future<void> warmUp(String languageTag);

  Future<void> dispose();
}
