import 'dart:math' as math;
import 'dart:typed_data';

/// Log-mel filterbank features.
///
/// Every constant here is part of a contract with the exported model: the
/// Python exporter under ml/export computes features with exactly these
/// values, and ml/export/verify_frontend.py asserts that this Dart
/// implementation matches it to 1e-3. Feature mismatch is the single most
/// common cause of an on-device model that "works in the notebook" and
/// produces gibberish on a phone, so the frontend is duplicated and then
/// verified, never assumed.
class LogMelExtractor {
  LogMelExtractor({
    this.sampleRateHz = 16000,
    this.frameLength = 400,
    this.frameShift = 160,
    this.fftSize = 512,
    this.melBands = 80,
    this.lowerEdgeHz = 20,
    this.upperEdgeHz = 7600,
    this.preEmphasis = 0.97,
  })  : _window = _hannPeriodic(frameLength),
        _filterbank = _melFilterbank(
          sampleRateHz: sampleRateHz,
          fftSize: fftSize,
          melBands: melBands,
          lowerEdgeHz: lowerEdgeHz,
          upperEdgeHz: upperEdgeHz,
        );

  final int sampleRateHz;
  final int frameLength;
  final int frameShift;
  final int fftSize;
  final int melBands;
  final double lowerEdgeHz;
  final double upperEdgeHz;
  final double preEmphasis;

  static const double _logEpsilon = 1e-10;

  final Float64List _window;
  final List<Float64List> _filterbank;

  /// Returns [melBands] x frames, laid out band-major to match the model's
  /// expected [1, 80, frames] input without a transpose at inference time.
  Float32List extract(Int16List pcm) {
    if (pcm.length < frameLength) {
      return Float32List(0);
    }

    // Pre-emphasis lifts the high frequencies that carry consonant identity;
    // Indic retroflex and dental contrasts live up there.
    final Float64List emphasised = Float64List(pcm.length);
    emphasised[0] = pcm[0] / 32768.0;
    for (int i = 1; i < pcm.length; i++) {
      emphasised[i] =
          (pcm[i] - preEmphasis * pcm[i - 1]) / 32768.0;
    }

    final int frames = 1 + (pcm.length - frameLength) ~/ frameShift;
    final Float32List output = Float32List(melBands * frames);

    final Float64List real = Float64List(fftSize);
    final Float64List imag = Float64List(fftSize);
    final Float64List power = Float64List(fftSize ~/ 2 + 1);

    for (int frame = 0; frame < frames; frame++) {
      final int offset = frame * frameShift;
      real.fillRange(0, fftSize, 0);
      imag.fillRange(0, fftSize, 0);
      for (int i = 0; i < frameLength; i++) {
        real[i] = emphasised[offset + i] * _window[i];
      }

      _fftInPlace(real, imag);

      for (int bin = 0; bin < power.length; bin++) {
        power[bin] = real[bin] * real[bin] + imag[bin] * imag[bin];
      }

      for (int band = 0; band < melBands; band++) {
        final Float64List weights = _filterbank[band];
        double sum = 0;
        for (int bin = 0; bin < weights.length; bin++) {
          final double weight = weights[bin];
          if (weight != 0) sum += weight * power[bin];
        }
        // Natural log, matching torch.log in the exporter. log10 here would
        // scale every feature by 2.3 and quietly destroy accuracy.
        output[band * frames + frame] =
            math.log(sum < _logEpsilon ? _logEpsilon : sum);
      }
    }

    _applyCmvn(output, melBands, frames);
    return output;
  }

  /// Per-utterance mean and variance normalisation.
  ///
  /// Per-utterance rather than a stored global: it costs nothing here and it
  /// cancels the channel difference between a cheap handset microphone and
  /// whatever recorded the training data.
  static void _applyCmvn(Float32List features, int bands, int frames) {
    for (int band = 0; band < bands; band++) {
      final int base = band * frames;
      double sum = 0;
      for (int f = 0; f < frames; f++) {
        sum += features[base + f];
      }
      final double mean = sum / frames;

      double variance = 0;
      for (int f = 0; f < frames; f++) {
        final double d = features[base + f] - mean;
        variance += d * d;
      }
      final double stdDev = math.sqrt(variance / frames) + 1e-5;

      for (int f = 0; f < frames; f++) {
        features[base + f] = (features[base + f] - mean) / stdDev;
      }
    }
  }

  static Float64List _hannPeriodic(int length) {
    final Float64List window = Float64List(length);
    for (int i = 0; i < length; i++) {
      // Periodic (divide by N), not symmetric (N-1): this is what
      // torch.hann_window defaults to.
      window[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / length);
    }
    return window;
  }

  static double _hzToMel(double hz) =>
      2595.0 * (math.log(1 + hz / 700.0) / math.ln10);

  static double _melToHz(double mel) =>
      700.0 * (math.pow(10, mel / 2595.0) - 1);

  static List<Float64List> _melFilterbank({
    required int sampleRateHz,
    required int fftSize,
    required int melBands,
    required double lowerEdgeHz,
    required double upperEdgeHz,
  }) {
    final int bins = fftSize ~/ 2 + 1;
    final double lowMel = _hzToMel(lowerEdgeHz);
    final double highMel = _hzToMel(upperEdgeHz);

    final List<double> points = <double>[
      for (int i = 0; i < melBands + 2; i++)
        _melToHz(lowMel + (highMel - lowMel) * i / (melBands + 1)),
    ];

    final List<Float64List> bank = <Float64List>[];
    for (int band = 0; band < melBands; band++) {
      final Float64List weights = Float64List(bins);
      final double left = points[band];
      final double centre = points[band + 1];
      final double right = points[band + 2];
      for (int bin = 0; bin < bins; bin++) {
        final double hz = bin * sampleRateHz / fftSize;
        if (hz >= left && hz <= centre) {
          weights[bin] = (hz - left) / (centre - left);
        } else if (hz > centre && hz <= right) {
          weights[bin] = (right - hz) / (right - centre);
        }
      }
      bank.add(weights);
    }
    return bank;
  }

  /// Iterative radix-2 FFT.
  ///
  /// Hand-written rather than pulled from a package: it is thirty lines, it
  /// avoids a dependency in the hottest loop in the app, and it lets the
  /// exact arithmetic be compared against NumPy in the verifier.
  static void _fftInPlace(Float64List real, Float64List imag) {
    final int n = real.length;
    if (n <= 1) return;

    // Bit-reversal permutation.
    for (int i = 1, j = 0; i < n; i++) {
      int bit = n >> 1;
      for (; (j & bit) != 0; bit >>= 1) {
        j ^= bit;
      }
      j ^= bit;
      if (i < j) {
        final double tr = real[i];
        real[i] = real[j];
        real[j] = tr;
        final double ti = imag[i];
        imag[i] = imag[j];
        imag[j] = ti;
      }
    }

    for (int length = 2; length <= n; length <<= 1) {
      final double angle = -2 * math.pi / length;
      final double wReal = math.cos(angle);
      final double wImag = math.sin(angle);
      for (int i = 0; i < n; i += length) {
        double curReal = 1;
        double curImag = 0;
        for (int j = 0; j < length ~/ 2; j++) {
          final int a = i + j;
          final int b = i + j + length ~/ 2;
          final double xr = real[b] * curReal - imag[b] * curImag;
          final double xi = real[b] * curImag + imag[b] * curReal;
          real[b] = real[a] - xr;
          imag[b] = imag[a] - xi;
          real[a] += xr;
          imag[a] += xi;
          final double nextReal = curReal * wReal - curImag * wImag;
          curImag = curReal * wImag + curImag * wReal;
          curReal = nextReal;
        }
      }
    }
  }
}
