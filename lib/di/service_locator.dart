import 'dart:math';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/asr/asr_engine.dart';
import '../core/asr/onnx_ctc_asr_engine.dart';
import '../core/asr/simulated_asr_engine.dart';
import '../core/audio/capture_engine.dart';
import '../core/audio/playback_controller.dart';
import '../core/cloud/cloud_asr_engine.dart';
import '../core/cloud/cloud_client.dart';
import '../core/cloud/cloud_speech_config.dart';
import '../core/cloud/cloud_tts_engine.dart';
import '../core/metrics/metrics.dart';
import '../core/models/engine_sources.dart';
import '../core/models/model_pack.dart';
import '../core/models/model_pack_manager.dart';
import '../core/models/pack_installer.dart';
import '../core/platform/platform_capabilities.dart';
import '../core/protocol/capabilities.dart';
import '../core/session/alert_controller.dart';
import '../core/session/floor_controller.dart';
import '../core/session/session_controller.dart';
import '../core/session/session_launcher.dart';
import '../core/storage/database.dart';
import '../core/storage/entities.dart';
import '../core/storage/message_repository.dart';
import '../core/transport/transport_adapter.dart';
import '../core/tts/onnx_vits_tts_engine.dart';
import '../core/tts/system_tts_engine.dart';
import '../core/tts/tts_engine.dart';
import '../core/util/async.dart';
import '../core/util/log.dart';

/// Wires the object graph.
///
/// Hand-written rather than a DI package: the graph is small, the wiring is
/// read once, and an explicit constructor chain is the clearest possible
/// statement of what depends on what. It also makes substitution in tests
/// obvious - build the same graph over a loopback transport.
class ServiceLocator {
  ServiceLocator._({
    required this.preferences,
    required this.packs,
    required this.metrics,
    required this.repository,
    required this.capture,
    required this.playback,
    required this.floor,
    required this.platformInfo,
    required this.capabilities,
    required this.launcher,
    required this.deviceId,
    required this.installer,
  });

  static ServiceLocator? _instance;

  static ServiceLocator get instance {
    final ServiceLocator? existing = _instance;
    if (existing == null) {
      throw StateError('ServiceLocator.bootstrap() has not run');
    }
    return existing;
  }

  final SharedPreferences preferences;
  final ModelPackManager packs;
  final MetricsCollector metrics;
  final MessageRepository repository;
  final CaptureEngine capture;
  final PlaybackController playback;
  final FloorController floor;

  /// Host capability probe. Consulted rather than checking `Platform.isIOS`
  /// inline, so a limitation is reported once and surfaced honestly in the UI -
  /// notably alert loudness, which iOS cannot guarantee.
  final PlatformInfo platformInfo;
  final PlatformCapabilities capabilities;

  /// Owns the link, the handshake and the live session.
  final SessionLauncher launcher;

  final String deviceId;

  /// Fetches, imports and removes model packs. The only thing in the app that
  /// opens an outbound connection, and only when a person asks it to.
  final PackInstaller installer;

  AsrEngine? _asr;
  TtsEngine? _tts;

  /// Created once and kept across rebuilds: the platform synthesiser is a
  /// process-wide engine whose language data does not change with the app's
  /// settings, so recreating it on every switch would only lose the probe
  /// result and pay the start-up cost again.
  late final SystemTtsEngine _deviceVoice = SystemTtsEngine(metrics: metrics);

  /// Shared by both cloud engines, and reads the configuration lazily so a key
  /// entered in settings applies to the next utterance.
  late final CloudClient cloudClient =
      CloudClient(config: () => cloudSpeechConfig);

  /// Null when the selected source cannot run. Null rather than a throwing
  /// stub, so the UI can render a "this needs setup" state instead of an error
  /// every time a button is touched.
  AsrEngine? get asr => _asr;
  TtsEngine? get tts => _tts;

  /// The platform synthesiser, whether or not it is the selected source, so
  /// the settings screen can report what this phone has.
  SystemTtsEngine get deviceVoice => _deviceVoice;

  bool get deviceVoiceAvailable => _deviceVoice.isAvailable;

  /// Asks the platform which of the app's languages have voice data installed.
  ///
  /// Worth doing at startup and again after the user returns from the system
  /// settings: voice data is downloaded outside this app, and a stale answer
  /// here is the difference between offering the device voice and hiding it.
  Future<Set<String>> probeDeviceVoice() async {
    await _deviceVoice.probe(
      candidates: CloudSpeechConfig.languages.toList(growable: false),
    );
    return _deviceVoice.installedLanguages;
  }

  AlertController? get alerts => launcher.alerts;
  SessionController? get session => launcher.session;

  // ---------------------------------------------------------------------------
  // Persisted preferences
  // ---------------------------------------------------------------------------

  static const String _deviceIdKey = 'device_id';
  static const String _languageKey = 'language_tag';
  static const String _themeKey = 'theme_mode';
  static const String _onboardedKey = 'onboarded_v1';
  static const String _alertArmedKey = 'alert_armed';
  static const String _nameKey = 'display_name';
  static const String _lastKindKey = 'last_transport_kind';
  static const String _lastRoleKey = 'last_transport_role';
  static const String _lastAddressKey = 'last_transport_address';
  static const String _speedKey = 'speed_profile';
  static const String _hapticsKey = 'haptics_enabled';
  static const String _asrSourceKey = 'recognition_source';
  static const String _voiceSourceKey = 'voice_source';
  static const String _cloudKey = 'cloud_speech_config';

  // ---------------------------------------------------------------------------
  // Speech engines
  // ---------------------------------------------------------------------------

  RecognitionSource get recognitionSource =>
      RecognitionSource.fromCode(preferences.getString(_asrSourceKey));

  VoiceSource get voiceSource =>
      VoiceSource.fromCode(preferences.getString(_voiceSourceKey));

  CloudSpeechConfig get cloudSpeechConfig =>
      CloudSpeechConfig.decode(preferences.getString(_cloudKey));

  Future<void> setRecognitionSource(RecognitionSource source) async {
    await preferences.setString(_asrSourceKey, source.code);
    await _rebuildEngines();
  }

  Future<void> setVoiceSource(VoiceSource source) async {
    await preferences.setString(_voiceSourceKey, source.code);
    await _rebuildEngines();
  }

  Future<void> setCloudSpeechConfig(CloudSpeechConfig config) async {
    await preferences.setString(_cloudKey, config.encode());
    await _rebuildEngines();
  }

  String get languageTag => preferences.getString(_languageKey) ?? 'hi-IN';

  Future<void> setLanguageTag(String tag) async {
    await preferences.setString(_languageKey, tag);
    // Warm the models for the language the user is about to speak. Switching
    // language and then pressing talk would otherwise pay a model load at the
    // worst possible moment - a second of dead air after the button is held.
    unawaited(_warm(tag));
  }

  Future<void> _warm(String tag) async {
    try {
      await _asr?.warmUp(tag);
      await _tts?.warmUp(tag);
    } on Object catch (error) {
      // A missing pack is not an error worth surfacing here; the pack screen
      // reports coverage from the disk scan.
      ItLog.w('boot', 'warm-up for $tag skipped: $error');
    }
  }

  ThemeMode get themeMode => switch (preferences.getString(_themeKey)) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  Future<void> setThemeMode(ThemeMode mode) =>
      preferences.setString(_themeKey, mode.name);

  bool get onboarded => preferences.getBool(_onboardedKey) ?? false;

  Future<void> completeOnboarding() =>
      preferences.setBool(_onboardedKey, true);

  /// Sends the user back through the introduction. Offered from settings
  /// rather than hidden, because the introduction is where the alert-consent
  /// and permission steps live and a user who skipped past them needs a way
  /// back that is not "reinstall the app".
  Future<void> resetOnboarding() =>
      preferences.setBool(_onboardedKey, false);

  /// Whether the user has explicitly accepted loud, non-duckable alerts. The
  /// system prompt is deliberate: this app can raise the ringer volume to
  /// maximum, and doing that without consent would be indefensible.
  bool get alertsArmed => preferences.getBool(_alertArmedKey) ?? false;

  Future<void> setAlertsArmed(bool armed) =>
      preferences.setBool(_alertArmedKey, armed);

  String get displayName =>
      preferences.getString(_nameKey) ?? 'iTantra ${deviceId.substring(0, 4)}';

  Future<void> setDisplayName(String name) =>
      preferences.setString(_nameKey, name.trim());

  /// Whether each outcome should get its own vibration.
  ///
  /// On by default, because the brief asks for an audio-first user to be able
  /// to follow the app without reading it - but switchable, because a phone
  /// carried somewhere that being noticed is dangerous must be able to go
  /// silent without also giving up its alerts.
  bool get hapticsEnabled => preferences.getBool(_hapticsKey) ?? true;

  Future<void> setHapticsEnabled(bool enabled) =>
      preferences.setBool(_hapticsKey, enabled);

  SpeedProfile get speedProfile {
    final String? stored = preferences.getString(_speedKey);
    for (final SpeedProfile profile in SpeedProfile.values) {
      if (profile.name == stored) return profile;
    }
    return SpeedProfile.native;
  }

  Future<void> setSpeedProfile(SpeedProfile profile) =>
      preferences.setString(_speedKey, profile.name);

  /// The last link the user chose, offered as a one-tap reconnect.
  ConnectionSpec? get lastConnection {
    final String? kindName = preferences.getString(_lastKindKey);
    if (kindName == null) return null;
    for (final TransportKind kind in TransportKind.values) {
      if (kind.name != kindName) continue;
      return ConnectionSpec(
        kind: kind,
        isHost: preferences.getBool(_lastRoleKey) ?? true,
        address: preferences.getString(_lastAddressKey),
        speed: speedProfile,
      );
    }
    return null;
  }

  Future<void> rememberConnection(ConnectionSpec spec) async {
    await preferences.setString(_lastKindKey, spec.kind.name);
    await preferences.setBool(_lastRoleKey, spec.isHost);
    if (spec.address != null) {
      await preferences.setString(_lastAddressKey, spec.address!);
    }
    await preferences.setString(_speedKey, spec.speed.name);
  }

  // ---------------------------------------------------------------------------
  // Pack management
  // ---------------------------------------------------------------------------

  /// Re-reads the pack directory and rebuilds the engines when coverage
  /// changes. Called after an import or a delete, so the app never keeps
  /// offering a language whose pack has just been removed.
  Future<PackRefreshResult> refreshPacks() async {
    final int beforeAsr = packs.packs
        .where((ModelPack p) => p.role == PackRole.asr)
        .length;
    final int beforeTts = packs.packs
        .where((ModelPack p) => p.role == PackRole.tts)
        .length;

    await packs.refresh();

    final int afterAsr =
        packs.packs.where((ModelPack p) => p.role == PackRole.asr).length;
    final int afterTts =
        packs.packs.where((ModelPack p) => p.role == PackRole.tts).length;

    final bool changed = beforeAsr != afterAsr || beforeTts != afterTts;
    if (changed) await _rebuildEngines();

    return PackRefreshResult(
      total: packs.packs.length,
      asrLanguages: afterAsr,
      ttsLanguages: afterTts,
      changed: changed,
    );
  }

  /// Rebuilds the engine pair. Called after a pack is installed or removed, so
  /// a newly added language becomes usable without restarting the app.
  Future<void> refreshEngines() => _rebuildEngines();

  /// Rebuilds the engine pair for the currently selected sources.
  ///
  /// Public because a source change and a pack install both land here, and they
  /// have to leave the object graph in exactly one state. The device voice is
  /// deliberately not disposed: it is process-wide and still valid.
  Future<void> _rebuildEngines() async {
    final AsrEngine? previousAsr = _asr;
    final TtsEngine? previousTts = _tts;
    _asr = null;
    _tts = null;
    await previousAsr?.dispose();
    if (previousTts != null && !identical(previousTts, _deviceVoice)) {
      await previousTts.dispose();
    }

    _asr = _buildAsr();
    _tts = _buildTts();

    // The launcher reads engines through the holder, so it must be updated in
    // the same step or a live session would keep using the disposed pair.
    _engines.asr = _asr;
    _engines.tts = _tts;

    ItLog.i(
      'boot',
      'engines rebuilt: recognition=${_asr?.runtimeType}, '
          'voice=${_tts?.runtimeType}',
    );
    await _warm(languageTag);
  }

  AsrEngine? _buildAsr() {
    switch (recognitionSource) {
      case RecognitionSource.packs:
        final bool hasPack =
            packs.packs.any((ModelPack p) => p.role == PackRole.asr);
        return hasPack ? OnnxCtcAsrEngine(packs: packs, metrics: metrics) : null;
      case RecognitionSource.cloud:
        return cloudSpeechConfig.canTranscribe
            ? CloudAsrEngine(client: cloudClient, metrics: metrics)
            : null;
      case RecognitionSource.simulated:
        return SimulatedAsrEngine(metrics: metrics);
    }
  }

  TtsEngine? _buildTts() {
    switch (voiceSource) {
      case VoiceSource.packs:
        final bool hasPack =
            packs.packs.any((ModelPack p) => p.role == PackRole.tts);
        return hasPack ? OnnxVitsTtsEngine(packs: packs, metrics: metrics) : null;
      case VoiceSource.device:
        return _deviceVoice;
      case VoiceSource.cloud:
        return cloudSpeechConfig.canSynthesize
            ? CloudTtsEngine(client: cloudClient, metrics: metrics)
            : null;
      case VoiceSource.none:
        return null;
    }
  }

  /// Whether the full loop can run in [tag] on this device and on the peer.
  ///
  /// Answered from the selected sources, not from the packs on disk: with a
  /// cloud engine selected, a phone with no packs at all can still recognise
  /// and speak, and saying otherwise would send the user shopping for a model
  /// they do not need.
  CoverageReport coverageFor(String tag, DeviceCapabilities? peer) {
    final bool localAsr = switch (recognitionSource) {
      RecognitionSource.packs => packs.packFor(tag, PackRole.asr) != null,
      RecognitionSource.cloud => cloudSpeechConfig.canTranscribe,
      RecognitionSource.simulated => true,
    };
    final bool localTts = switch (voiceSource) {
      VoiceSource.packs => packs.packFor(tag, PackRole.tts) != null,
      // An unprobed device voice is assumed usable: reporting it as missing
      // before it has been asked would hide the option that most users want.
      VoiceSource.device => _deviceVoice.installedLanguages.isEmpty ||
          _deviceVoice.installedLanguages.contains(tag),
      VoiceSource.cloud => cloudSpeechConfig.canSynthesize,
      VoiceSource.none => false,
    };
    final bool peerTts = peer?.ttsLanguages.contains(tag) ?? true;
    return CoverageReport(
      canRecognise: localAsr,
      canSpeakLocally: localTts,
      peerCanSpeak: peerTts,
    );
  }

  // ---------------------------------------------------------------------------
  // History
  // ---------------------------------------------------------------------------

  Future<List<StoredMessage>> history({int limit = 300}) =>
      repository.recent(limit: limit);

  Future<void> clearHistory() => repository.clear();

  // ---------------------------------------------------------------------------
  // Bootstrap
  // ---------------------------------------------------------------------------

  static Future<ServiceLocator> bootstrap() async {
    final SharedPreferences preferences =
        await SharedPreferences.getInstance();

    // A stable per-install id. Not the Android id: that is device-scoped and
    // reading it needs a permission we do not want to justify.
    String deviceId = preferences.getString(_deviceIdKey) ?? '';
    if (deviceId.isEmpty) {
      final Random random = Random.secure();
      deviceId = List<String>.generate(
        3,
        (_) => random.nextInt(1 << 24).toRadixString(36),
      ).join();
      await preferences.setString(_deviceIdKey, deviceId);
    }

    final ModelPackManager packs = ModelPackManager();
    await packs.refresh();

    final PlatformInfo platformInfo = PlatformInfo();
    final PlatformCapabilities capabilities = await platformInfo.load();

    final MetricsCollector metrics = MetricsCollector();
    final ItantraDatabase database = await ItantraDatabase.open();
    final MessageRepository repository = MessageRepository(database);

    final bool hasAsr = packs.packs.any((ModelPack p) => p.role == PackRole.asr);
    final bool hasTts = packs.packs.any((ModelPack p) => p.role == PackRole.tts);

    ItLog.i(
      'boot',
      'packs: ${packs.packs.length}, asr=$hasAsr, tts=$hasTts, '
          'platform=${capabilities.platform}',
    );

    // Created once and shared. Two separate CaptureEngine instances would mean
    // the session streams audio through one while the UI reads the level off
    // the other, which is exactly the kind of bug that shows up as "the meter
    // works but nothing is ever sent".
    final CaptureEngine capture = CaptureEngine();
    final PlaybackController playback = PlaybackController();
    final FloorController floor = FloorController();

    final ServiceLocator locator = ServiceLocator._(
      preferences: preferences,
      packs: packs,
      metrics: metrics,
      repository: repository,
      capture: capture,
      playback: playback,
      floor: floor,
      platformInfo: platformInfo,
      capabilities: capabilities,
      launcher: SessionLauncher(
        packs: () => packs.packs,
        metrics: metrics,
        repository: repository,
        capture: capture,
        playback: playback,
        floor: floor,
        capabilities: capabilities,
        deviceId: () => deviceId,
        asr: () => _engines.asr,
        tts: () => _engines.tts,
        languageTag: () => preferences.getString(_languageKey) ?? 'hi-IN',
        displayName: () => preferences.getString(_nameKey) ??
            'iTantra ${deviceId.substring(0, 4)}',
      ),
      deviceId: deviceId,
      installer: PackInstaller(packs: packs),
    );

    _instance = locator;

    // The launcher is constructed before the locator exists and reaches back
    // through the holder for the engines, which are replaced wholesale when a
    // pack is installed, when a source is changed, or when the cloud
    // configuration is edited. Building them here - from the persisted sources
    // rather than inline - is what keeps the settings screen and the running
    // graph from ever disagreeing.
    await locator._rebuildEngines();

    // Asked before the first frame so the UI can offer the device voice, or
    // explain that this ROM has no voice data, rather than failing on the first
    // message it tries to speak.
    await locator.probeDeviceVoice();

    return locator;
  }

  Future<void> dispose() async {
    await launcher.dispose();
    await _asr?.dispose();
    await _tts?.dispose();
  }
}

/// Indirection so the launcher can pick up an engine that was replaced when a
/// pack was installed, without holding a stale reference to a disposed one.
final _EngineHolder _engines = _EngineHolder();

class _EngineHolder {
  AsrEngine? asr;
  TtsEngine? tts;
}

/// What a pack rescan found.
class PackRefreshResult {
  const PackRefreshResult({
    required this.total,
    required this.asrLanguages,
    required this.ttsLanguages,
    required this.changed,
  });

  final int total;
  final int asrLanguages;
  final int ttsLanguages;
  final bool changed;
}

/// What one language can do right now, on this phone and on the peer.
class CoverageReport {
  const CoverageReport({
    required this.canRecognise,
    required this.canSpeakLocally,
    required this.peerCanSpeak,
  });

  final bool canRecognise;
  final bool canSpeakLocally;
  final bool peerCanSpeak;

  bool get fullLoop => canRecognise && canSpeakLocally;
  bool get usable => canRecognise && peerCanSpeak;

  String describe() {
    if (canRecognise && canSpeakLocally && peerCanSpeak) {
      return 'Speak and listen';
    }
    // Source-neutral wording: with a cloud engine or the device voice selected
    // there may be no packs involved at all, and "no packs installed" would be
    // both wrong and a reason to go and install something unnecessary.
    if (!canRecognise && !canSpeakLocally) {
      return peerCanSpeak
          ? 'Nothing set up on this phone yet'
          : 'Nothing set up on either phone';
    }
    if (!canRecognise) return 'Listen only — nothing here can transcribe';
    if (!canSpeakLocally) return 'Speak only — nothing here can speak this';
    if (!peerCanSpeak) return 'Ready — the other phone has no voice for this';
    return 'Ready';
  }
}


