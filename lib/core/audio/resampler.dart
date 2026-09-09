import 'dart:typed_data';

/// Linear resampler with an anti-alias pre-filter.
///
/// The microphone is opened at 16 kHz wherever the device allows it, so this
/// is usually a no-op. Some low-end handsets only offer 44.1 or 48 kHz, and
/// on those the audio must be converted before it reaches the feature
/// extractor - a model fed 48 kHz audio labelled as 16 kHz produces confident
/// nonsense.
///
/// Linear interpolation rather than a polyphase filter: the one-pole low pass
/// below removes the energy that would alias, and the residual error is far
/// below what the acoustic model can distinguish. A proper sinc resampler
/// would cost more CPU for no measurable word-error-rate gain, and idle CPU is
/// a scored metric.
class Resampler {
  Resampler({required this.inputRateHz, this.outputRateHz = 16000})
      : _ratio = inputRateHz / 16000 {
    _lowPassCoefficient = _coefficientFor(inputRateHz);
  }

  final int inputRateHz;
  final int outputRateHz;
  final double _ratio;

  double _lowPassCoefficient = 0;
  double _filterState = 0;
  double _position = 0;
  int _lastSample = 0;

  bool get isPassThrough => inputRateHz == outputRateHz;

  /// One-pole low pass at roughly 7 kHz, below the 8 kHz Nyquist limit of the
  /// output rate.
  static double _coefficientFor(int rateHz) {
    const double cutoffHz = 7000;
    final double rc = 1.0 / (2 * 3.141592653589793 * cutoffHz);
    final double dt = 1.0 / rateHz;
    return dt / (rc + dt);
  }

  Int16List process(Int16List input) {
    if (isPassThrough) return input;
    if (input.isEmpty) return input;

    // Filter in place on a copy, then sample.
    final Float64List filtered = Float64List(input.length);
    double state = _filterState;
    for (int i = 0; i < input.length; i++) {
      state += _lowPassCoefficient * (input[i] - state);
      filtered[i] = state;
    }
    _filterState = state;

    final int outputCount = ((input.length - _position) / _ratio).floor();
    final Int16List output = Int16List(outputCount < 0 ? 0 : outputCount);

    double position = _position;
    for (int i = 0; i < output.length; i++) {
      final int index = position.floor();
      final double fraction = position - index;

      final double a = index <= 0
          ? _lastSample.toDouble()
          : filtered[index - 1 < 0 ? 0 : index];
      final double b =
          index + 1 < filtered.length ? filtered[index + 1] : a;

      final double value = a + (b - a) * fraction;
      output[i] = value > 32767
          ? 32767
          : value < -32768
              ? -32768
              : value.round();
      position += _ratio;
    }

    // Carry the fractional position across calls so frame boundaries do not
    // introduce a click every 20 ms.
    _position = position - input.length;
    if (_position < 0) _position = 0;
    _lastSample = input[input.length - 1];

    return output;
  }

  void reset() {
    _filterState = 0;
    _position = 0;
    _lastSample = 0;
  }

  /// Averages a stereo stream to mono. Some devices hand back two channels
  /// even when one is requested.
  static Int16List downmixStereo(Int16List interleaved) {
    final Int16List mono = Int16List(interleaved.length ~/ 2);
    for (int i = 0; i < mono.length; i++) {
      mono[i] = ((interleaved[i * 2] + interleaved[i * 2 + 1]) ~/ 2);
    }
    return mono;
  }

  /// Little-endian 16-bit bytes to samples, matching what AudioRecord hands
  /// across the platform channel.
  static Int16List bytesToSamples(Uint8List bytes) {
    final ByteData view = ByteData.sublistView(bytes);
    final Int16List samples = Int16List(bytes.length ~/ 2);
    for (int i = 0; i < samples.length; i++) {
      samples[i] = view.getInt16(i * 2, Endian.little);
    }
    return samples;
  }

  static Uint8List samplesToBytes(Int16List samples) {
    final ByteData view = ByteData(samples.length * 2);
    for (int i = 0; i < samples.length; i++) {
      view.setInt16(i * 2, samples[i], Endian.little);
    }
    return view.buffer.asUint8List();
  }
}
