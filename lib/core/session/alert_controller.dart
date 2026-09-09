import 'dart:async';

import '../audio/playback_controller.dart';
import '../metrics/metrics.dart';
import '../protocol/message.dart';
import '../tts/tts_engine.dart';
import '../util/log.dart';

/// Plays alerts so that they cannot be missed.
///
/// Alerts are the reason this project exists, so they get their own path
/// rather than sharing the ordinary voice-note path:
///  * They repeat. Someone not holding the phone when it started still hears
///    the whole message.
///  * They play at raised volume and pre-empt anything in progress.
///  * They are slightly slowed (rate 0.92), which measurably improves
///    intelligibility over a small speaker in a noisy place.
///  * They cannot be interrupted by an incoming ordinary message; only the
///    user, or a higher-severity alert, stops one.
class AlertController {
  AlertController({
    required TtsEngine tts,
    required PlaybackController playback,
    required MetricsCollector metrics,
  })  : _tts = tts,
        _playback = playback,
        _metrics = metrics;

  final TtsEngine _tts;
  final PlaybackController _playback;
  final MetricsCollector _metrics;

  /// Silence between repeats. Long enough that two passes do not run
  /// together into one unintelligible stream.
  static const int repeatGapMs = 900;

  /// Alerts are spoken a little under normal speed.
  static const double alertSpeakingRate = 0.92;

  final List<AlertMessage> _active = <AlertMessage>[];
  bool _silenced = false;

  bool get active => _active.isNotEmpty;

  List<AlertMessage> get activeAlerts => List<AlertMessage>.unmodifiable(_active);

  /// Announces an alert, repeating it as the message asks.
  ///
  /// [onFirstAudible] reports stage B4 for the very first repeat only, since
  /// that is the moment a stopwatch at the far end would see.
  Future<void> announce(
    AlertMessage alert, {
    void Function(int monotonicMicros)? onFirstAudible,
  }) async {
    _active.add(alert);
    _silenced = false;
    _metrics.increment('alerts_announced');

    final PlaybackPriority priority = alert.severity == AlertSeverity.distress
        ? PlaybackPriority.distress
        : PlaybackPriority.warning;

    try {
      for (int repeat = 0; repeat < alert.repeatCount; repeat++) {
        if (_silenced) break;

        _metrics.mark(alert.messageId, Stage.b2SynthesisStart);

        bool reportedPcm = false;
        final Stream<PcmChunk> chunks = _tts
            .synthesize(SynthesisRequest(
              text: alert.text,
              languageTag: alert.languageTag,
              speakingRate: alertSpeakingRate,
              isAlert: true,
            ))
            .map((SynthesisChunk chunk) {
          if (!reportedPcm) {
            reportedPcm = true;
            _metrics.mark(alert.messageId, Stage.b3FirstPcm);
          }
          return PcmChunk(
            samples: chunk.samples,
            sampleRateHz: chunk.sampleRateHz,
            isLast: chunk.isLast,
          );
        });

        final bool isFirstRepeat = repeat == 0;
        final PlaybackOutcome outcome = await _playback.play(
          chunks: chunks,
          priority: priority,
          onFirstAudible: (int micros) {
            if (!isFirstRepeat) return;
            _metrics.mark(alert.messageId, Stage.b4FirstAudible, micros);
            onFirstAudible?.call(micros);
          },
        );

        if (!outcome.completed && outcome.reason == 'interrupted') {
          // A higher-severity alert took over; stop repeating this one.
          break;
        }

        if (repeat + 1 < alert.repeatCount && !_silenced) {
          await Future<void>.delayed(
              const Duration(milliseconds: repeatGapMs));
        }
      }

      _metrics.mark(alert.messageId, Stage.b5PlaybackDone);
    } on TtsException catch (e) {
      // A missing voice pack must not swallow the alert: the text is already
      // in the transcript, and the banner stays on screen.
      ItLog.w('alert', 'cannot speak alert: ${e.message}');
    } finally {
      _active.remove(alert);
    }
  }

  /// User-initiated stop. Counted, because an operator silencing every alert
  /// is a signal that the alerting policy is wrong.
  Future<void> silence() async {
    if (_active.isEmpty) return;
    _silenced = true;
    _metrics.increment('alerts_silenced_by_user');
    await _playback.stop();
    _active.clear();
  }
}
