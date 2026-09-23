import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/audio/playback_controller.dart';
import '../core/cloud/cloud_speech_config.dart';
import '../core/metrics/metrics.dart';
import '../core/models/engine_sources.dart';
import '../core/models/model_pack.dart';
import '../core/models/pack_installer.dart';
import '../core/platform/platform_capabilities.dart';
import '../core/protocol/capabilities.dart';
import '../core/protocol/message.dart';
import '../core/session/alert_controller.dart';
import '../core/session/session_controller.dart';
import '../core/session/session_launcher.dart';
import '../core/storage/entities.dart';
import '../core/transport/transport_adapter.dart';
import '../core/tts/tts_engine.dart';
import '../core/util/async.dart';
import '../di/service_locator.dart';
import 'haptics.dart';
import 'languages.dart';
import 'widgets/ptt_button.dart';

/// A banner shown across the top of the conversation screen.
///
/// [severity] picks the colour, but the banner also always carries an icon and
/// a close button, so colour is never the only signal that something is wrong.
class AppBanner {
  const AppBanner(
    this.message, {
    this.severity = BannerSeverity.info,
    this.actionLabel,
    this.action,
  });

  final String message;
  final BannerSeverity severity;
  final String? actionLabel;
  final Future<void> Function()? action;
}

enum BannerSeverity { info, warning, error, missingPack }

/// Everything the UI reads, in one place.
///
/// A plain [ChangeNotifier] rather than a state-management package. The app has
/// one source of truth per concern - the launcher's state stream and the
/// session's event stream - and a handful of derived getters. Introducing a
/// framework here would add concepts without removing any, and it keeps the
/// dependency list - which is scored as app size - shorter.
class AppController extends ChangeNotifier {
  AppController(this._locator) {
    _launchSub = _locator.launcher.states.listen(_onLaunchState);
    _themeMode = _locator.themeMode;
    _alertsArmed = _locator.alertsArmed;
    // Pushed into the palette module once, so the haptics helper stays free of
    // any dependency on the object graph and can be called from anywhere.
    Haptics.enabled = _locator.hapticsEnabled;
  }

  final ServiceLocator _locator;

  StreamSubscription<LaunchState>? _launchSub;
  StreamSubscription<SessionEvent>? _sessionSub;

  // -- launch ---------------------------------------------------------------

  LaunchState _launch = const LaunchIdle();
  LaunchState get launch => _launch;

  SessionController? get session => _locator.launcher.session;
  bool get isLive => _launch is LaunchLive;

  SessionMode get mode => session?.mode ?? _mode;
  SessionMode _mode = SessionMode.pushToTalk;

  String get linkLabel => switch (_launch) {
        LaunchLive(linkLabel: final String label) => label,
        LaunchAwaitingVerification(linkLabel: final String label) => label,
        LaunchConnecting(label: final String label) => label,
        _ => 'No link',
      };

  bool get isEncrypted => switch (_launch) {
        LaunchLive(encrypted: final bool encrypted) => encrypted,
        _ => false,
      };

  /// True only for the in-process demonstration, so the UI can say so plainly
  /// rather than implying a second device is involved.
  bool get isDemo => _launch is LaunchLive &&
      (_launch as LaunchLive).spec.kind == TransportKind.loopback;

  ConnectionSpec? get spec => switch (_launch) {
        LaunchLive(spec: final ConnectionSpec spec) => spec,
        _ => _locator.launcher.spec,
      };

  // -- transcript -----------------------------------------------------------

  final List<StoredMessage> _messages = <StoredMessage>[];
  List<StoredMessage> get messages => List<StoredMessage>.unmodifiable(_messages);

  /// The most recent thing that was said, either way, for the "repeat" action.
  StoredMessage? get lastMessage => _messages.isEmpty ? null : _messages.first;

  // -- live input -----------------------------------------------------------

  double _level = 0;
  bool _speechDetected = false;
  bool _talking = false;
  bool _recognising = false;

  double get level => _level;
  bool get speechDetected => _speechDetected;
  bool get talking => _talking;

  // -- banner ---------------------------------------------------------------

  AppBanner? _banner;
  AppBanner? get banner => _banner;

  /// A short, transient note shown as a snack bar rather than as a banner.
  String? _toast;

  String? consumeToast() {
    final String? value = _toast;
    _toast = null;
    return value;
  }

  // -- preferences ----------------------------------------------------------

  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;

  bool _alertsArmed = false;
  bool get alertsArmed => _alertsArmed;

  bool get hapticsEnabled => _locator.hapticsEnabled;

  String get languageTag => _locator.languageTag;

  bool get onboarded => _locator.onboarded;

  SpeedProfile get speedProfile => _locator.speedProfile;

  String get displayName => _locator.displayName;

  bool get hasRecognition => _locator.asr != null;
  bool get hasVoice => _locator.tts != null;

  PlatformCapabilities get capabilities => _locator.capabilities;

  /// Live counters and percentiles for the diagnostics screen.
  MetricsCollector get metrics => _locator.metrics;

  /// Metric names that have at least one stored sample, across all runs.
  Future<List<String>> recordedMetrics() => _locator.repository.recordedMetrics();

  /// Percentiles for one metric, over every run stored on this phone.
  Future<LatencySummary> storedPercentiles(String metric) =>
      _locator.repository.percentiles(metric);

  /// Current output volume, 0..1, or null where the platform does not report
  /// it. Shown in diagnostics so a demo can prove the phone is loud enough for
  /// alerts instead of asserting it.
  Future<double?> outputVolume() => _locator.platformInfo.outputVolume();

  /// A human label for the live link, including the transport and whether it
  /// ended up encrypted.
  String get linkDetail {
    final String transport =
        _locator.launcher.transport?.descriptor.label ?? 'none';
    return isEncrypted ? '$transport · encrypted' : '$transport · plaintext';
  }

  // -- speech sources ---------------------------------------------------------

  /// Where recognition happens, and where the voice comes from. Both are
  /// exposed because the conversation screen has to be able to say which is in
  /// use without the user going looking for it.
  RecognitionSource get recognitionSource => _locator.recognitionSource;
  VoiceSource get voiceSource => _locator.voiceSource;
  CloudSpeechConfig get cloudConfig => _locator.cloudSpeechConfig;
  PackInstaller get installer => _locator.installer;

  bool get deviceVoiceAvailable => _locator.deviceVoiceAvailable;
  Set<String> get deviceVoiceLanguages =>
      _locator.deviceVoice.installedLanguages;

  /// True when the transcript on screen was not recognised from speech at all.
  /// Drives a permanent, unmissable marker on the conversation screen.
  bool get isSimulatedRecognition =>
      recognitionSource == RecognitionSource.simulated;

  /// True when holding the talk button sends audio off this phone.
  bool get recognitionLeavesDevice => recognitionSource.leavesDevice;
  bool get voiceLeavesDevice => voiceSource.leavesDevice;

  /// True when the selected recognition source is live but unrunnable, so the
  /// UI can point at the one thing that is missing.
  bool get recognitionNeedsSetup =>
      recognitionSource.needsSetup && !hasRecognition;

  bool get voiceNeedsSetup =>
      !hasVoice && voiceSource != VoiceSource.none;

  Future<void> setRecognitionSource(RecognitionSource source) async {
    await _locator.setRecognitionSource(source);
    _banner = switch (source) {
      RecognitionSource.simulated => const AppBanner(
          'Demonstration mode: the text on screen is a fixed example, not your '
          'speech. Link, storage and playback are real.',
          severity: BannerSeverity.warning,
        ),
      RecognitionSource.cloud => AppBanner(
          'Cloud recognition is on. Audio from the microphone is sent to '
          '${cloudConfig.host} while you hold the talk button.',
          severity: BannerSeverity.info,
        ),
      RecognitionSource.packs => null,
    };
    notifyListeners();
  }

  Future<void> setVoiceSource(VoiceSource source) async {
    await _locator.setVoiceSource(source);
    // Probing again here rather than only at startup: the most common reason
    // the device voice reports nothing is that its data has not been
    // downloaded yet, and the user may well have just gone and installed it.
    if (source == VoiceSource.device) await _locator.probeDeviceVoice();
    notifyListeners();
  }

  Future<void> setCloudConfig(CloudSpeechConfig config) async {
    await _locator.setCloudSpeechConfig(config);
    notifyListeners();
  }

  Future<Set<String>> probeDeviceVoice() async {
    final Set<String> languages = await _locator.probeDeviceVoice();
    notifyListeners();
    return languages;
  }

  Future<PackInstallResult> installPack({
    required Uri modelUrl,
    required String languageTag,
    required PackRole role,
    Map<String, Uri> auxiliary = const <String, Uri>{},
    String? licence,
    String? notes,
    int? sampleRateHz,
    bool redistributable = true,
    void Function(PackInstallProgress)? onProgress,
  }) async {
    final PackInstallResult result = await installer.fetch(
      modelUrl: modelUrl,
      languageTag: languageTag,
      role: role,
      auxiliary: auxiliary,
      licence: licence,
      notes: notes,
      sampleRateHz: sampleRateHz,
      redistributable: redistributable,
      onProgress: onProgress,
    );
    await _afterPackChange();
    return result;
  }

  Future<PackInstallResult> importPack({
    required String modelPath,
    required String languageTag,
    required PackRole role,
    String? vocabularyPath,
    String? licence,
    String? notes,
    int? sampleRateHz,
    void Function(PackInstallProgress)? onProgress,
  }) async {
    final PackInstallResult result = await installer.import(
      modelPath: modelPath,
      languageTag: languageTag,
      role: role,
      vocabularyPath: vocabularyPath,
      licence: licence,
      notes: notes,
      sampleRateHz: sampleRateHz,
      onProgress: onProgress,
    );
    await _afterPackChange();
    return result;
  }

  Future<void> removePack(ModelPack pack) async {
    await installer.remove(pack);
    await _afterPackChange();
  }

  /// Rescans, then rebuilds the engines so a pack that was just installed is
  /// usable immediately - including switching the source back to the
  /// on-device model if the user was waiting on a download to finish.
  Future<void> _afterPackChange() async {
    await _locator.refreshEngines();
    notifyListeners();
  }

  List<ModelPack> get installedPacks => _locator.packs.packs;

  int get asrCount => installedPacks
      .where((ModelPack pack) => pack.role == PackRole.asr)
      .length;

  int get ttsCount => installedPacks
      .where((ModelPack pack) => pack.role == PackRole.tts)
      .length;

  int get packBytes => _locator.packs.totalBytes;

  List<String> get packProblems => _locator.packs.problems;

  /// Languages where this phone has both halves of the loop, so the picker can
  /// show a tick rather than a language that will fail on the first press.
  Set<String> get readyLanguages =>
      recognizableLanguages.intersection(speakableLanguages);

  // -- derived ---------------------------------------------------------------

  /// What the talk button should look like right now.
  TalkState get talkState {
    if (_recognising) return TalkState.finishing;
    if (_talking) return TalkState.talking;

    final LaunchState launch = _launch;
    if (launch is LaunchFailed) return TalkState.offline;
    if (launch is LaunchConnecting ||
        launch is LaunchAwaitingVerification) {
      return TalkState.preparing;
    }
    if (launch is! LaunchLive) return TalkState.offline;

    if (!_locator.launcher.floor.canCaptureLocally) {
      return TalkState.blocked;
    }
    // A live link with no recognition pack is still useful - typed messages
    // and alerts work - but the microphone path is not. This is its own state
    // rather than "preparing", because it is not going to resolve itself: the
    // user has to install a model, and a button that just sits there looking
    // busy is the single most confusing thing this screen could do.
    if (!hasRecognition) return TalkState.setupNeeded;
    return TalkState.ready;
  }

  /// True when the microphone path is blocked by something the user has to fix
  /// - a missing model, or a cloud source with no key. The UI offers exactly
  /// the one action that resolves it.
  bool get needsRecognitionPack => isLive && !hasRecognition;

  /// What to tell the user when the talk button will not work, named for the
  /// selected source rather than assuming a pack is what is missing.
  String? get blockedReason => switch (talkState) {
        TalkState.blocked => 'The other phone is talking',
        TalkState.setupNeeded => switch (recognitionSource) {
            RecognitionSource.cloud =>
              'Cloud recognition needs an endpoint and a key',
            RecognitionSource.simulated => 'Recognition is switched off',
            RecognitionSource.packs => 'No recognition model on this phone yet',
          },
        _ => null,
      };

  bool get canSendTyped => isLive;
  bool get canAlert => isLive;

  DeviceCapabilities? get peerCapabilities => switch (_launch) {
        LaunchLive(peerCapabilities: final DeviceCapabilities? caps) => caps,
        LaunchAwaitingVerification(
          peerCapabilities: final DeviceCapabilities? caps
        ) =>
          caps,
        _ => null,
      };

  String? get peerLabel => switch (_launch) {
        LaunchLive(peerLabel: final String? label) => label,
        LaunchAwaitingVerification(peerLabel: final String? label) => label,
        _ => null,
      };

  CoverageReport coverage(String tag) =>
      _locator.coverageFor(tag, peerCapabilities);

  /// Languages worth offering in the picker.
  ///
  /// Derived from the selected sources rather than from the packs on disk: with
  /// the device voice or a cloud engine in play, a phone with no packs at all
  /// can still hold a conversation, and a picker that only listed installed
  /// packs would hide the languages the user can actually use.
  List<LanguageSpec> get installedLanguages {
    final Set<String> usable =
        recognizableLanguages.intersection(speakableLanguages);
    return Languages.all
        .where((LanguageSpec spec) => usable.contains(spec.tag))
        .toList(growable: false);
  }

  /// Languages the selected recognition source can handle.
  Set<String> get recognizableLanguages => switch (recognitionSource) {
        RecognitionSource.packs => _packLanguages(PackRole.asr),
        RecognitionSource.cloud => cloudConfig.canTranscribe
            ? CloudSpeechConfig.languages
            : const <String>{},
        // The demonstration can be run in any language the app offers, because
        // it is not listening to any of them.
        RecognitionSource.simulated => Languages.all
            .map((LanguageSpec spec) => spec.tag)
            .toSet(),
      };

  /// Languages the selected voice can speak.
  Set<String> get speakableLanguages => switch (voiceSource) {
        VoiceSource.packs => _packLanguages(PackRole.tts),
        // An unprobed device voice is treated as capable: the platform has not
        // been asked yet, and hiding every language until it answers would be
        // worse than offering one that turns out to need a download.
        VoiceSource.device => deviceVoiceLanguages.isEmpty
            ? Languages.all.map((LanguageSpec spec) => spec.tag).toSet()
            : deviceVoiceLanguages,
        VoiceSource.cloud => cloudConfig.canSynthesize
            ? CloudSpeechConfig.languages
            : const <String>{},
        VoiceSource.none => const <String>{},
      };

  Set<String> _packLanguages(PackRole role) => _locator.packs.packs
      .where((ModelPack pack) => pack.role == role)
      .map((ModelPack pack) => pack.languageTag)
      .toSet();

  /// Estimated time for one sentence of [characters] characters over the
  /// current link. Shown before a long message is committed, so queue delay is
  /// never a surprise at the far end.
  int estimatedMillisForMessage(int characters) {
    final SpeedProfile profile = speedProfile;
    // Roughly 2.9 UTF-8 bytes per character for these scripts, plus the
    // protocol envelope.
    final int bytes = 90 + (characters * 3);
    return profile.estimatedMillisFor(bytes);
  }

  // -- lifecycle -------------------------------------------------------------

  Future<void> load() async {
    _messages
      ..clear()
      ..addAll(await _locator.history());
    notifyListeners();
  }

  void _onLaunchState(LaunchState state) {
    _launch = state;

    switch (state) {
      case LaunchLive(session: final SessionController session):
        _bindSession(session);
        _mode = session.mode;
        _banner = null;
      case LaunchFailed(message: final String message, retryable: final bool retryable):
        _unbindSession();
        _talking = false;
        _level = 0;
        _banner = AppBanner(
          message,
          severity: BannerSeverity.error,
          actionLabel: retryable ? 'Retry' : null,
          action: retryable && _lastSpec != null
              ? () => connect(_lastSpec!)
              : null,
        );
      case LaunchAwaitingVerification():
        _banner = null;
      case LaunchConnecting():
        _talking = false;
      case LaunchIdle():
        _unbindSession();
        _talking = false;
        _level = 0;
    }

    notifyListeners();
  }

  void _bindSession(SessionController session) {
    unawaited(_sessionSub?.cancel());
    _sessionSub = session.events.listen(_onSessionEvent);
  }

  void _unbindSession() {
    unawaited(_sessionSub?.cancel());
    _sessionSub = null;
  }

  void _onSessionEvent(SessionEvent event) {
    switch (event) {
      case SessionLevel(rmsDbfs: final double db, isSpeech: final bool speech):
        // dBFS mapped to 0..1 over a 45 dB window: below -45 dBFS there is
        // nothing a user needs to see, and above -5 the meter would pin.
        _level = ((db + 45) / 40).clamp(0.0, 1.0);
        _speechDetected = speech;
        notifyListeners();

      case SessionMessageStored(message: final StoredMessage message):
        _messages.insert(0, message);
        // An incoming message has been stored here, which is the one moment
        // "delivered" is true for it. Felt rather than read, because the phone
        // is usually not being looked at.
        if (message.direction == MessageDirection.incoming) {
          Haptics.fireAndForget(Haptic.delivered);
        }
        notifyListeners();

      case SessionMessageUpdated(
          id: final String id,
          state: final DeliveryState state
        ):
        final int index =
            _messages.indexWhere((StoredMessage m) => m.id == id);
        if (index >= 0) {
          final DeliveryState previous = _messages[index].state;
          _messages[index] = _messages[index].copyWith(state: state);
          // Only on a change: the same state can be reported more than once,
          // and a repeated buzz reads as a different event.
          if (previous != state) _announceHapticFor(state);
          notifyListeners();
        }

      case SessionError(
          message: final String message,
          isMissingModel: final bool missing
        ):
        _banner = AppBanner(
          message,
          severity: missing ? BannerSeverity.missingPack : BannerSeverity.error,
        );
        Haptics.fireAndForget(Haptic.failure);
        notifyListeners();

      case SessionBusy(isRecognising: final bool busy):
        _recognising = busy;
        notifyListeners();

      case SessionNoSpeech():
        // Not an error and not worth a banner, but silence has to be
        // acknowledged or the user will keep holding the button down, and the
        // acknowledgement has to work without looking at the screen.
        _toast = 'Nothing was recognised — try again, a little closer';
        Haptics.fireAndForget(Haptic.failure);
        notifyListeners();

      case SessionAlert(alert: final AlertMessage alert):
        // Announcing is the alert controller's job; the transcript row arrives
        // separately as a stored message. The vibration belongs here, because
        // this is the event that means a distress message actually arrived.
        Haptics.fireAndForget(
          alert.severity == AlertSeverity.distress
              ? Haptic.alert
              : Haptic.warning,
        );
    }
  }

  /// Maps a delivery state onto the haptic vocabulary.
  void _announceHapticFor(DeliveryState state) {
    switch (state) {
      case DeliveryState.sent:
        Haptics.fireAndForget(Haptic.sent);
      case DeliveryState.delivered:
      case DeliveryState.played:
        Haptics.fireAndForget(Haptic.delivered);
      case DeliveryState.failed:
        Haptics.fireAndForget(Haptic.failure);
      case DeliveryState.pending:
        // Nothing to report: the user has just acted and already felt it.
        break;
    }
  }

  // -- actions ---------------------------------------------------------------

  ConnectionSpec? _lastSpec;

  /// The link used most recently, so the home screen can offer "reconnect"
  /// without the user re-entering an address they already typed once.
  ConnectionSpec? get lastConnection => _locator.lastConnection;

  Future<void> connect(ConnectionSpec spec) async {
    _lastSpec = spec;
    await _locator.launcher.connect(spec);
    if (_locator.launcher.state is LaunchLive) {
      await _locator.rememberConnection(spec);
    }
  }

  Future<void> startDemo() => connect(ConnectionSpec.demo);

  Future<void> reconnectLast() async {
    final ConnectionSpec? last = _locator.lastConnection;
    if (last == null) {
      await startDemo();
      return;
    }
    await connect(last);
  }

  Future<void> disconnect() async {
    await _locator.launcher.disconnect();
    _talking = false;
    _level = 0;
    _banner = null;
    notifyListeners();
  }

  Future<void> confirmVerification() async {
    _toast = 'Link verified and encrypted';
    await _locator.launcher.confirmVerification();
  }

  Future<void> rejectVerification() => _locator.launcher.rejectVerification();

  Future<void> pressTalk() async {
    final SessionController? active = session;
    if (active == null) return;
    await active.pressTalk();
    _talking = active.isTalking;
    notifyListeners();
  }

  Future<void> releaseTalk() async {
    final SessionController? active = session;
    if (active == null) return;
    await active.releaseTalk();
    _talking = false;
    _level = 0;
    notifyListeners();
  }

  Future<void> setMode(SessionMode next) async {
    _mode = next;
    session?.setMode(next);
    notifyListeners();
  }

  Future<void> sendTyped(String text) async {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return;
    await _locator.launcher.sendTyped(trimmed);
  }

  Future<void> raiseAlert(
    String text, {
    AlertSeverity severity = AlertSeverity.distress,
  }) async {
    await _locator.launcher.raiseAlert(text, severity: severity);
  }

  Future<void> silenceAlerts() async {
    await _locator.alerts?.silence();
    _toast = 'Alerts silenced';
    notifyListeners();
  }

  /// Play a stored message again, locally. Used by the replay affordance on a
  /// received bubble: a message that arrived while the phone was in a pocket
  /// has to be hearable without asking the other person to repeat themselves.
  Future<void> replay(StoredMessage message) async {
    final TtsEngine? engine = _locator.tts;
    if (engine == null) {
      _toast = 'No voice pack installed for ${message.languageTag}';
      notifyListeners();
      return;
    }

    if (message.isAlert) {
      await _locator.alerts?.announce(AlertMessage(
        messageId: message.id,
        senderId: message.peerId ?? 'peer',
        languageTag: message.languageTag,
        text: message.text,
        severity: (message.severity ?? '').toLowerCase() == 'distress'
            ? AlertSeverity.distress
            : AlertSeverity.warning,
        repeatCount: 1,
      ));
      return;
    }

    try {
      await _locator.playback.play(
        chunks: engine
            .synthesize(SynthesisRequest(
              text: message.text,
              languageTag: message.languageTag,
            ))
            .map((SynthesisChunk chunk) => PcmChunk(
                  samples: chunk.samples,
                  sampleRateHz: chunk.sampleRateHz,
                  isLast: chunk.isLast,
                )),
      );
    } on TtsException catch (error) {
      _toast = error.message;
      notifyListeners();
    }
  }

  Future<void> retry(StoredMessage message) async {
    if (message.direction != MessageDirection.outgoing) return;
    await sendTyped(message.text);
  }

  Future<void> setLanguage(String tag) async {
    await _locator.setLanguageTag(tag);
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    await _locator.setThemeMode(mode);
    notifyListeners();
  }

  Future<void> setAlertsArmed(bool armed) async {
    _alertsArmed = armed;
    await _locator.setAlertsArmed(armed);
    notifyListeners();
  }

  Future<void> setHapticsEnabled(bool enabled) async {
    Haptics.enabled = enabled;
    await _locator.setHapticsEnabled(enabled);
    // Felt immediately, so the switch proves itself instead of merely
    // changing a stored value.
    if (enabled) Haptics.fireAndForget(Haptic.delivered);
    notifyListeners();
  }

  Future<void> setSpeedProfile(SpeedProfile profile) async {
    await _locator.setSpeedProfile(profile);
    notifyListeners();
  }

  Future<void> setDisplayName(String name) async {
    await _locator.setDisplayName(name);
    notifyListeners();
  }

  Future<void> completeOnboarding() async {
    await _locator.completeOnboarding();
    notifyListeners();
  }

  /// Replays the introduction, including the alert-consent and permission
  /// steps, on the next build.
  Future<void> replayIntro() async {
    await _locator.resetOnboarding();
    notifyListeners();
  }

  /// Plays a short alert through the real alert path.
  ///
  /// The onboarding screen offers this before the user arms loud alerts, and
  /// the settings screen offers it again. Hearing the volume and the way the
  /// app takes audio focus is the only honest way to decide whether alerts are
  /// reliable on a given phone - and a claim about loudness that a user cannot
  /// test is not a claim worth making.
  Future<void> testAlertTone() async {
    final AlertController? alerts = _locator.alerts;
    if (alerts == null) {
      // No live session, so there is no alert controller. A standalone test
      // still has to produce sound or the user learns nothing, so it goes
      // through the ordinary playback path with an alarm-grade priority.
      await _playStandaloneTestAlert();
      return;
    }

    await alerts.announce(
      AlertMessage(
        messageId: 'test-alert',
        senderId: 'self',
        languageTag: languageTag,
        text: 'This is a test alert. Alerts sound like this.',
        severity: AlertSeverity.warning,
        repeatCount: 1,
      ),
    );
  }

  Future<void> _playStandaloneTestAlert() async {
    final TtsEngine? engine = _locator.tts;
    if (engine == null) {
      _toast = 'Install a voice pack to hear a test alert';
      notifyListeners();
      return;
    }
    try {
      await _locator.playback.play(
        priority: PlaybackPriority.warning,
        chunks: engine
            .synthesize(SynthesisRequest(
              text: 'This is a test alert. Alerts sound like this.',
              languageTag: languageTag,
              speakingRate: AlertController.alertSpeakingRate,
              isAlert: true,
            ))
            .map((SynthesisChunk chunk) => PcmChunk(
                  samples: chunk.samples,
                  sampleRateHz: chunk.sampleRateHz,
                  isLast: chunk.isLast,
                )),
      );
    } on TtsException catch (error) {
      _toast = error.message;
      notifyListeners();
    }
  }

  /// Where packs are expected to live, resolved from the same manager that
  /// scans them so the two can never disagree.
  Future<Directory> packsDirectory() => _locator.packs.root();

  /// Full checksum verification of every installed pack.
  ///
  /// Deliberately slow - it hashes hundreds of megabytes - so it is only ever
  /// triggered by an explicit press on the packs screen. A pack that fails here
  /// would otherwise surface as garbled speech rather than as an error.
  Future<Map<String, bool>> verifyPacks() async {
    await _locator.packs.refresh();
    final Map<String, bool> result = await _locator.packs.verify();
    notifyListeners();
    return result;
  }

  /// Rescans the pack directory, rebuilding the engines when coverage changed.
  Future<PackRefreshResult> refreshPacks() async {
    final PackRefreshResult result = await _locator.refreshPacks();
    if (result.changed) {
      _toast = 'Language packs reloaded';
      notifyListeners();
    }
    return result;
  }

  Future<void> clearHistory() async {
    await _locator.clearHistory();
    _messages.clear();
    notifyListeners();
  }

  void dismissBanner() {
    _banner = null;
    notifyListeners();
  }

  /// Called by the onboarding flow, so the pack screen and the conversation
  /// screen agree on what was installed before the first message.
  void clearToast() {
    _toast = null;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_launchSub?.cancel());
    unawaited(_sessionSub?.cancel());
    super.dispose();
  }
}
