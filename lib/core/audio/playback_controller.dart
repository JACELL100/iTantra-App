import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../util/log.dart';
import 'resampler.dart';

/// One block of synthesised audio.
class PcmChunk {
  const PcmChunk({
    required this.samples,
    required this.sampleRateHz,
    this.isLast = false,
  });

  final Int16List samples;
  final int sampleRateHz;
  final bool isLast;

  int get durationMs => samples.length * 1000 ~/ sampleRateHz;
}

/// How a playback request behaves when something is already playing.
enum PlaybackPriority {
  /// Normal voice note. Queued behind whatever is playing.
  normal,

  /// Warning. Plays at raised volume and interrupts normal speech.
  warning,

  /// Distress. Full volume, interrupts everything, cannot be ducked.
  distress,
}

/// Result of a playback attempt.
class PlaybackOutcome {
  const PlaybackOutcome({
    required this.completed,
    required this.firstAudibleMicros,
    this.reason,
  });

  final bool completed;

  /// Stage B4: the monotonic microsecond at which the platform reported the
  /// first sample actually reaching the output device. Not the moment we
  /// handed bytes to the mixer - the gap between the two is real and is part
  /// of what the user perceives as latency.
  final int firstAudibleMicros;

  final String? reason;
}

/// Streaming playback over a platform channel.
///
/// Chunks are written as they arrive from the vocoder rather than after the
/// whole utterance is synthesised. On a low-end phone a three-second sentence
/// takes over a second to synthesise, so streaming the first chunk as soon as
/// it exists removes most of the perceived delay.
class PlaybackController {
  PlaybackController({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('org.itantra/audio_playback');

  final MethodChannel _channel;

  int _sessionCounter = 0;
  int? _activeSession;
  PlaybackPriority _activePriority = PlaybackPriority.normal;

  bool get isPlaying => _activeSession != null;
  PlaybackPriority get activePriority => _activePriority;

  /// Plays a stream of chunks. [onFirstAudible] fires once, with the
  /// monotonic timestamp of the first audible sample.
  Future<PlaybackOutcome> play({
    required Stream<PcmChunk> chunks,
    PlaybackPriority priority = PlaybackPriority.normal,
    void Function(int monotonicMicros)? onFirstAudible,
  }) async {
    // A distress announcement must not wait behind a queued voice note.
    if (_activeSession != null && priority.index > _activePriority.index) {
      await stop();
    }

    final int session = ++_sessionCounter;
    _activeSession = session;
    _activePriority = priority;

    int firstAudible = 0;
    try {
      final Map<Object?, Object?>? started =
          await _channel.invokeMapMethod<Object?, Object?>('start',
              <String, Object?>{
            'session': session,
            'priority': priority.name,
          });
      final bool granted = (started?['granted'] as bool?) ?? false;
      if (!granted) {
        _activeSession = null;
        return const PlaybackOutcome(
          completed: false,
          firstAudibleMicros: 0,
          reason: 'audio focus denied',
        );
      }

      await for (final PcmChunk chunk in chunks) {
        if (_activeSession != session) {
          return PlaybackOutcome(
            completed: false,
            firstAudibleMicros: firstAudible,
            reason: 'interrupted',
          );
        }
        final Map<Object?, Object?>? wrote =
            await _channel.invokeMapMethod<Object?, Object?>('write',
                <String, Object?>{
              'session': session,
              'pcm': Resampler.samplesToBytes(chunk.samples),
              'sampleRateHz': chunk.sampleRateHz,
              'last': chunk.isLast,
            });
        final int? audible = wrote?['audible'] as int?;
        if (audible != null && audible > 0 && firstAudible == 0) {
          firstAudible = audible;
          onFirstAudible?.call(audible);
        }
      }

      // Drain waits for the buffer to empty; without it the microphone would
      // reopen while the tail of the sentence is still in the speaker, and
      // in hands-free mode the app would transcribe itself.
      await _channel.invokeMethod<void>('drain', <String, Object?>{
        'session': session,
      });

      return PlaybackOutcome(
        completed: true,
        firstAudibleMicros: firstAudible,
      );
    } on PlatformException catch (e) {
      ItLog.e('playback', 'platform failure: ${e.message}');
      return PlaybackOutcome(
        completed: false,
        firstAudibleMicros: firstAudible,
        reason: e.message,
      );
    } finally {
      if (_activeSession == session) {
        _activeSession = null;
        _activePriority = PlaybackPriority.normal;
      }
    }
  }

  Future<void> stop() async {
    final int? session = _activeSession;
    _activeSession = null;
    _activePriority = PlaybackPriority.normal;
    if (session == null) return;
    try {
      await _channel.invokeMethod<void>('stop', <String, Object?>{
        'session': session,
      });
    } on PlatformException catch (e) {
      ItLog.w('playback', 'stop failed: ${e.message}');
    }
  }
}
