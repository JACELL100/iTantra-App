import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:onnxruntime/onnxruntime.dart';

import '../metrics/metrics.dart';
import '../models/model_pack.dart';
import '../models/model_pack_manager.dart';
import '../models/onnx_runtime_host.dart';
import '../util/log.dart';
import 'asr_engine.dart';
import 'ctc_decoder.dart';
import 'log_mel.dart';

/// A loaded recogniser: the graph, its vocabulary and its decoder.
class _LoadedRecogniser {
  _LoadedRecogniser({
    required this.session,
    required this.tokens,
    required this.decoder,
    required this.runOptions,
    required this.inputName,
    required this.lengthName,
    required this.outputName,
  });

  final OrtSession session;
  final TokenTable tokens;
  final CtcDecoder decoder;
  final OrtRunOptions runOptions;

  /// Tensor names read from the pack manifest, resolved by the installer when
  /// the graph was opened. Null [lengthName] means the graph takes a single
  /// input; null [outputName] means "the first output the graph returns".
  final String inputName;
  final String? lengthName;
  final String? outputName;

  void release() {
    runOptions.release();
    session.release();
  }
}

/// Speech to text on ONNX Runtime, greedy CTC.
///
/// ## Model contract
///
/// Fixed by `ml/export/export_asr_onnx.py`, and the only place it can be
/// broken is the export:
///
/// ```
/// inputs :  audio_signal  float32 [1, 80, frames]
///           length        int64   [1]
/// output :  logprobs      float32 [1, frames, vocab]
/// ```
///
/// plus `tokens.txt`, one token per line, blank at index 0.
///
/// ## Why this shape
///
/// * **Utterance at a time, not streaming.** The endpointer already decides
///   where an utterance ends. One forward pass over a closed 2-4 s segment is
///   both more accurate and much cheaper on a low-end CPU than re-running a
///   streaming decoder every 200 ms - and idle CPU is explicitly scored.
/// * **Greedy, not beam search.** A beam of 8 with no external language model
///   buys a fraction of a percent of word error rate on short utterances while
///   costing several times the decode. Latency is 20% of the score.
/// * **Threads capped, not maximised.** Big cores are shared with the audio
///   path and the UI. Four threads on a Cortex-A53 phone makes the first
///   message slower, not faster, because the microphone callback and the
///   compositor are competing for the same cores. See [intraOpThreads].
/// * **Sessions are cached per language.** Loading a 150 MB graph takes
///   seconds; a language switch must not pay that on every utterance, and
///   neither must a bidirectional session where both languages are live.
class OnnxCtcAsrEngine implements AsrEngine {
  OnnxCtcAsrEngine({
    required ModelPackManager packs,
    required MetricsCollector metrics,
    this.maxCachedSessions = 2,
    this.intraOpThreads = 2,
  })  : _packs = packs,
        _metrics = metrics;

  final ModelPackManager _packs;
  final MetricsCollector _metrics;

  /// One recogniser per active language, least-recently-used evicted.
  ///
  /// Two rather than one: a bilingual operator who alternates between Hindi and
  /// English should not reload a 150 MB graph on every sentence. Not more than
  /// two, because each holds a full activation arena and combined PSS is a
  /// scored budget.
  final int maxCachedSessions;

  /// Intra-op threads. Two is the deliberate default - see the class comment.
  final int intraOpThreads;

  final LogMelExtractor _frontend = LogMelExtractor();
  final LinkedHashMap<String, _LoadedRecogniser> _recognisers =
      LinkedHashMap<String, _LoadedRecogniser>();

  /// Serialises inference. Two concurrent forward passes on a low-end CPU are
  /// slower than two sequential ones and can exhaust memory, so utterances
  /// queue rather than race.
  Future<void> _gate = Future<void>.value();

  bool _closed = false;

  @override
  Set<String> get availableLanguages => _packs.packs
      .where((ModelPack pack) => pack.role == PackRole.asr)
      .map((ModelPack pack) => pack.languageTag)
      .toSet();

  /// True when a recogniser for [languageTag] is already resident, so the UI can
  /// distinguish "first word will be slow" from "warm".
  bool isWarm(String languageTag) => _recognisers.containsKey(languageTag);

  @override
  Future<void> warmUp(String languageTag) async {
    if (_closed) return;
    await _recogniserFor(languageTag);
  }

  Future<_LoadedRecogniser> _recogniserFor(String languageTag) async {
    final _LoadedRecogniser? cached = _recognisers.remove(languageTag);
    if (cached != null) {
      _recognisers[languageTag] = cached;
      return cached;
    }

    final ModelPack? pack = _packs.packFor(languageTag, PackRole.asr);
    if (pack == null) {
      throw AsrException(
        'no recognition pack installed for $languageTag',
        isMissingModel: true,
      );
    }

    final File model = File(pack.modelPath);
    if (!model.existsSync()) {
      throw AsrException(
        'recognition pack for $languageTag is incomplete: model.onnx missing',
        isMissingModel: true,
      );
    }

    OnnxRuntimeHost.acquire();
    _metrics.increment('asr_sessions_created');

    final OrtSessionOptions options = OrtSessionOptions()
      ..setIntraOpNumThreads(intraOpThreads)
      ..setInterOpNumThreads(1)
      ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);

    OrtSession? session;
    try {
      session = OrtSession.fromFile(model, options);
    } on Object catch (error) {
      // A graph that will not load is almost always a corrupt pack or an
      // exporter/opset mismatch. Both are install problems, so they are
      // reported as such rather than as a recognition failure.
      OnnxRuntimeHost.release();
      throw AsrException(
        'could not load the $languageTag recognition model: $error',
        isMissingModel: true,
      );
    } finally {
      options.release();
    }

    final TokenTable tokens;
    try {
      tokens = TokenTable.fromFile(pack.assetPath('tokens.txt'));
    } on Object catch (error) {
      session.release();
      OnnxRuntimeHost.release();
      throw AsrException(
        'the $languageTag pack has no usable tokens.txt: $error',
        isMissingModel: true,
      );
    }

    final TensorNames names = pack.tensorNames;
    final _LoadedRecogniser loaded = _LoadedRecogniser(
      session: session,
      tokens: tokens,
      decoder: CtcDecoder(tokens),
      runOptions: OrtRunOptions(),
      inputName: names.input,
      lengthName: names.length,
      outputName: names.output,
    );

    _metrics.record('asr_vocab_size', tokens.size.toDouble());
    ItLog.i('asr',
        'loaded $languageTag (${tokens.size} tokens, ${pack.describeSize()})');

    _recognisers[languageTag] = loaded;
    _evictIfNeeded();
    return loaded;
  }

  void _evictIfNeeded() {
    while (_recognisers.length > maxCachedSessions) {
      final String oldest = _recognisers.keys.first;
      _recognisers.remove(oldest)?.release();
      OnnxRuntimeHost.release();
      _metrics.increment('asr_sessions_evicted');
      ItLog.i('asr', 'evicted $oldest to stay inside the memory budget');
    }
  }

  @override
  Future<AsrResult> transcribe({
    required Int16List pcm,
    required String languageTag,
  }) {
    final Completer<AsrResult> completer = Completer<AsrResult>();
    // Chained rather than awaited so callers never race: each task starts only
    // after the previous one has finished, and a failure in one does not stop
    // the chain.
    _gate = _gate.then((_) async {
      try {
        completer.complete(await _transcribeNow(pcm, languageTag));
      } on AsrException catch (error, stack) {
        completer.completeError(error, stack);
      } on Object catch (error, stack) {
        ItLog.e('asr', 'inference failed', error, stack);
        completer.completeError(
          AsrException('recognition failed: $error'),
          stack,
        );
      }
    });
    return completer.future;
  }

  Future<AsrResult> _transcribeNow(Int16List pcm, String languageTag) async {
    if (_closed) {
      throw const AsrException('recognition engine is shut down');
    }

    final int audioMs = pcm.length * 1000 ~/ 16000;

    // 25 ms is the shortest input the frontend can window at all. Anything
    // shorter is a mis-triggered endpoint, not speech, and running the model on
    // it would produce a hallucination for no reason.
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

    final _LoadedRecogniser recogniser = await _recogniserFor(languageTag);

    final int startMicros = MetricsCollector.nowMicros();

    final int melBands = _frontend.melBands;
    final Float32List features = _frontend.extract(pcm);
    if (features.isEmpty) {
      return AsrResult(
        text: '',
        confidence: 0,
        languageTag: languageTag,
        audioMs: audioMs,
        computeMs: 0,
      );
    }

    final int frames = features.length ~/ melBands;
    if (frames <= 0) {
      return AsrResult(
        text: '',
        confidence: 0,
        languageTag: languageTag,
        audioMs: audioMs,
        computeMs: 0,
      );
    }

    final OrtValueTensor signal = OrtValueTensor.createTensorWithDataList(
      features,
      <int>[1, melBands, frames],
    );
    final OrtValueTensor length = OrtValueTensor.createTensorWithDataList(
      Int64List.fromList(<int>[frames]),
      <int>[1],
    );

    List<OrtValue?>? outputs;
    String text = '';
    double confidence = 0;
    try {
      final Map<String, OrtValue> inputs = <String, OrtValue>{
        recogniser.inputName: signal,
        if (recogniser.lengthName case final String name) name: length,
      };
      final Future<List<OrtValue?>>? pending = recogniser.session.runAsync(
        recogniser.runOptions,
        inputs,
        recogniser.outputName == null
            ? null
            : <String>[recogniser.outputName!],
      );
      if (pending == null) {
        throw const AsrException('the model session is not usable');
      }
      outputs = await pending;

      if (outputs.isEmpty || outputs.first == null) {
        throw const AsrException('the model produced no output');
      }

      final List<List<double>> logProbs = _asFrameVocabulary(outputs.first);
      if (logProbs.isEmpty) {
        throw const AsrException('the model output had no frames');
      }

      final CtcDecoding decoded = recogniser.decoder.decode(logProbs);
      text = decoded.text;
      confidence = decoded.confidence;
    } finally {
      signal.release();
      length.release();
      if (outputs != null) {
        for (final OrtValue? value in outputs) {
          value?.release();
        }
      }
    }

    final int computeMs = (MetricsCollector.nowMicros() - startMicros) ~/ 1000;
    _metrics.record('asr_compute_ms', computeMs.toDouble());
    if (audioMs > 0) {
      final double rtf = computeMs / audioMs;
      _metrics.record('asr_rtf', rtf);
    }
    if (text.isEmpty) {
      // Counted separately, and deliberately not sent anywhere: an empty
      // message on the far end is noise, not information. A high rate here
      // means the frontend or the endpointing is wrong, not the decoder.
      _metrics.increment('asr_empty_transcripts');
    } else {
      _metrics.increment('asr_transcripts');
    }

    return AsrResult(
      text: text,
      confidence: confidence,
      languageTag: languageTag,
      audioMs: audioMs,
      computeMs: computeMs,
    );
  }

  /// Unwraps the `[1, frames, vocab]` output into frames x vocabulary.
  ///
  /// Written as an explicit walk rather than a cast chain: the runtime returns
  /// nested `List<dynamic>`, and a chained cast fails at runtime with a message
  /// that says nothing about which dimension was wrong. A model that returns
  /// a different rank is far more likely to be a bad export than a bug here, so
  /// the error names the shape it actually saw.
  static List<List<double>> _asFrameVocabulary(OrtValue? output) {
    final Object? raw = output?.value;
    if (raw is! List) {
      throw AsrException('expected a tensor, got ${raw.runtimeType}');
    }

    // Drop leading batch dimensions of size 1.
    Object? node = raw;
    while (node is List && node.length == 1 && node.first is List) {
      node = node.first;
    }

    if (node is! List) {
      throw const AsrException('model output has an unexpected rank');
    }

    final List<List<double>> frames = <List<double>>[];
    for (final Object? frame in node) {
      if (frame is! List) {
        throw AsrException(
            'model output frame is ${frame.runtimeType}, expected a list');
      }
      final List<double> row = List<double>.filled(frame.length, 0);
      for (int i = 0; i < frame.length; i++) {
        final Object? value = frame[i];
        row[i] = value is num ? value.toDouble() : 0;
      }
      frames.add(row);
    }
    return frames;
  }

  @override
  Future<void> dispose() async {
    _closed = true;
    // Let any in-flight inference finish before the sessions go away, or the
    // native call reads freed memory.
    await _gate;
    for (final _LoadedRecogniser recogniser in _recognisers.values) {
      recogniser.release();
      OnnxRuntimeHost.release();
    }
    _recognisers.clear();
  }
}
