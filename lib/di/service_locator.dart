import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/asr/asr_engine.dart';
import '../core/asr/onnx_ctc_asr_engine.dart';
import '../core/audio/capture_engine.dart';
import '../core/audio/playback_controller.dart';
import '../core/metrics/metrics.dart';
import '../core/models/model_pack_manager.dart';
import '../core/platform/platform_capabilities.dart';
import '../core/security/session_crypto.dart';
import '../core/session/alert_controller.dart';
import '../core/session/floor_controller.dart';
import '../core/session/message_pipeline.dart';
import '../core/session/session_controller.dart';
import '../core/storage/database.dart';
import '../core/storage/message_repository.dart';
import '../core/transport/loopback_transport.dart';
import '../core/transport/transport_adapter.dart';
import '../core/tts/onnx_vits_tts_engine.dart';
import '../core/tts/tts_engine.dart';
import '../core/util/log.dart';

/// Wires the object graph.
///
/// Hand-written rather than a DI package: the graph is small, the wiring is
/// read once, and an explicit constructor chain is the clearest possible
/// statement of what depends on what. It also makes the substitution in tests
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
    required this.deviceId,
    required this.asr,
    required this.tts,
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
  /// inline, so a limitation is reported once and surfaced honestly in the
  /// UI - notably alert loudness, which iOS cannot guarantee.
  final PlatformInfo platformInfo;
  final PlatformCapabilities capabilities;

  final String deviceId;

  /// Null when no pack is installed. Null rather than a throwing stub, so the
  /// UI can render a "install a language pack" state instead of an error
  /// every time a button is touched.
  final AsrEngine? asr;
  final TtsEngine? tts;

  static const String _deviceIdKey = 'device_id';
  static const String _languageKey = 'language_tag';

  TransportAdapter? _transport;
  MessagePipeline? _pipeline;
  SessionController? _session;
  AlertController? _alerts;

  TransportAdapter? get transport => _transport;
  MessagePipeline? get pipeline => _pipeline;
  SessionController? get session => _session;
  AlertController? get alerts => _alerts;

  String get languageTag =>
      preferences.getString(_languageKey) ?? 'hi-IN';

  Future<void> setLanguageTag(String tag) async {
    await preferences.setString(_languageKey, tag);
  }

  static Future<ServiceLocator> bootstrap() async {
    final SharedPreferences preferences =
        await SharedPreferences.getInstance();

    // A stable per-install id. Not the Android id: that is device-scoped and
    // reading it needs a permission we do not want to justify.
    String deviceId = preferences.getString(_deviceIdKey) ?? '';
    if (deviceId.isEmpty) {
      final Random random = Random.secure();
      deviceId = List<String>.generate(
        4,
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

    final bool hasAsr = packs.packs.any((p) => p.role.code == 'asr');
    final bool hasTts = packs.packs.any((p) => p.role.code == 'tts');

    ItLog.i('boot',
        'packs: ${packs.packs.length}, asr=$hasAsr, tts=$hasTts');

    final ServiceLocator locator = ServiceLocator._(
      preferences: preferences,
      packs: packs,
      metrics: metrics,
      repository: repository,
      capture: CaptureEngine(),
      playback: PlaybackController(),
      floor: FloorController(),
      platformInfo: platformInfo,
      capabilities: capabilities,
      deviceId: deviceId,
      asr: hasAsr
          ? OnnxCtcAsrEngine(packs: packs, metrics: metrics)
          : null,
      tts: hasTts
          ? OnnxVitsTtsEngine(packs: packs, metrics: metrics)
          : null,
    );

    _instance = locator;
    return locator;
  }

  /// Installs a live transport and starts a session over it.
  Future<SessionController> attachTransport(
    TransportAdapter transport, {
    SessionCrypto? crypto,
  }) async {
    await _session?.dispose();
    await _transport?.close();

    final MessagePipeline pipeline = MessagePipeline(
      transport: transport,
      metrics: metrics,
      deviceId: deviceId,
      crypto: crypto,
    );

    final TtsEngine? voice = tts;
    final AlertController alerts = AlertController(
      // A null engine cannot happen here in practice, because the alert path
      // is only reachable once a pack exists; the fallback keeps the type
      // honest without a nullable field everywhere downstream.
      tts: voice ?? _SilentTtsEngine(),
      playback: playback,
      metrics: metrics,
    );

    final SessionController session = SessionController(
      capture: capture,
      playback: playback,
      pipeline: pipeline,
      repository: repository,
      metrics: metrics,
      floor: floor,
      alerts: alerts,
      languageTag: () => languageTag,
      asr: asr,
      tts: tts,
    );

    _transport = transport;
    _pipeline = pipeline;
    _alerts = alerts;
    _session = session;

    await transport.connect();
    await session.start();
    return session;
  }

  /// Single-device demo: both ends of a loopback pair in one process, so the
  /// full path can be shown without a second phone.
  Future<SessionController> attachLoopback() async {
    final (LoopbackTransport local, LoopbackTransport remote) =
        LoopbackTransport.pair();

    // The far end simply echoes a receipt, which is enough to exercise the
    // send path, the metrics and the transcript.
    final MessagePipeline farEnd = MessagePipeline(
      transport: remote,
      metrics: MetricsCollector(),
      deviceId: 'demo-peer',
    );
    farEnd.inbound().listen((Inbound inbound) async {
      if (inbound is InboundMessage) {
        await farEnd.sendReceipt(inbound.message.messageId);
      }
    });
    await remote.connect();

    return attachTransport(local);
  }

  Future<void> dispose() async {
    await _session?.dispose();
    await _transport?.close();
    await asr?.dispose();
    await tts?.dispose();
  }
}

/// Stands in for a voice engine when no pack is installed. It produces no
/// audio, which is correct: the text is still stored and shown.
class _SilentTtsEngine implements TtsEngine {
  @override
  Set<String> get availableLanguages => const <String>{};

  @override
  Stream<SynthesisChunk> synthesize(SynthesisRequest request) =>
      const Stream<SynthesisChunk>.empty();

  @override
  Future<void> warmUp(String languageTag) async {}

  @override
  Future<void> dispose() async {}
}
