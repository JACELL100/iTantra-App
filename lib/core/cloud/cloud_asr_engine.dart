import 'dart:typed_data';

import '../asr/asr_engine.dart';
import '../metrics/metrics.dart';
import '../util/log.dart';
import 'cloud_client.dart';
import 'cloud_speech_config.dart';
import 'wav.dart';

/// Recognition through an OpenAI-compatible `/audio/transcriptions` endpoint.
///
/// This is the accuracy path, not the default one. It exists because the brief
/// is a multilingual aid and the honest ranking of speech models on Indic
/// languages puts a hosted Whisper-class model clearly above anything that fits
/// in a phone's memory - so an operator who has a network and a key should be
/// able to use one, and an operator who does not still gets the on-device path.
///
/// The trade is stated on screen wherever it is selected: speech leaves the
/// device, it needs a connection, it costs whatever the provider charges, and
/// nothing about the app's offline guarantee applies to it. Nothing is sent
/// until a person holds the talk button with this engine selected.
class CloudAsrEngine implements AsrEngine {
  CloudAsrEngine({
    required CloudClient client,
    required MetricsCollector metrics,
    this.timeoutHint,
  })  : _client = client,
        _metrics = metrics;

  final CloudClient _client;
  final MetricsCollector _metrics;
  final String? timeoutHint;

  @override
  Set<String> get availableLanguages => CloudSpeechConfig.languages;

  @override
  Future<void> warmUp(String languageTag) async {
    // Nothing to load. The first request pays the TLS handshake instead, which
    // is why the caller's own timeout is generous.
  }

  @override
  Future<AsrResult> transcribe({
    required Int16List pcm,
    required String languageTag,
  }) async {
    final int audioMs = pcm.length * 1000 ~/ 16000;

    if (pcm.length < 400) {
      _metrics.increment('asr_too_short');
      return AsrResult(
        text: '',
        confidence: 0,
        languageTag: languageTag,
        audioMs: audioMs,
        computeMs: 0,
      );
    }

    final int startMicros = MetricsCollector.nowMicros();

    final Map<String, Object?> response;
    try {
      response = await _client.postAudio(
        _client.config.transcriptionsUri,
        audio: WavCodec.encode(pcm, 16000),
        filename: 'utterance.wav',
        fields: <String, String>{
          'model': _client.config.asrModel,
          'language': CloudSpeechConfig.languageCode(languageTag),
          'response_format': 'json',
        },
      );
    } on CloudSpeechException catch (error) {
      _metrics.increment('asr_cloud_failures');
      throw AsrException(
        error.message,
        // A bad key is a setup problem and the UI should offer the Models
        // screen, not a retry button that can never work.
        isMissingModel: error.isAuthFailure,
      );
    }

    final int computeMs = (MetricsCollector.nowMicros() - startMicros) ~/ 1000;
    _metrics.record('asr_compute_ms', computeMs.toDouble());
    _metrics.record('asr_cloud_ms', computeMs.toDouble());

    final Object? text = response['text'];
    if (text is! String) {
      throw const AsrException(
        'the transcription response had no text field',
      );
    }

    final String transcript = text.trim();
    if (transcript.isEmpty) {
      _metrics.increment('asr_empty_transcripts');
    } else {
      _metrics.increment('asr_transcripts');
      _metrics.increment('asr_transcripts_cloud');
    }

    ItLog.i('asr', 'cloud transcript in ${computeMs}ms (${transcript.length} chars)');

    return AsrResult(
      text: transcript,
      // The endpoint reports no confidence. Reporting 1.0 would be a claim the
      // app cannot support, and reporting 0 would make every cloud message look
      // uncertain, so the field is left at 0 and the UI's low-confidence
      // advisory is suppressed for cloud results - see [reportsConfidence].
      confidence: 0,
      languageTag: languageTag,
      audioMs: audioMs,
      computeMs: computeMs,
      reportsConfidence: false,
    );
  }

  @override
  Future<void> dispose() async {}
}
