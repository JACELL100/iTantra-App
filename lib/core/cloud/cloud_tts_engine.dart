import 'dart:typed_data';

import '../metrics/metrics.dart';
import '../tts/text_frontend.dart';
import '../tts/tts_engine.dart';
import '../util/log.dart';
import 'cloud_client.dart';
import 'cloud_speech_config.dart';
import 'wav.dart';

/// Synthesis through an OpenAI-compatible `/audio/speech` endpoint.
///
/// Requests WAV rather than the providers' default MP3, which matters more than
/// it looks: decoding MP3 means a full codec in the app, and re-encoding it to
/// feed the PCM playback path would add noise and latency for no benefit. WAV
/// in, PCM out, one less moving part.
///
/// Text is clause-split by the same [TextFrontend] the on-device voice uses, so
/// playback can start on the first clause while the rest is still in flight.
/// That is the difference between a one-second and a five-second wait on a
/// three-sentence alert.
class CloudTtsEngine implements TtsEngine {
  CloudTtsEngine({
    required CloudClient client,
    required MetricsCollector metrics,
    this.sliceMilliseconds = 320,
  })  : _client = client,
        _metrics = metrics;

  final CloudClient _client;
  final MetricsCollector _metrics;

  /// Size of each emitted slice. Small enough that playback starts
  /// immediately, large enough not to wake the platform player hundreds of
  /// times a second.
  final int sliceMilliseconds;

  final TextFrontend _frontend = const TextFrontend();

  @override
  Set<String> get availableLanguages => CloudSpeechConfig.languages;

  @override
  Future<void> warmUp(String languageTag) async {
    // Nothing to load locally. The handshake is paid by the first request.
  }

  @override
  Stream<SynthesisChunk> synthesize(SynthesisRequest request) async* {
    final List<TextChunk> clauses =
        _frontend.prepare(request.text, request.languageTag);
    if (clauses.isEmpty) return;

    _metrics.increment('tts_utterances');
    final int startMicros = MetricsCollector.nowMicros();
    int producedMs = 0;

    for (final TextChunk clause in clauses) {
      final Uint8List bytes;
      try {
        bytes = await _client.postJsonForBytes(
          _client.config.speechUri,
          <String, Object?>{
            'model': _client.config.ttsModel,
            'input': clause.text,
            'voice': _client.config.ttsVoice.isEmpty
                ? 'alloy'
                : _client.config.ttsVoice,
            'response_format': 'wav',
            // The endpoint's own range. Clamped rather than passed through: an
            // out-of-range value is a 400 from most providers, and a sliding
            // rate control should never be able to break playback.
            'speed': request.speakingRate.clamp(0.25, 4.0),
          },
        );
      } on CloudSpeechException catch (error) {
        _metrics.increment('tts_cloud_failures');
        throw TtsException(
          error.message,
          isMissingModel: error.isAuthFailure,
        );
      }

      final WavData audio;
      try {
        audio = WavCodec.decode(bytes);
      } on FormatException catch (error) {
        throw TtsException(
          'the voice returned audio this app cannot read (${error.message}). '
          'Ask the provider for WAV output.',
        );
      }

      if (audio.samples.isEmpty) continue;

      final int slice = (audio.sampleRateHz * sliceMilliseconds ~/ 1000)
          .clamp(1600, 48000);
      for (int offset = 0; offset < audio.samples.length; offset += slice) {
        final int end =
            (offset + slice).clamp(0, audio.samples.length);
        final Int16List samples = Int16List.sublistView(
          audio.samples,
          offset,
          end,
        );
        producedMs += samples.length * 1000 ~/ audio.sampleRateHz;
        yield SynthesisChunk(
          samples: samples,
          sampleRateHz: audio.sampleRateHz,
          isLast: clause.isLast && end >= audio.samples.length,
          chunkIndex: clause.index,
        );
      }
    }

    final int computeMs = (MetricsCollector.nowMicros() - startMicros) ~/ 1000;
    _metrics.record('tts_compute_ms', computeMs.toDouble());
    if (producedMs > 0) {
      _metrics.record('tts_rtf', computeMs / producedMs);
    }
    ItLog.i('tts', 'cloud voice produced ${producedMs}ms in ${computeMs}ms');
  }

  @override
  Future<void> dispose() async {}
}
