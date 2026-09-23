import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:onnxruntime/onnxruntime.dart';

import '../metrics/metrics.dart';
import '../models/model_pack.dart';
import '../models/model_pack_manager.dart';
import '../util/log.dart';
import 'phonemizer.dart';
import 'text_frontend.dart';
import 'tts_engine.dart';

class _LoadedVoice {
  _LoadedVoice(this.session, this.phonemizer, this.sampleRateHz);

  final OrtSession session;
  final Phonemizer phonemizer;
  final int sampleRateHz;

  void release() => session.release();
}

/// VITS-style synthesis on ONNX Runtime.
///
/// Model contract, fixed by ml/export/export_tts_onnx.py:
///   inputs   input int64 [1, tokens], input_lengths int64 [1],
///            scales float32 [3] = noise, length, noise_w
///   output   audio float32 [1, 1, samples]
///
/// A single-stage model (text straight to waveform) rather than an acoustic
/// model plus separate vocoder: half the graphs to load, half the memory, and
/// no intermediate mel tensor to marshal across FFI. On a low-end phone that
/// is the difference between a real-time factor around 0.4 and one above 1.0.
class OnnxVitsTtsEngine implements TtsEngine {
  OnnxVitsTtsEngine({
    required ModelPackManager packs,
    required MetricsCollector metrics,
    this.maxCachedSessions = 2,
  })  : _packs = packs,
        _metrics = metrics;

  final ModelPackManager _packs;
  final MetricsCollector _metrics;
  final int maxCachedSessions;

  final TextFrontend _frontend = const TextFrontend();
  final LinkedHashMap<String, _LoadedVoice> _voices =
      LinkedHashMap<String, _LoadedVoice>();

  bool _runtimeReady = false;

  /// Inference scales. These are the reference VITS values; lowering noise
  /// makes speech flatter but more predictable, which is what an alert wants
  /// more than expressiveness.
  static const double noiseScale = 0.667;
  static const double noiseScaleW = 0.8;
  static const int modelSampleRateHz = 22050;

  @override
  Set<String> get availableLanguages => _packs.packs
      .where((ModelPack pack) => pack.role == PackRole.tts)
      .map((ModelPack pack) => pack.languageTag)
      .toSet();

  @override
  Future<void> warmUp(String languageTag) async {
    await _voiceFor(languageTag);
  }

  Future<_LoadedVoice> _voiceFor(String languageTag) async {
    final _LoadedVoice? cached = _voices.remove(languageTag);
    if (cached != null) {
      _voices[languageTag] = cached;
      return cached;
    }

    final ModelPack? pack = _packs.packFor(languageTag, PackRole.tts);
    if (pack == null) {
      throw TtsException(
        'no voice pack installed for $languageTag',
        isMissingModel: true,
      );
    }

    if (!_runtimeReady) {
      OrtEnv.instance.init();
      _runtimeReady = true;
    }

    final OrtSessionOptions options = OrtSessionOptions()
      ..setIntraOpNumThreads(2)
      ..setInterOpNumThreads(1)
      ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);

    final _LoadedVoice voice = _LoadedVoice(
      OrtSession.fromFile(File(pack.modelPath), options),
      Phonemizer.load(
        graphemesPath: pack.assetPath('graphemes.tsv'),
        lexiconPath: pack.assetPath('lexicon.tsv'),
      ),
      pack.sampleRateHz ?? modelSampleRateHz,
    );

    _voices[languageTag] = voice;
    _metrics.increment('tts_sessions_created');

    while (_voices.length > maxCachedSessions) {
      final String oldest = _voices.keys.first;
      _voices.remove(oldest)?.release();
      _metrics.increment('tts_sessions_evicted');
      ItLog.i('tts', 'evicted voice for $oldest');
    }

    return voice;
  }

  @override
  Stream<SynthesisChunk> synthesize(SynthesisRequest request) async* {
    final _LoadedVoice voice = await _voiceFor(request.languageTag);
    final List<TextChunk> chunks =
        _frontend.prepare(request.text, request.languageTag);

    if (chunks.isEmpty) return;

    _metrics.increment('tts_utterances');
    final int startMicros = MetricsCollector.nowMicros();
    int producedMs = 0;

    for (final TextChunk chunk in chunks) {
      final List<int> tokens = voice.phonemizer.encode(chunk.text);
      if (tokens.length <= 2) continue;

      final OrtValueTensor input = OrtValueTensor.createTensorWithDataList(
        Int64List.fromList(tokens),
        <int>[1, tokens.length],
      );
      final OrtValueTensor lengths = OrtValueTensor.createTensorWithDataList(
        Int64List.fromList(<int>[tokens.length]),
        <int>[1],
      );
      // Length scale is the inverse of speaking rate: a rate of 0.92 makes
      // speech slightly slower, which is easier to follow over a small
      // speaker in a noisy place.
      final OrtValueTensor scales = OrtValueTensor.createTensorWithDataList(
        Float32List.fromList(<double>[
          noiseScale,
          1.0 / request.speed,
          noiseScaleW,
        ]),
        <int>[3],
      );

      List<OrtValue?>? outputs;
      try {
        outputs = await voice.session.runAsync(
          OrtRunOptions(),
          <String, OrtValue>{
            'input': input,
            'input_lengths': lengths,
            'scales': scales,
          },
        );

        final Float64List audio = _flatten(outputs?.first?.value);
        if (audio.isEmpty) continue;

        final Float32List pcm = Float32List.fromList(
          audio.map((d) => d.clamp(-1.0, 1.0)).toList(),
        );
        producedMs += pcm.length * 1000 ~/ voice.sampleRateHz;

        yield SynthesisChunk(
          samples: pcm,
          sampleRateHz: voice.sampleRateHz,
          isLast: chunk == chunks.last,
        );
      } finally {
        input.release();
        lengths.release();
        scales.release();
        if (outputs != null) {
          for (final OrtValue? value in outputs) {
            value?.release();
          }
        }
      }
    }

    final int computeMs = (MetricsCollector.nowMicros() - startMicros) ~/ 1000;
    _metrics.record('tts_compute_ms', computeMs.toDouble());
    if (producedMs > 0) {
      _metrics.record('tts_rtf', computeMs / producedMs);
    }
  }

  /// Flattens the [1, 1, samples] output into a flat list of doubles.
  ///
  /// Written as an explicit recursive walk because the runtime returns nested
  /// List<dynamic>, and a chained cast expression here fails at runtime with
  /// an error that says nothing useful about which dimension was wrong.
  static Float64List _flatten(Object? raw) {
    final List<double> collected = <double>[];

    void walk(Object? node) {
      if (node is num) {
        collected.add(node.toDouble());
      } else if (node is List) {
        for (final Object? child in node) {
          walk(child);
        }
      }
    }

    walk(raw);
    return Float64List.fromList(collected);
  }

  @override
  Future<void> dispose() async {
    for (final _LoadedVoice voice in _voices.values) {
      voice.release();
    }
    _voices.clear();
    if (_runtimeReady) {
      OrtEnv.instance.release();
      _runtimeReady = false;
    }
  }
}
