import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'asr_engine.dart';
import '../util/log.dart';

/// Gemma 4 E2B-it ASR engine using LiteRT-LM via platform channel.
///
/// Accepts 16 kHz mono PCM audio, performs transcription + optional translation.
/// Only loads on 6 GB+ RAM devices (enforced by PlatformInfo probe).
class GemmaAsrEngine implements AsrEngine {
  GemmaAsrEngine({
    required String modelPath,
    this.maxTokens = 512,
    this.temperature = 0.0,
  }) : _modelPath = modelPath;

  final String _modelPath;
  final int maxTokens;
  final double temperature;

  final MethodChannel _channel = const MethodChannel('org.itantra/gemma_asr');
  bool _isLoaded = false;
  String? _loadedLanguage;

  @override
  Set<String> get availableLanguages => <String>{
    'hi-IN', 'gu-IN', 'mr-IN', 'kn-IN', 'ml-IN',
    'ta-IN', 'te-IN', 'or-IN', 'bn-IN', 'en-IN',
  };

  @override
  Future<void> warmUp(String languageTag) async {
    if (_isLoaded && _loadedLanguage == languageTag) return;
    await _loadModel();
    _loadedLanguage = languageTag;
  }

  Future<void> _loadModel() async {
    if (_isLoaded) return;
    try {
      await _channel.invokeMethod('loadModel', {'modelPath': _modelPath});
      _isLoaded = true;
      ItLog.i('gemma_asr', 'Loaded Gemma 4 E2B from $_modelPath');
    } on PlatformException catch (e) {
      ItLog.e('gemma_asr', 'Failed to load Gemma model', e);
      throw AsrException('Gemma model load failed: ${e.message}', isMissingModel: true);
    }
  }

  @override
  Future<AsrResult> transcribe({
    required Int16List pcm,
    required String languageTag,
    String? targetLanguageTag,
  }) async {
    await _loadModel();

    final stopwatch = Stopwatch()..start();

    // Convert PCM to base64 WAV
    final audioBase64 = _pcmToBase64Wav(pcm, 16000);

    String prompt;
    if (targetLanguageTag != null && targetLanguageTag != languageTag) {
      prompt = 'Translate the following speech from $languageTag to $targetLanguageTag. Output JSON: {"text": "...", "translated_text": "..."}';
    } else {
      prompt = 'Transcribe the following speech in $languageTag. Output JSON: {"text": "..."}';
    }

    try {
      final result = await _channel.invokeMethod('transcribe', {
        'audioBase64': audioBase64,
        'prompt': prompt,
        'maxTokens': maxTokens,
        'temperature': temperature,
      });

      stopwatch.stop();
      final computeMs = stopwatch.elapsedMilliseconds;
      final audioMs = (pcm.length / 16).round(); // 16kHz = 16 samples/ms

      return _parseResponse(
        result as String,
        languageTag,
        targetLanguageTag,
        audioMs,
        computeMs,
      );
    } on PlatformException catch (e) {
      ItLog.e('gemma_asr', 'Gemma inference failed', e);
      throw AsrException('Gemma inference failed: ${e.message}');
    }
  }

  String _pcmToBase64Wav(Int16List pcm, int sampleRate) {
    // Minimal WAV header + PCM data, base64 encoded
    final byteData = ByteData(44 + pcm.length * 2);
    // RIFF header
    byteData.setUint8(0, 0x52); // 'R'
    byteData.setUint8(1, 0x49); // 'I'
    byteData.setUint8(2, 0x46); // 'F'
    byteData.setUint8(3, 0x46); // 'F'
    byteData.setUint32(4, 36 + pcm.length * 2, Endian.little); // file size - 8
    byteData.setUint8(8, 0x57); // 'W'
    byteData.setUint8(9, 0x41); // 'A'
    byteData.setUint8(10, 0x56); // 'V'
    byteData.setUint8(11, 0x45); // 'E'
    // fmt chunk
    byteData.setUint8(12, 0x66); // 'f'
    byteData.setUint8(13, 0x6D); // 'm'
    byteData.setUint8(14, 0x74); // 't'
    byteData.setUint8(15, 0x20); // ' '
    byteData.setUint32(16, 16, Endian.little); // fmt chunk size
    byteData.setUint16(20, 1, Endian.little); // PCM format
    byteData.setUint16(22, 1, Endian.little); // mono
    byteData.setUint32(24, sampleRate, Endian.little);
    byteData.setUint32(28, sampleRate * 2, Endian.little); // byte rate
    byteData.setUint16(32, 2, Endian.little); // block align
    byteData.setUint16(34, 16, Endian.little); // bits per sample
    // data chunk
    byteData.setUint8(36, 0x64); // 'd'
    byteData.setUint8(37, 0x61); // 'a'
    byteData.setUint8(38, 0x74); // 't'
    byteData.setUint8(39, 0x61); // 'a'
    byteData.setUint32(40, pcm.length * 2, Endian.little); // data size
    // PCM data
    for (int i = 0; i < pcm.length; i++) {
      byteData.setInt16(44 + i * 2, pcm[i], Endian.little);
    }
    return base64Encode(byteData.buffer.asUint8List());
  }

  AsrResult _parseResponse(
    String response,
    String languageTag,
    String? targetLanguageTag,
    int audioMs,
    int computeMs,
  ) {
    // Expected JSON: {"text": "...", "translated_text": "..."}
    String text = '';
    String? translatedText;

    try {
      // Try to parse JSON from response
      final start = response.indexOf('{');
      final end = response.lastIndexOf('}');
      if (start >= 0 && end > start) {
        final jsonStr = response.substring(start, end + 1);
        final map = jsonDecode(jsonStr) as Map<String, dynamic>;
        text = map['text'] as String? ?? '';
        translatedText = map['translated_text'] as String?;
      } else {
        // Fallback: use entire response as text
        text = response.trim();
      }
    } catch (_) {
      text = response.trim();
    }

    return AsrResult(
      text: text,
      confidence: text.isEmpty ? 0.0 : 0.9, // Gemma doesn't expose confidence
      languageTag: languageTag,
      audioMs: audioMs,
      computeMs: computeMs,
      translatedText: translatedText,
      targetLanguageTag: targetLanguageTag,
    );
  }

  @override
  Future<void> dispose() async {
    try {
      await _channel.invokeMethod('dispose');
    } catch (_) {}
    _isLoaded = false;
    _loadedLanguage = null;
  }
}