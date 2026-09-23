import 'dart:io';
import 'dart:typed_data';

import 'package:onnxruntime/onnxruntime.dart';

import 'asr_engine.dart';
import '../models/model_pack.dart';
import '../models/model_pack_manager.dart';
import '../util/log.dart';

/// ONNX CTC ASR engine (fallback for devices without Gemma support).
///
/// Loads per-language ONNX models from model packs.
class OnnxCtcAsrEngine implements AsrEngine {
  OnnxCtcAsrEngine({
    required ModelPackManager packs,
  }) : _packs = packs;

  final ModelPackManager _packs;

  OrtSession? _session;
  String? _loadedLanguage;

  @override
  Set<String> get availableLanguages => _packs.packs
      .where((p) => p.role == PackRole.asr && !p.id.contains('gemma'))
      .map((p) => p.languageTag)
      .toSet();

  @override
  Future<void> warmUp(String languageTag) async {
    if (_session != null && _loadedLanguage == languageTag) return;
    await _loadModel(languageTag);
    _loadedLanguage = languageTag;
  }

  Future<void> _loadModel(String languageTag) async {
    if (_session != null) {
      _session!.release();
      _session = null;
    }

    final pack = _packs.packFor(languageTag, PackRole.asr);
    if (pack == null) {
      throw AsrException('No ASR pack for $languageTag', isMissingModel: true);
    }

    try {
      final options = OrtSessionOptions();
      _session = OrtSession.fromFile(File(pack.modelPath), options);
      ItLog.i('onnx_ctc_asr', 'Loaded ONNX CTC model for $languageTag');
    } on Exception catch (e) {
      ItLog.e('onnx_ctc_asr', 'Failed to load ONNX model', e);
      throw AsrException('ONNX model load failed: $e', isMissingModel: true);
    }
  }

  @override
  Future<AsrResult> transcribe({
    required Int16List pcm,
    required String languageTag,
    String? targetLanguageTag,
  }) async {
    await warmUp(languageTag);
    final session = _session!;

    final stopwatch = Stopwatch()..start();

    try {
      // Prepare input tensor
      final inputTensor = _prepareInput(pcm);

      final outputs = session.run(OrtRunOptions(), {'input': inputTensor});

      stopwatch.stop();
      final computeMs = stopwatch.elapsedMilliseconds;
      final audioMs = (pcm.length / 16).round();

      // Get output tensor - outputs is List<OrtValue?>
      final outputTensor = outputs.firstWhere((o) => o != null)!;
      final logits = outputTensor.value as List<List<List<double>>>;

      // CTC decode
      final text = _ctcDecode(logits);

      inputTensor.release();
      for (final v in outputs) {
        v?.release();
      }

      return AsrResult(
        text: text,
        confidence: text.isEmpty ? 0.0 : 0.85,
        languageTag: languageTag,
        audioMs: audioMs,
        computeMs: computeMs,
        // ONNX CTC doesn't do translation
        translatedText: null,
        targetLanguageTag: null,
      );
    } on Exception catch (e) {
      ItLog.e('onnx_ctc_asr', 'ONNX inference failed', e);
      throw AsrException('ONNX inference failed: $e');
    }
  }

  OrtValue _prepareInput(Int16List pcm) {
    // Convert PCM to log-mel features
    // This is a simplified version - real implementation would use log_mel.dart
    final floatList = Float32List(pcm.length);
    for (int i = 0; i < pcm.length; i++) {
      floatList[i] = pcm[i] / 32768.0;
    }
    // Reshape to [1, 1, num_samples] for model input
    // TODO: Use correct onnxruntime Dart API for tensor creation
    throw UnimplementedError('ONNX tensor creation needs correct API');
  }

  String _ctcDecode(List<List<List<double>>> logits) {
    // Simple greedy CTC decode
    // logits shape: [batch, time, vocab]
    final timeSteps = logits[0];
    final vocabSize = timeSteps[0].length;

    // Find blank token (usually last or 0)
    const blank = 0;

    final List<int> tokens = [];
    for (final frame in timeSteps) {
      int best = 0;
      double bestScore = frame[0];
      for (int i = 1; i < vocabSize; i++) {
        if (frame[i] > bestScore) {
          bestScore = frame[i];
          best = i;
        }
      }
      if (best != blank) {
        if (tokens.isEmpty || tokens.last != best) {
          tokens.add(best);
        }
      }
    }

    // Convert tokens to text (placeholder - needs actual vocabulary)
    return tokens.map((t) => String.fromCharCode(t + 0x0900)).join(); // Devanagari placeholder
  }

  @override
  Future<void> dispose() async {
    _session?.release();
    _session = null;
    _loadedLanguage = null;
  }
}