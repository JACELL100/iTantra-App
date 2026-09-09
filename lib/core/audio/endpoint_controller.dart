import 'dart:typed_data';

import 'audio_frame.dart';

/// Why an utterance was closed.
enum EndReason { silence, hardLimit, manual }

/// Endpointing thresholds.
///
/// These numbers are the difference between a walkie-talkie that feels
/// instant and one that feels broken, so each is chosen rather than guessed.
class EndpointConfig {
  const EndpointConfig({
    this.preRollMs = 250,
    this.postRollMs = 150,
    this.minSpeechMs = 200,
    this.endSilenceMs = 450,
    this.softLimitMs = 8000,
    this.hardLimitMs = 12000,
    this.speechThreshold = 0.5,
  });

  /// Audio kept from *before* the VAD fired. Without it the first consonant
  /// is always missing, because detection inevitably lags onset.
  final int preRollMs;

  /// Audio kept after speech ends, so a trailing fricative survives.
  final int postRollMs;

  /// Shorter than this is a cough, a door, or a knock.
  final int minSpeechMs;

  /// Silence that closes an utterance. 450 ms is the compromise: 300 ms cuts
  /// people off mid-sentence when they pause to think, and 700 ms adds a
  /// quarter second to every message's latency.
  final int endSilenceMs;

  /// After this, the utterance is cut at the next pause - long enough to say
  /// something useful, short enough that the listener is not waiting.
  final int softLimitMs;

  /// Absolute cap. Protects memory and stops a stuck-open microphone from
  /// buffering forever.
  final int hardLimitMs;

  final double speechThreshold;
}

/// A closed segment of speech, ready for recognition.
class Utterance {
  const Utterance({
    required this.pcm,
    required this.monotonicStartMicros,
    required this.monotonicSpeechEndMicros,
    required this.reason,
    this.isContinuation = false,
  });

  final Int16List pcm;
  final int monotonicStartMicros;

  /// Stage A0. The moment speech actually stopped, not the moment we noticed,
  /// so end-to-end latency is measured against what the speaker experienced.
  final int monotonicSpeechEndMicros;

  final EndReason reason;

  /// True when the previous segment was cut at the soft limit, so the UI can
  /// join the transcripts instead of showing two fragments.
  final bool isContinuation;

  int get durationMs => pcm.length * 1000 ~/ AudioFormatSpec.sampleRateHz;
}

/// Turns a stream of frames plus VAD probabilities into utterances.
///
/// A ring buffer holds the pre-roll continuously, which is the only way to
/// include audio from before the decision that speech had started.
class EndpointController {
  EndpointController({this.config = const EndpointConfig()})
      : _preRollFrames = config.preRollMs ~/ AudioFormatSpec.frameDurationMs,
        _postRollFrames = config.postRollMs ~/ AudioFormatSpec.frameDurationMs,
        _endSilenceFrames =
            config.endSilenceMs ~/ AudioFormatSpec.frameDurationMs,
        _minSpeechFrames =
            config.minSpeechMs ~/ AudioFormatSpec.frameDurationMs,
        _softLimitFrames =
            config.softLimitMs ~/ AudioFormatSpec.frameDurationMs,
        _hardLimitFrames =
            config.hardLimitMs ~/ AudioFormatSpec.frameDurationMs;

  final EndpointConfig config;

  final int _preRollFrames;
  final int _postRollFrames;
  final int _endSilenceFrames;
  final int _minSpeechFrames;
  final int _softLimitFrames;
  final int _hardLimitFrames;

  final List<AudioFrame> _preRoll = <AudioFrame>[];
  final List<AudioFrame> _active = <AudioFrame>[];

  bool _inSpeech = false;
  int _speechFrames = 0;
  int _silenceFrames = 0;
  int _trailingFrames = 0;
  int _startMicros = 0;
  int _lastSpeechMicros = 0;
  bool _nextIsContinuation = false;

  bool get isCapturingUtterance => _inSpeech;

  /// Feeds one frame. Returns an utterance when one closes.
  Utterance? onFrame(AudioFrame frame, double speechProbability) {
    final bool isSpeech = speechProbability >= config.speechThreshold;

    if (!_inSpeech) {
      _preRoll.add(frame);
      while (_preRoll.length > _preRollFrames) {
        _preRoll.removeAt(0);
      }
      if (!isSpeech) return null;

      _inSpeech = true;
      _active
        ..clear()
        ..addAll(_preRoll);
      _preRoll.clear();
      _startMicros = _active.isEmpty
          ? frame.monotonicMicros
          : _active.first.monotonicMicros;
      _speechFrames = 0;
      _silenceFrames = 0;
      _trailingFrames = 0;
    }

    _active.add(frame);

    if (isSpeech) {
      _speechFrames++;
      _silenceFrames = 0;
      _trailingFrames = 0;
      _lastSpeechMicros = frame.monotonicMicros + frame.durationMs * 1000;
    } else {
      _silenceFrames++;
      if (_trailingFrames < _postRollFrames) _trailingFrames++;
    }

    if (_active.length >= _hardLimitFrames) {
      return _close(EndReason.hardLimit, continuationNext: true);
    }

    // Past the soft limit, the next pause of any length ends the segment.
    if (_active.length >= _softLimitFrames && !isSpeech) {
      return _close(EndReason.silence, continuationNext: true);
    }

    if (_silenceFrames >= _endSilenceFrames) {
      if (_speechFrames < _minSpeechFrames) {
        // Too short to be speech: drop it and go back to listening, keeping
        // the tail as the new pre-roll.
        _resetToListening();
        return null;
      }
      return _close(EndReason.silence);
    }

    return null;
  }

  /// Ends the current utterance immediately, used when the talk button is
  /// released. The buffered audio is kept, not discarded, so a word still
  /// being spoken at release is not chopped in half.
  Utterance? flush(EndReason reason) {
    if (!_inSpeech) return null;
    if (_speechFrames < _minSpeechFrames) {
      _resetToListening();
      return null;
    }
    return _close(reason);
  }

  Utterance? _close(EndReason reason, {bool continuationNext = false}) {
    // Trim silence beyond the post-roll: it costs recognition time and adds
    // nothing. The frames counted in _silenceFrames past _postRollFrames are
    // the ones removed.
    final int excess = _silenceFrames - _postRollFrames;
    final int keep = excess > 0 ? _active.length - excess : _active.length;
    final List<AudioFrame> frames =
        _active.sublist(0, keep < 0 ? 0 : keep);

    final int totalSamples = frames.fold<int>(
        0, (int sum, AudioFrame f) => sum + f.samples.length);
    final Int16List pcm = Int16List(totalSamples);
    int offset = 0;
    for (final AudioFrame f in frames) {
      pcm.setRange(offset, offset + f.samples.length, f.samples);
      offset += f.samples.length;
    }

    final Utterance utterance = Utterance(
      pcm: pcm,
      monotonicStartMicros: _startMicros,
      monotonicSpeechEndMicros:
          _lastSpeechMicros == 0 ? _startMicros : _lastSpeechMicros,
      reason: reason,
      isContinuation: _nextIsContinuation,
    );

    _nextIsContinuation = continuationNext;
    _resetToListening();
    return utterance;
  }

  void _resetToListening() {
    // Keep the last few frames as pre-roll: if the speaker starts again
    // immediately, the onset is already buffered.
    final int tail = _active.length < _preRollFrames
        ? _active.length
        : _preRollFrames;
    _preRoll
      ..clear()
      ..addAll(_active.sublist(_active.length - tail));
    _active.clear();
    _inSpeech = false;
    _speechFrames = 0;
    _silenceFrames = 0;
    _trailingFrames = 0;
  }

  void reset() {
    _preRoll.clear();
    _active.clear();
    _inSpeech = false;
    _speechFrames = 0;
    _silenceFrames = 0;
    _trailingFrames = 0;
    _nextIsContinuation = false;
    _lastSpeechMicros = 0;
  }
}
