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

/// The utterance closed but produced no text: silence, wind, or a door.
///
/// Distinct from an error, because the fix is different - speak louder or
/// closer rather than install a pack or reconnect.
class SessionNoSpeech extends SessionEvent {
  const SessionNoSpeech();
}

/// Recognition is in flight.
///
/// Surfaced so the talk button can hold its "recognising" face while an
/// utterance is being decoded. Without it the button snaps back to ready the
/// instant the finger lifts, and a user whose sentence takes two seconds to
/// transcribe has no idea whether it worked.
class SessionBusy extends SessionEvent {
  const SessionBusy(this.isRecognising);

  final bool isRecognising;
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
    AsrEngine? asr,
    TtsEngine? tts,
    VadEngine? vad,
    EndpointController? endpointer,
    Future<void> Function(HandshakeMessage hello)? onHandshake,
  })  : _onHandshake = onHandshake,
        _capture = capture,
        _playback = playback,
        _pipeline = pipeline,
        _repository = repository,
        _metrics = metrics,
        _floor = floor,
        _alerts = alerts,
        _languageTag = languageTag,
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
  final AsrEngine? _asr;
  final TtsEngine? _tts;
  final VadEngine _vad;
  final EndpointController _endpointer;

  /// Pairing is owned by the launcher, not the session: the key exchange
  /// finishes before there is a session to speak of. The session only routes
  /// the frame to it, because the session already owns the single inbound
  /// subscription.
  final Future<void> Function(HandshakeMessage hello)? _onHandshake;

  final StreamController<SessionEvent> _events =
      StreamController<SessionEvent>.broadcast();

  StreamSubscription<AudioFrame>? _frames;
  StreamSubscription<Inbound>? _inbound;

  SessionMode _mode = SessionMode.pushToTalk;
  bool _talking = false;
  bool _recognising = false;

  /// True while an utterance is being decoded or sent. The UI uses this to keep
  /// the talk button in its "recognising" state rather than dropping back to
  /// ready the instant a finger lifts.
  bool get isRecognising => _recognising;

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

    _recognising = true;
    _events.add(const SessionBusy(true));

    final AsrResult result;
    try {
      result = await asr.transcribe(
        pcm: utterance.pcm,
        languageTag: language,
      );
    } on AsrException catch (e) {
      _events.add(SessionError(e.message, isMissingModel: e.isMissingModel));
      return;
    } finally {
      _recognising = false;
      _events.add(const SessionBusy(false));
    }

    _metrics.mark(messageId, Stage.a2AsrFinal);

    if (result.isEmpty) {
      // Silence, wind, or a door closing. Nothing is sent, because an empty
      // message on the far end is noise, not information. A user who spoke and
      // got nothing needs to be told, though, or they will assume the link is
      // broken.
      _metrics.increment('local_no_speech');
      _events.add(const SessionNoSpeech());
      return;
    }

    final StoredMessage stored = StoredMessage(
      id: messageId,
      direction: MessageDirection.outgoing,
      languageTag: language,
      text: result.text,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      state: DeliveryState.pending,
      confidence: result.confidence,
    );
    await _repository.insert(stored);
    _events.add(SessionMessageStored(stored));

    try {
      await _pipeline.sendText(
        text: result.text,
        languageTag: language,
        confidence: result.confidence,
        messageId: messageId,
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
      case final TextMessage text:
        await _handleText(text);
      case final AlertMessage alert:
        await _handleAlert(alert);
      case final ReceiptMessage receipt:
        _metrics.mark(receipt.acknowledgedId, Stage.a5Receipt);
        await _repository.updateState(
            receipt.acknowledgedId, DeliveryState.played);
        _events.add(SessionMessageUpdated(
            receipt.acknowledgedId, DeliveryState.played));
      case final FloorMessage floor:
        _handleFloor(floor);
      case final CapabilitiesMessage caps:
        // A capability refresh mid-session, which is what a peer sends after
        // someone installs a pack. Recorded but not acted on yet.
        _metrics.increment('capability_refreshes_received');
        ItLog.i('session', 'peer can hear ${caps.ttsLanguages.length} languages');
      case final HandshakeMessage handshake:
        // Reached only when a peer re-handshakes on a live link, which is what
        // happens after a reconnect. Routed rather than handled, so the key
        // exchange stays in one place.
        await _onHandshake?.call(handshake);
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
    final StoredMessage stored = await _repository.insertIncoming(
      id: text.messageId,
      languageTag: text.languageTag,
      text: text.text,
      isAlert: false,
      peerId: text.senderId,
      confidence: text.confidencePercent / 100.0,
    );
    _metrics.mark(text.messageId, Stage.b1Stored);
    _events.add(SessionMessageStored(stored));

    await _speak(
      messageId: text.messageId,
      text: text.text,
      languageTag: text.languageTag,
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
      return PcmChunk(
        samples: chunk.samples,
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

  /// Announces a message that something other than this phone's receive path
  /// stored, so the UI can show it.
  ///
  /// The single-phone demonstration writes its incoming rows straight to the
  /// repository, because there is no second device and therefore no second
  /// SessionController to raise the event. Without this hook those rows exist
  /// in the database and never appear on screen, which is precisely what made
  /// the demonstration look broken: the sender pressed send, and nothing at all
  /// came back.
  void publishPeerStored(StoredMessage message) {
    if (_events.isClosed) return;
    _events.add(SessionMessageStored(message));
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
