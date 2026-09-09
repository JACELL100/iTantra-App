import 'dart:math' as math;
import 'dart:typed_data';

/// The single audio format used everywhere in the app.
///
/// 16 kHz mono, because that is what the acoustic models were trained on;
/// resampling once at the edge is cheaper and safer than letting several
/// rates leak into the pipeline. 20 ms frames because that is short enough
/// for responsive endpointing and long enough that per-frame overhead is
/// irrelevant.
class AudioFormatSpec {
  const AudioFormatSpec._();

  static const int sampleRateHz = 16000;
  static const int frameDurationMs = 20;
  static const int samplesPerFrame = sampleRateHz * frameDurationMs ~/ 1000;
  static const int bytesPerFrame = samplesPerFrame * 2;
  static const int channels = 1;
}

/// One 20 ms block of microphone audio.
class AudioFrame {
  AudioFrame({
    required this.samples,
    required this.monotonicMicros,
    required this.sequence,
  });

  final Int16List samples;

  /// Capture timestamp from the platform's monotonic clock. Wall-clock time
  /// is useless for latency measurement because it can jump; this is what
  /// stage A0 is anchored to.
  final int monotonicMicros;

  final int sequence;

  int get durationMs => samples.length * 1000 ~/ AudioFormatSpec.sampleRateHz;

  /// Mean square, kept as a raw number so the VAD can compare frames without
  /// paying for a logarithm on every one.
  double get meanSquare {
    if (samples.isEmpty) return 0;
    double sum = 0;
    for (final int sample in samples) {
      final double normalised = sample / 32768.0;
      sum += normalised * normalised;
    }
    return sum / samples.length;
  }

  /// Level in dBFS, floored at -90 so digital silence does not produce
  /// negative infinity and break the level meter.
  double get rmsDbfs {
    final double ms = meanSquare;
    if (ms <= 1e-12) return -90;
    return 10 * (math.log(ms) / math.ln10);
  }

  int get peak {
    int maximum = 0;
    for (final int sample in samples) {
      final int magnitude = sample.abs();
      if (magnitude > maximum) maximum = magnitude;
    }
    return maximum;
  }

  /// Flagged in diagnostics: a clipping input is the most common cause of a
  /// sudden jump in word error rate, and it is a gain problem, not a model
  /// problem.
  bool get isClipping => peak >= 32000;
}
