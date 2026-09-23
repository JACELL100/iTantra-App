import 'dart:async';
import 'dart:typed_data';

import '../asr/asr_engine.dart';
import '../audio/audio_frame.dart';
import '../audio/capture_engine.dart';
import '../audio/endpoint_controller.dart';
import '../audio/playback_controller.dart';
import '../audio/vad.dart';
import '../metrics/metrics.dart';
import '../protocol/message.dart';
import '../storage/entities.dart';
import '../storage/message_repository.dart';
import '../tts/tts_engine.dart';
import '../util/log.dart';
import 'alert_controller.dart';
import 'floor_controller.dart';
import 'message_pipeline.dart';

/// How the microphone behaves.
enum SessionMode {
  /// Walkie-talkie. The microphone is only live while the button is held,
  /// which is both the requested behaviour and the reason idle CPU can stay
  /// near zero.
  pushToTalk,

  /// Phone-like. The endpointer decides where sentences begin and end.
  handsFree,
}

/// Events the UI reacts to.
sealed class SessionEvent {
  const SessionEvent();
}

class SessionMessageStored extends SessionEvent {
  const SessionMessageStored(this.message);

  final StoredMessage message;
}

class SessionMessageUpdated extends SessionEvent {
  const SessionMessageUpdated(this.id, this.state);

  final String id;
  final DeliveryState state;
}

/// Input level, for the talk button's glow. Sent as an event rather than a
/// separate stream so the UI has exactly one thing to listen to.
class SessionLevel extends SessionEvent {
  const SessionLevel(this.rmsDbfs, this.isSpeech);

  final double rmsDbfs;
  final bool isSpeech;
}

class SessionError extends SessionEvent {
  const SessionError(this.message, {this.isMissingModel = false});

  final String message;

  /// Lets the UI say "install the Tamil pack" instead of "an error occurred".
  final bool isMissingModel;
}

class SessionAlert extends SessionEvent {
  const SessionAlert(this.alert);

  final AlertMessage alert;
}

/// Orchestrates the whole loop: microphone in, text out, text in, speech out.
///
/// This is the only class that knows the order of operations, and it is
/// deliberately the only stateful one. Everything it uses is injected, so the
/// same controller runs in a widget test over a loopback transport with stub
/// engines.
class SessionController {
  SessionController({
    required CaptureEngine capture,
    required PlaybackController playback,
    required MessagePipeline pipeline,
    required MessageRepository repository,
    required MetricsCollector metrics,
    required FloorController floor,
    required AlertController alerts,
    required String Function() languageTag,
    String? Function()? targetLanguageTag, // null = same-language mode
    AsrEngine? asr,
    TtsEngine? tts,
    VadEngine? vad,
    EndpointController? endpointer,
  })  : _capture = capture,
        _playback = playback,
        _pipeline = pipeline,
        _repository = repository,
        _metrics = metrics,
        _floor = floor,
        _alerts = alerts,
        _languageTag = languageTag,
        _targetLanguageTag = targetLanguageTag ?? (() => null),
        _asr = asr,
        _tts = tts,
        _vad = vad ?? EnergyVadEngine(),
        _endpointer = endpointer ?? EndpointController();

  final CaptureEngine _capture;
  final PlaybackController _playback;
  final MessagePipeline _pipeline;
  final MessageRepository _repository;
  final MetricsCollector _metrics;
  final FloorController _floor;
  final AlertController _alerts;
  final String Function() _languageTag;
  final String? Function() _targetLanguageTag; // Returns target lang or null
  final AsrEngine? _asr;
  final TtsEngine? _tts;
  final VadEngine _vad;
  final EndpointController _endpointer;

  final StreamController<SessionEvent> _events =
      StreamController<SessionEvent>.broadcast();

  StreamSubscription<AudioFrame>? _frames;
  StreamSubscription<Inbound>? _inbound;

  SessionMode _mode = SessionMode.pushToTalk;
  bool _talking = false;

  /// Recognition runs one utterance at a time. Two concurrent forward passes
  /// on a low-end CPU are slower than two sequential ones and can exhaust
  /// memory, so utterances queue behind this future instead.
  Future<void> _asrQueue = Future<void>.value();

  Stream<SessionEvent> get events => _events.stream;

  SessionMode get mode => _mode;

  bool get isTalking => _talking;

  Future<void> start() async {
    _inbound = _pipeline.inbound().listen(_onInbound);

    final Stream<AudioFrame> frames = await _capture.start();
    _frames = frames.listen(_onFrame, onError: (Object error) {
      _events.add(SessionError('microphone error: $error'));
    });

    // In push-to-talk the microphone is muted until the button is pressed.
    _capture.setMuted(_mode == SessionMode.pushToTalk);
  }

  void setMode(SessionMode mode) {
    _mode = mode;
    _capture.setMuted(mode == SessionMode.pushToTalk && !_talking);
    _endpointer.reset();
    _vad.reset();
  }

  Future<void> pressTalk() async {
    if (_talking) return;
    final FloorDecision decision = _floor.requestLocal();
    if (decision == FloorDecision.denied) {
      _events.add(const SessionError('the other side is talking'));
      return;
    }
    _talking = true;
    _vad.reset();
    _endpointer.reset();
    _capture.setMuted(false);
    await _pipeline.sendFloor(FloorOp.request);
  }

  Future<void> releaseTalk() async {
    if (!_talking) return;
    _talking = false;

    // Flush before muting, so a word still in flight is transcribed rather
    // than discarded.
    final Utterance? tail = _endpointer.flush(EndReason.manual);
    if (tail != null) _enqueue(tail);

    if (_mode == SessionMode.pushToTalk) _capture.setMuted(true);
    _floor.releaseLocal();
    await _pipeline.sendFloor(FloorOp.release);
  }

  void _onFrame(AudioFrame frame) {
    final double probability = _vad.process(frame);
    _events.add(SessionLevel(frame.rmsDbfs, probability >= 0.5));

    final Utterance? utterance = _endpointer.onFrame(frame, probability);
    if (utterance != null) _enqueue(utterance);
  }

  void _enqueue(Utterance utterance) {
    _asrQueue = _asrQueue.then((_) => _recognise(utterance)).catchError(
        (Object error, StackTrace stack) {
      ItLog.e('session', 'recognition failed', error, stack);
    });
  }

  Future<void> _recognise(Utterance utterance) async {
    final AsrEngine? asr = _asr;
    if (asr == null) {
      _events.add(const SessionError(
        'no speech-to-text pack installed',
        isMissingModel: true,
      ));
      return;
    }

    final String language = _languageTag();
    final String messageId = _pipeline.newMessageId();
    _metrics.mark(
        messageId, Stage.a0SpeechEnd, utterance.monotonicSpeechEndMicros);
    _metrics.mark(messageId, Stage.a1Endpoint);

    final AsrResult result;
    try {
      // Pass target language if cross-language mode is enabled
      final String? targetLang = _targetLanguageTag();
      result = await asr.transcribe(
        pcm: utterance.pcm,
        languageTag: language,
        targetLanguageTag: targetLang,
      );
    } on AsrException catch (e) {
      _events.add(SessionError(e.message, isMissingModel: e.isMissingModel));
      return;
    }

    _metrics.mark(messageId, Stage.a2AsrFinal);

    if (result.isEmpty) {
      // Silence, wind, or a door closing. Nothing is sent, because an empty
      // message on the far end is noise, not information.
      return;
    }

    // Determine what to send and what language the receiver should use
    final String sendLang = result.hasTranslation ? language : language;
    final String sendText = result.text;
    final String? translatedText = result.translatedText;
    final String? targetLang = result.targetLanguageTag;

    final StoredMessage stored = StoredMessage(
      id: messageId,
      direction: MessageDirection.outgoing,
      languageTag: language,
      text: result.text,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      state: DeliveryState.pending,
      confidence: result.confidence,
      // Store translation metadata
      translatedText: translatedText,
      targetLanguageTag: targetLang,
    );
    await _repository.insert(stored);
    _events.add(SessionMessageStored(stored));

    try {
      await _pipeline.sendText(
        text: sendText,
        languageTag: language,
        confidence: result.confidence,
        messageId: messageId,
        srcLang: language,
        tgtLang: targetLang,
        translatedText: translatedText,
      );
      await _repository.updateState(messageId, DeliveryState.sent);
      _events.add(SessionMessageUpdated(messageId, DeliveryState.sent));

      final double? sendMs = _metrics.timeline(messageId).sendMs;
      if (sendMs != null) {
        _metrics.record('send_ms', sendMs);
        await _repository.recordLatencySample('send_ms', sendMs,
            messageId: messageId);
      }
    } on Object catch (error) {
      await _repository.updateState(messageId, DeliveryState.failed);
      _events.add(SessionMessageUpdated(messageId, DeliveryState.failed));
      _events.add(SessionError('could not send: $error'));
    }
  }

  Future<void> raiseAlert({
    required String text,
    AlertSeverity severity = AlertSeverity.distress,
  }) async {
    final String language = _languageTag();
    _floor.requestLocal(forAlert: true);

    final AlertMessage message = await _pipeline.sendAlert(
      text: text,
      languageTag: language,
      severity: severity,
    );

    final StoredMessage stored = StoredMessage(
      id: message.messageId,
      direction: MessageDirection.outgoing,
      languageTag: language,
      text: text,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      state: DeliveryState.sent,
      isAlert: true,
      severity: severity.name,
    );
    await _repository.insert(stored);
    _events.add(SessionMessageStored(stored));
    _floor.releaseLocal();
  }

  Future<void> _onInbound(Inbound inbound) async {
    switch (inbound) {
      case InboundRejected(reason: final String reason):
        _events.add(SessionError('dropped a frame: $reason'));
      case InboundDuplicate():
        // Already handled; nothing to do but the counter, which the pipeline
        // has already incremented.
        break;
      case InboundMessage(message: final WireMessage message):
        await _handleMessage(message);
    }
  }

  Future<void> _handleMessage(WireMessage message) async {
    switch (message) {
      case TextMessage text:
        await _handleText(text);
      case AlertMessage alert:
        await _handleAlert(alert);
      case ReceiptMessage receipt:
        _metrics.mark(receipt.acknowledgedId, Stage.a5Receipt);
        await _repository.updateState(
            receipt.acknowledgedId, DeliveryState.played);
        _events.add(SessionMessageUpdated(
            receipt.acknowledgedId, DeliveryState.played));
      case FloorMessage floor:
        _handleFloor(floor);
      case CapabilitiesMessage():
        // Handled by the pairing flow, which owns capability state.
        break;
    }
  }

  void _handleFloor(FloorMessage floor) {
    switch (floor.op) {
      case FloorOp.request:
        _floor.requestFromPeer();
      case FloorOp.release:
        _floor.releaseFromPeer();
      case FloorOp.grant:
      case FloorOp.reject:
        break;
    }
  }

  Future<void> _handleText(TextMessage text) async {
    // Use translated text and target language if this is a cross-language message
    final speakLang = text.speakLanguage;
    final speakText = text.speakText;

    final StoredMessage stored = await _repository.insertIncoming(
      id: text.messageId,
      languageTag: speakLang,
      text: speakText,
      isAlert: false,
      peerId: text.senderId,
      confidence: text.confidencePercent / 100.0,
      // Store original + translation metadata
      originalText: text.text,
      originalLanguageTag: text.languageTag,
      translatedText: text.translatedText,
      targetLanguageTag: text.tgtLang,
    );
    _metrics.mark(text.messageId, Stage.b1Stored);
    _events.add(SessionMessageStored(stored));

    await _speak(
      messageId: text.messageId,
      text: speakText,
      languageTag: speakLang,
    );

    await _pipeline.sendReceipt(text.messageId);
  }

  Future<void> _handleAlert(AlertMessage alert) async {
    final StoredMessage stored = await _repository.insertIncoming(
      id: alert.messageId,
      languageTag: alert.languageTag,
      text: alert.text,
      isAlert: true,
      severity: alert.severity.name,
      peerId: alert.senderId,
    );
    _metrics.mark(alert.messageId, Stage.b1Stored);
    _events.add(SessionMessageStored(stored));
    _events.add(SessionAlert(alert));

    // Muted for the same reason as ordinary playback, and it matters more
    // here: an alert plays at full volume, so a live microphone would
    // certainly hear it and could re-transmit it.
    _capture.setMuted(true);
    try {
      await _alerts.announce(alert);
    } finally {
      _capture.setMuted(_mode == SessionMode.pushToTalk && !_talking);
    }

    await _pipeline.sendReceipt(alert.messageId);
    await _recordReceiveLatency(alert.messageId);
  }

  Future<void> _speak({
    required String messageId,
    required String text,
    required String languageTag,
  }) async {
    final TtsEngine? tts = _tts;
    if (tts == null) {
      _events.add(const SessionError(
        'no voice pack installed, showing text only',
        isMissingModel: true,
      ));
      return;
    }

    _metrics.mark(messageId, Stage.b2SynthesisStart);

    bool sawFirstChunk = false;
    final Stream<PcmChunk> chunks = tts
        .synthesize(SynthesisRequest(text: text, languageTag: languageTag))
        .map((SynthesisChunk chunk) {
      if (!sawFirstChunk) {
        sawFirstChunk = true;
        _metrics.mark(messageId, Stage.b3FirstPcm);
      }
      // Convert Float32List (-1.0 to 1.0) to Int16List (-32768 to 32767)
      final int16Samples = Int16List(chunk.samples.length);
      for (int i = 0; i < chunk.samples.length; i++) {
        int16Samples[i] = (chunk.samples[i].clamp(-1.0, 1.0) * 32767).round();
      }
      return PcmChunk(
        samples: int16Samples,
        sampleRateHz: chunk.sampleRateHz,
        isLast: chunk.isLast,
      );
    });

    // The microphone is muted for the duration of playback. Without this,
    // hands-free mode transcribes the phone's own speaker output and the two
    // devices talk to each other forever.
    _capture.setMuted(true);
    try {
      await _playback.play(
        chunks: chunks,
        onFirstAudible: (int micros) {
          _metrics.mark(messageId, Stage.b4FirstAudible, micros);
        },
      );
      _metrics.mark(messageId, Stage.b5PlaybackDone);
    } on TtsException catch (e) {
      _events.add(SessionError(e.message, isMissingModel: e.isMissingModel));
    } finally {
      _capture.setMuted(_mode == SessionMode.pushToTalk && !_talking);
    }

    await _repository.updateState(messageId, DeliveryState.played);
    _events.add(SessionMessageUpdated(messageId, DeliveryState.played));
    await _recordReceiveLatency(messageId);
  }

  Future<void> _recordReceiveLatency(String messageId) async {
    final MessageTimeline line = _metrics.timeline(messageId);
    final double? receiveMs = line.receiveMs;
    if (receiveMs != null) {
      _metrics.record('receive_ms', receiveMs);
      await _repository.recordLatencySample('receive_ms', receiveMs,
          messageId: messageId);
    }
    final double? deltaMs = line.deltaMs;
    if (deltaMs != null) {
      _metrics.record('delta_ms', deltaMs);
      await _repository.recordLatencySample('delta_ms', deltaMs,
          messageId: messageId);
    }
  }

  /// Sends a pre-written phrase without using the microphone, for a user who
  /// cannot speak or must stay silent.
  Future<void> sendTypedText(String text) async {
    final String language = _languageTag();
    final String id = _pipeline.newMessageId();
    _metrics.mark(id, Stage.a0SpeechEnd);

    final StoredMessage stored = StoredMessage(
      id: id,
      direction: MessageDirection.outgoing,
      languageTag: language,
      text: text,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      state: DeliveryState.pending,
    );
    await _repository.insert(stored);
    _events.add(SessionMessageStored(stored));

    await _pipeline.sendText(
      text: text,
      languageTag: language,
      confidence: 1.0,
      messageId: id,
    );
    await _repository.updateState(id, DeliveryState.sent);
    _events.add(SessionMessageUpdated(id, DeliveryState.sent));
  }

  Future<void> dispose() async {
    await _frames?.cancel();
    await _inbound?.cancel();
    await _capture.stop();
    await _playback.stop();
    await _events.close();
  }

  /// Exposed for the diagnostics screen's synthetic latency test.
  Int16List silenceForTest(int milliseconds) =>
      Int16List(AudioFormatSpec.sampleRateHz * milliseconds ~/ 1000);
}
