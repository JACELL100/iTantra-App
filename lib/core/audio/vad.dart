import 'audio_frame.dart';

/// Voice activity detection.
///
/// Kept behind an interface so a neural VAD (Silero exported to ONNX) can be
/// dropped in without touching the endpointer, but the default is energy
/// based on purpose: idle CPU is a scored metric, and running a neural network
/// on every 20 ms frame while nobody is speaking spends battery to detect
/// silence.
abstract class VadEngine {
  /// Returns speech probability in 0..1 for one frame.
  double process(AudioFrame frame);

  void reset();
}

/// Adaptive-noise energy VAD.
///
/// The threshold is relative to a running noise floor rather than absolute,
/// because the same absolute level is speech in a quiet room and silence in a
/// moving vehicle. Activation and release use different thresholds
/// (hysteresis) so a level hovering near the boundary does not chatter
/// between speech and silence every frame.
class EnergyVadEngine implements VadEngine {
  EnergyVadEngine({
    this.activationSnrDb = 8.0,
    this.releaseSnrDb = 4.0,
    this.noiseAdaptUp = 0.02,
    this.noiseAdaptDown = 0.25,
    this.calibrationFrames = 10,
  });

  /// Speech must exceed the noise floor by this much to start.
  final double activationSnrDb;

  /// Once speech has started, it continues until it drops below this. The gap
  /// between the two is what suppresses chattering.
  final double releaseSnrDb;

  /// The noise floor rises slowly (so a long vowel is not mistaken for noise)
  /// and falls quickly (so it recovers immediately when a truck passes).
  final double noiseAdaptUp;
  final double noiseAdaptDown;

  /// Frames used to seed the noise floor before any decision is made.
  final int calibrationFrames;

  double _noiseFloorDb = -60;
  int _seen = 0;
  bool _inSpeech = false;

  double get noiseFloorDb => _noiseFloorDb;

  @override
  double process(AudioFrame frame) {
    final double levelDb = frame.rmsDbfs;

    if (_seen < calibrationFrames) {
      _seen++;
      // Straight average during calibration: 200 ms of whatever the room
      // sounds like, which is a better start than any constant.
      _noiseFloorDb = _seen == 1
          ? levelDb
          : _noiseFloorDb + (levelDb - _noiseFloorDb) / _seen;
      return 0;
    }

    final double snr = levelDb - _noiseFloorDb;
    final bool wasInSpeech = _inSpeech;
    _inSpeech = wasInSpeech
        ? snr > releaseSnrDb
        : snr > activationSnrDb;

    // Only adapt on frames we believe are noise, or the floor slowly climbs
    // to the level of the speaker's own voice and stops detecting them.
    if (!_inSpeech) {
      final double rate =
          levelDb > _noiseFloorDb ? noiseAdaptUp : noiseAdaptDown;
      _noiseFloorDb += rate * (levelDb - _noiseFloorDb);
    }

    if (!_inSpeech) return 0;

    // A soft probability rather than a hard 1.0 lets the endpointer weigh
    // marginal frames instead of treating a whisper like a shout.
    final double margin = (snr - releaseSnrDb) / 12.0;
    return margin.clamp(0.5, 1.0);
  }

  @override
  void reset() {
    _noiseFloorDb = -60;
    _seen = 0;
    _inSpeech = false;
  }
}
