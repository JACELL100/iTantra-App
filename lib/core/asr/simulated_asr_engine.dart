import 'dart:typed_data';

import '../metrics/metrics.dart';
import 'asr_engine.dart';

/// A recogniser that does not recognise.
///
/// It exists for exactly one reason: the single-phone demonstration. With no
/// model installed, holding the talk button would otherwise produce a banner
/// saying a pack is missing, and every part of the pipeline that *is* built -
/// endpointing, transmission, storage, synthesis, playback, receipts, and all
/// the latency measurement - would be untestable without a second phone and a
/// 150 MB download.
///
/// What it does honestly:
///
///  * waits for the real utterance length, so endpointing, `send_ms` and the
///    queue behave exactly as they do with a real model;
///  * returns a plausible field phrase, because the point is to exercise the
///    rest of the path;
///  * reports [AsrResult.isSimulated], which the UI turns into a permanent
///    "simulated" marker on the screen and on every message it produces.
///
/// What it is not: a model. It never listens. The UI says so in words, on
/// screen, for as long as the source is selected - which is the only way a
/// demonstration can use it and still be telling the truth.
class SimulatedAsrEngine implements AsrEngine {
  SimulatedAsrEngine({required MetricsCollector metrics}) : _metrics = metrics;

  final MetricsCollector _metrics;

  int _turn = 0;

  /// Deliberately about the app rather than about the user's day. A canned
  /// sentence pretending to be someone's speech is the one thing that would
  /// make this dishonest; a sentence about the demonstration makes it obvious
  /// to anyone reading the transcript, even after the banner has scrolled away.
  static const List<String> phrases = <String>[
    'This is a simulated message from the demonstration mode.',
    'No recognition model is installed, so this text was produced locally.',
    'The link, storage, and playback you are watching are real.',
    'Install a model from the Models screen to dictate your own words.',
  ];

  @override
  Set<String> get availableLanguages => const <String>{};

  @override
  Future<void> warmUp(String languageTag) async {}

  @override
  Future<AsrResult> transcribe({
    required Int16List pcm,
    required String languageTag,
  }) async {
    final int audioMs = pcm.length * 1000 ~/ 16000;

    // A quarter of the utterance length, floored, so the demonstration still
    // shows a realistic wait instead of appearing to be instant. Below 400
    // samples there is nothing to transcribe, which mirrors the real engine's
    // behaviour rather than papering over it.
    if (pcm.length < 400) {
      _metrics.increment('asr_too_short');
      return AsrResult(
        text: '',
        confidence: 0,
        languageTag: languageTag,
        audioMs: audioMs,
        computeMs: 0,
        isSimulated: true,
      );
    }

    final int delay = (audioMs ~/ 4).clamp(60, 400);
    await Future<void>.delayed(Duration(milliseconds: delay));

    final String text = phrases[_turn % phrases.length];
    _turn++;

    _metrics.increment('asr_transcripts');
    _metrics.increment('asr_simulated');
    _metrics.record('asr_compute_ms', delay.toDouble());

    return AsrResult(
      text: text,
      confidence: 1,
      languageTag: languageTag,
      audioMs: audioMs,
      computeMs: delay,
      isSimulated: true,
    );
  }

  @override
  Future<void> dispose() async {}
}
