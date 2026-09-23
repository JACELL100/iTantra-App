import 'dart:typed_data';

/// One synthesis job.
class SynthesisRequest {
  const SynthesisRequest({
    required this.text,
    required this.languageTag,
    this.speakingRate = 1.0,
    this.isAlert = false,
  });

  final String text;

  /// The language the text actually is, never the UI language. A message that
  /// arrived in Odia must be spoken with the Odia voice even if the reader's
  /// interface is in English.
  final String languageTag;

  /// 1.0 is the voice's natural rate. Below 1.0 is slower.
  ///
  /// Alerts use 0.92: measured against a phone speaker in a noisy room, a
  /// slightly slower delivery is more intelligible, and intelligibility is
  /// worth more than pace on a distress message.
  final double speakingRate;

  /// Lets an engine pick a steadier synthesis configuration - less expressive,
  /// more predictable - when the content is an emergency announcement.
  final bool isAlert;

  SynthesisRequest withRate(double rate) => SynthesisRequest(
        text: text,
        languageTag: languageTag,
        speakingRate: rate,
        isAlert: isAlert,
      );
}

/// One block of synthesised audio, emitted as soon as it exists.
///
/// Chunked rather than a single buffer so playback can start while the rest of
/// the sentence is still being generated. On a low-end phone a three-second
/// sentence takes over a second to synthesise, so this is the single largest
/// perceived-latency win available on the receive side.
class SynthesisChunk {
  const SynthesisChunk({
    required this.samples,
    required this.sampleRateHz,
    required this.isLast,
    this.chunkIndex = 0,
  });

  final Int16List samples;

  /// The model's own output rate. Resampling happens once, at the output
  /// device, not per chunk.
  final int sampleRateHz;

  /// True for the final chunk of the utterance. Playback uses it to know when
  /// it may drain and report completion.
  final bool isLast;

  /// Index of the text clause this chunk came from, so the UI can show
  /// progress through a long message.
  final int chunkIndex;

  int get durationMs =>
      sampleRateHz == 0 ? 0 : samples.length * 1000 ~/ sampleRateHz;
}

/// Raised when synthesis cannot proceed.
class TtsException implements Exception {
  const TtsException(this.message, {this.isMissingModel = false});

  final String message;

  /// Distinguished so the UI can say "install the Odia voice pack" instead of
  /// "synthesis failed", which would send someone hunting for a bug that does
  /// not exist. The same distinction exists on the recognition side.
  final bool isMissingModel;

  @override
  String toString() => 'TtsException: $message';
}

/// Text to speech.
///
/// Utterance-at-a-time rather than an audio-streaming API, because the wire
/// protocol only ever delivers whole segments and streaming synthesis would
/// mean committing to prosody before the sentence is known. Clause-level
/// chunking inside one utterance is what buys the latency instead.
abstract class TtsEngine {
  /// Languages this engine can currently serve, derived from installed packs.
  Set<String> get availableLanguages;

  /// Synthesises one request. The stream completes when the utterance is done.
  ///
  /// A caller that stops listening early (an alert pre-empting a voice note)
  /// must not leave a native session mid-inference; implementations cancel on
  /// stream cancellation.
  Stream<SynthesisChunk> synthesize(SynthesisRequest request);

  /// Loads the voice ahead of first use, so the first message of a session does
  /// not pay the model-load cost. A missing pack is not an error here - the UI
  /// already reports coverage from the pack scan.
  Future<void> warmUp(String languageTag);

  Future<void> dispose();
}
