import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../cloud/wav.dart';
import '../metrics/metrics.dart';
import '../util/log.dart';
import 'tts_engine.dart';

/// The voice the phone already has.
///
/// Android and iOS both ship a speech synthesiser, both work with the radio
/// off, and neither requires a download - which makes this the only voice a
/// fresh install has. It is not the app's own model and does not pretend to be:
/// the on-device VITS packs are better, and the settings screen says so. But a
/// phone that cannot speak at all is not a communication aid, and "install a
/// 60 MB voice pack before your first message" is a bad answer to somebody who
/// needs one now.
///
/// Synthesis goes through the platform and comes back as PCM, so it feeds the
/// same playback path, the same priority handling and the same latency
/// measurements as a model-based voice. On Android the platform writes a WAV
/// file which is decoded here; on iOS the buffers arrive directly. Both are
/// handled, because the alternative - a platform-specific code path in Dart -
/// would put an `if (Platform.isAndroid)` in the middle of the audio path.
class SystemTtsEngine implements TtsEngine {
  SystemTtsEngine({
    required MetricsCollector metrics,
    MethodChannel? channel,
    this.sliceMilliseconds = 320,
  })  : _metrics = metrics,
        _channel = channel ?? const MethodChannel('itantra/system_tts');

  final MetricsCollector _metrics;
  final MethodChannel _channel;
  final int sliceMilliseconds;

  /// Whether the platform reported a working synthesiser.
  ///
  /// False is a legitimate state - a ROM with no TTS engine, or every voice
  /// uninstalled - and the UI uses it to stop offering the device voice rather
  /// than failing on the first spoken message.
  bool _available = false;

  bool get isAvailable => _available;

  /// The languages the platform actually has voice data for. Empty until
  /// [probe] has run. Used to explain *which* language is missing instead of
  /// reporting a generic failure.
  Set<String> _installedLanguages = <String>{};

  Set<String> get installedLanguages => _installedLanguages;

  /// Asked at start-up and after the user returns from settings, since voice
  /// data can be installed while the app is in the background.
  ///
  /// [candidates] are the tags the app offers; the platform answers with the
  /// subset it has data for. Passing them in rather than enumerating every
  /// voice on the device keeps the answer in the same BCP-47 form the rest of
  /// the app compares against.
  Future<void> probe({List<String> candidates = const <String>[]}) async {
    try {
      final Object? result = await _channel.invokeMethod<Object?>(
        'probe',
        <String, Object?>{'candidates': candidates},
      );
      if (result is Map) {
        _available = result['available'] == true;
        final Object? languages = result['languages'];
        if (languages is List) {
          _installedLanguages =
              languages.whereType<String>().toSet();
        }
      }
    } on MissingPluginException {
      // The channel is not implemented - a desktop build, or a platform
      // without a synthesiser. Not an error; simply no device voice.
      _available = false;
    } on PlatformException catch (error) {
      ItLog.w('tts', 'device voice probe failed: ${error.message}');
      _available = false;
    }
  }

  @override
  Set<String> get availableLanguages => _installedLanguages;

  @override
  Future<void> warmUp(String languageTag) async {
    if (!_available) return;
    try {
      // Starting the synthesiser is what takes a second or more on a cold
      // start, so it is done when the language is chosen rather than when the
      // first message arrives.
      await _channel.invokeMethod<void>('prepare', <String, Object?>{
        'languageTag': languageTag,
      });
    } on PlatformException catch (error) {
      ItLog.w('tts', 'device voice prepare failed: ${error.message}');
    }
  }

  @override
  Stream<SynthesisChunk> synthesize(SynthesisRequest request) async* {
    if (!_available) {
      throw const TtsException(
        'this phone has no working text-to-speech engine, or its voice data '
        'for this language is not installed. Install a voice pack instead.',
        isMissingModel: true,
      );
    }

    final int startMicros = MetricsCollector.nowMicros();
    _metrics.increment('tts_utterances');

    final Object? raw;
    try {
      raw = await _channel.invokeMethod<Object?>('synthesize', <String, Object?>{
        'text': request.text,
        'languageTag': request.languageTag,
        'rate': request.speakingRate,
      });
    } on PlatformException catch (error) {
      throw TtsException(
        error.message ??
            'the device voice could not speak this text '
                '(${error.code}).',
        isMissingModel: error.code == 'missing-data',
      );
    }

    final WavData? audio = await _decode(raw, request.languageTag);
    if (audio == null || audio.samples.isEmpty) {
      throw const TtsException('the device voice produced no audio');
    }

    _metrics.record('tts_compute_ms',
        (MetricsCollector.nowMicros() - startMicros) / 1000.0);

    final int slice =
        (audio.sampleRateHz * sliceMilliseconds ~/ 1000).clamp(1600, 48000);
    for (int offset = 0; offset < audio.samples.length; offset += slice) {
      final int end = (offset + slice).clamp(0, audio.samples.length);
      yield SynthesisChunk(
        samples: Int16List.sublistView(audio.samples, offset, end),
        sampleRateHz: audio.sampleRateHz,
        isLast: end >= audio.samples.length,
      );
    }
  }

  /// Turns whatever the platform returned into samples.
  ///
  /// Two shapes, and both are deliberate: Android writes a WAV file because
  /// `synthesizeToFile` is the only supported offline API there, while iOS
  /// hands back buffers directly through `AVSpeechSynthesizer.write`.
  Future<WavData?> _decode(Object? raw, String languageTag) async {
    if (raw is! Map) return null;

    final Object? path = raw['path'];
    if (path is String && path.isNotEmpty) {
      final File file = File(path);
      try {
        if (file.existsSync()) return WavCodec.decode(await file.readAsBytes());
      } on FormatException catch (error) {
        ItLog.w('tts', 'device voice wrote unreadable audio: ${error.message}');
      } finally {
        // The engine writes into the app's cache; leaving one WAV per message
        // there would be a slow leak.
        try {
          if (file.existsSync()) file.deleteSync();
        } on FileSystemException {
          // Best effort. A file the platform still holds open is harmless.
        }
      }
      return null;
    }

    final Object? pcm = raw['pcm'];
    final Object? rate = raw['sampleRateHz'];
    if (pcm is Uint8List && rate is int && rate > 0) {
      // The platform hands back little-endian PCM16, the same order the phone
      // speaks natively, so a view is enough on a little-endian device and a
      // byte swap is needed on the other kind. Doing it explicitly costs one
      // pass and removes a class of bug that sounds like static.
      return WavData(
        samples: _pcm16(pcm),
        sampleRateHz: rate,
      );
    }

    ItLog.w('tts', 'device voice returned an unrecognised payload for $languageTag');
    return null;
  }

  static Int16List _pcm16(Uint8List bytes) {
    final int count = bytes.length ~/ 2;
    final Int16List out = Int16List(count);
    final ByteData view = ByteData.sublistView(bytes);
    for (int i = 0; i < count; i++) {
      out[i] = view.getInt16(i * 2, Endian.little);
    }
    return out;
  }

  @override
  Future<void> dispose() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      // Nothing to stop is not a failure.
    }
  }
}
