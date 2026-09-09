import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/session/session_controller.dart';
import '../core/storage/entities.dart';
import '../di/service_locator.dart';

/// View state for the conversation screen.
///
/// A plain ChangeNotifier rather than a state-management package. The screen
/// has one source of truth (the session's event stream) and a handful of
/// fields; introducing a framework here would add concepts without removing
/// any, and it keeps the app's dependency list - which is scored as app size
/// - shorter.
class ConversationController extends ChangeNotifier {
  ConversationController(this._locator);

  final ServiceLocator _locator;

  SessionController? _session;
  StreamSubscription<SessionEvent>? _events;

  final List<StoredMessage> _messages = <StoredMessage>[];
  double _level = 0;
  bool _speechDetected = false;
  bool _talking = false;
  String? _banner;
  bool _bannerIsMissingModel = false;
  bool _connecting = false;

  List<StoredMessage> get messages => List<StoredMessage>.unmodifiable(_messages);
  double get level => _level;
  bool get speechDetected => _speechDetected;
  bool get talking => _talking;
  String? get banner => _banner;
  bool get bannerIsMissingModel => _bannerIsMissingModel;
  bool get connecting => _connecting;
  bool get connected => _session != null;
  SessionMode get mode => _session?.mode ?? SessionMode.pushToTalk;
  String get languageTag => _locator.languageTag;

  bool get canTalk => _session != null && _locator.asr != null;

  Future<void> load() async {
    // The transcript is restored before any link exists, so a user who
    // reopens the app after a crash still has the last messages in front of
    // them even if they cannot reconnect yet.
    final List<StoredMessage> stored = await _locator.repository.recent();
    _messages
      ..clear()
      ..addAll(stored);
    notifyListeners();
  }

  /// Starts the single-device demo link.
  Future<void> startDemo() async {
    _connecting = true;
    notifyListeners();
    try {
      _bind(await _locator.attachLoopback());
    } finally {
      _connecting = false;
      notifyListeners();
    }
  }

  void _bind(SessionController session) {
    _events?.cancel();
    _session = session;
    _events = session.events.listen(_onEvent);
  }

  void _onEvent(SessionEvent event) {
    switch (event) {
      case SessionLevel(rmsDbfs: final double db, isSpeech: final bool speech):
        // dBFS mapped to 0..1 over a 45 dB window: below -45 dBFS there is
        // nothing a user needs to see, and above -5 the meter would pin.
        _level = ((db + 45) / 40).clamp(0.0, 1.0);
        _speechDetected = speech;
        notifyListeners();
      case SessionMessageStored(message: final StoredMessage message):
        _messages.insert(0, message);
        notifyListeners();
      case SessionMessageUpdated(id: final String id, state: final DeliveryState state):
        final int index =
            _messages.indexWhere((StoredMessage m) => m.id == id);
        if (index >= 0) {
          _messages[index] = _messages[index].copyWith(state: state);
          notifyListeners();
        }
      case SessionError(
          message: final String message,
          isMissingModel: final bool missing,
        ):
        _banner = message;
        _bannerIsMissingModel = missing;
        notifyListeners();
      case SessionAlert():
        // The alert controller handles announcing it; the transcript entry
        // arrives as a separate stored event.
        break;
    }
  }

  Future<void> pressTalk() async {
    final SessionController? session = _session;
    if (session == null) return;
    await session.pressTalk();
    _talking = session.isTalking;
    notifyListeners();
  }

  Future<void> releaseTalk() async {
    final SessionController? session = _session;
    if (session == null) return;
    await session.releaseTalk();
    _talking = false;
    _level = 0;
    notifyListeners();
  }

  Future<void> setMode(SessionMode mode) async {
    _session?.setMode(mode);
    notifyListeners();
  }

  Future<void> raiseAlert(String text) async {
    await _session?.raiseAlert(text: text);
  }

  Future<void> sendTyped(String text) async {
    if (text.trim().isEmpty) return;
    await _session?.sendTypedText(text.trim());
  }

  Future<void> silenceAlerts() async {
    await _locator.alerts?.silence();
  }

  Future<void> setLanguage(String tag) async {
    await _locator.setLanguageTag(tag);
    // Warm the models for the new language now rather than on the next
    // press, so switching language does not cost a second of silence at the
    // worst possible moment.
    await _locator.asr?.warmUp(tag);
    await _locator.tts?.warmUp(tag);
    notifyListeners();
  }

  void dismissBanner() {
    _banner = null;
    _bannerIsMissingModel = false;
    notifyListeners();
  }

  Future<void> clearHistory() async {
    await _locator.repository.clear();
    _messages.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }
}
