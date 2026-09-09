import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../util/log.dart';
import 'audio_frame.dart';
import 'resampler.dart';

/// Microphone capture.
///
/// The actual AudioRecord loop lives in Kotlin behind a platform channel.
/// Dart receives already-framed 20 ms buffers with a monotonic capture
/// timestamp attached on the native side, which is the only place that
/// timestamp can be taken accurately: measuring it after it crosses the
/// channel would fold Dart scheduling jitter into the latency numbers this
/// project is graded on.
class CaptureEngine {
  CaptureEngine({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _methods = methodChannel ??
            const MethodChannel('org.itantra/audio_capture'),
        _events = eventChannel ??
            const EventChannel('org.itantra/audio_capture/frames');

  final MethodChannel _methods;
  final EventChannel _events;

  StreamSubscription<dynamic>? _subscription;
  StreamController<AudioFrame>? _controller;
  Resampler? _resampler;
  int _sequence = 0;
  bool _muted = false;

  bool get isRunning => _controller != null;

  /// While muted, frames are dropped in Dart but the native recorder keeps
  /// running. Restarting AudioRecord costs 100-300 ms on low-end devices,
  /// which would be paid on every single playback.
  void setMuted(bool muted) {
    _muted = muted;
  }

  Future<Stream<AudioFrame>> start() async {
    final StreamController<AudioFrame>? existing = _controller;
    if (existing != null) return existing.stream;

    final Map<Object?, Object?>? result =
        await _methods.invokeMapMethod<Object?, Object?>('start');
    final int deviceRate = (result?['sampleRateHz'] as int?) ??
        AudioFormatSpec.sampleRateHz;
    final int deviceChannels = (result?['channels'] as int?) ?? 1;

    _resampler = deviceRate == AudioFormatSpec.sampleRateHz
        ? null
        : Resampler(inputRateHz: deviceRate);
    if (_resampler != null) {
      ItLog.w('capture',
          'device opened at $deviceRate Hz; resampling to 16 kHz');
    }

    final StreamController<AudioFrame> controller =
        StreamController<AudioFrame>.broadcast(onCancel: stop);
    _controller = controller;
    _sequence = 0;

    _subscription = _events.receiveBroadcastStream().listen(
      (dynamic event) {
        if (_muted) return;
        final Map<Object?, Object?> map = event as Map<Object?, Object?>;
        final Uint8List bytes = map['pcm'] as Uint8List;
        final int micros = map['monotonicMicros'] as int;

        Int16List samples = Resampler.bytesToSamples(bytes);
        if (deviceChannels == 2) {
          samples = Resampler.downmixStereo(samples);
        }
        final Resampler? resampler = _resampler;
        if (resampler != null) samples = resampler.process(samples);
        if (samples.isEmpty) return;

        controller.add(AudioFrame(
          samples: samples,
          monotonicMicros: micros,
          sequence: _sequence++,
        ));
      },
      onError: (Object error, StackTrace stack) {
        ItLog.e('capture', 'frame stream error', error, stack);
        controller.addError(error, stack);
      },
    );

    return controller.stream;
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _methods.invokeMethod<void>('stop');
    } on PlatformException catch (e) {
      ItLog.w('capture', 'stop failed: ${e.message}');
    }
    await _controller?.close();
    _controller = null;
    _resampler?.reset();
  }
}
