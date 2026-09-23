import 'dart:convert';

/// Where the cloud engines send their requests.
///
/// Deliberately an OpenAI-compatible contract rather than a specific vendor's.
/// That shape is the de-facto standard: the big hosted providers expose it, so
/// do local servers such as a whisper.cpp server or LM Studio, and it means the
/// app is not tied to one company's pricing or to one company still existing
/// when this is used. Anything that speaks `/audio/transcriptions` and
/// `/audio/speech` works.
///
/// The user supplies the key. Nothing is bundled, nothing is shared between
/// installs, and speech is never sent anywhere unless this has been configured
/// on purpose - which is also why the workspace keeps working with no key at
/// all.
class CloudSpeechConfig {
  const CloudSpeechConfig({
    this.baseUrl = '',
    this.apiKey = '',
    this.asrModel = '',
    this.ttsModel = '',
    this.ttsVoice = '',
    this.timeoutSeconds = 45,
  });

  /// e.g. `https://api.groq.com/openai/v1`. A trailing slash is tolerated.
  final String baseUrl;

  final String apiKey;

  /// e.g. `whisper-large-v3-turbo`.
  final String asrModel;

  /// e.g. `gpt-4o-mini-tts`. Empty when the provider offers no synthesis, in
  /// which case the device voice is used instead.
  final String ttsModel;

  final String ttsVoice;

  final int timeoutSeconds;

  bool get hasKey => apiKey.trim().isNotEmpty;

  bool get hasBaseUrl => baseUrl.trim().isNotEmpty;

  /// Synthesising over the network needs all three of endpoint, key and model.
  bool get canTranscribe => hasBaseUrl && hasKey && asrModel.trim().isNotEmpty;

  bool get canSynthesize =>
      hasBaseUrl && hasKey && ttsModel.trim().isNotEmpty;

  static final RegExp _trailingSlashes = RegExp(r'/+$');

  Uri endpoint(String path) => Uri.parse(
        '${baseUrl.trim().replaceAll(_trailingSlashes, '')}'
        '/${path.replaceAll(RegExp(r'^/+'), '')}',
      );

  Uri get transcriptionsUri => endpoint('audio/transcriptions');

  Uri get speechUri => endpoint('audio/speech');

  /// The host, for the honest "this leaves your phone" line in the UI.
  String get host {
    if (!hasBaseUrl) return '—';
    try {
      return Uri.parse(baseUrl.trim()).host;
    } on FormatException {
      return baseUrl.trim();
    }
  }

  CloudSpeechConfig copyWith({
    String? baseUrl,
    String? apiKey,
    String? asrModel,
    String? ttsModel,
    String? ttsVoice,
    int? timeoutSeconds,
  }) =>
      CloudSpeechConfig(
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        asrModel: asrModel ?? this.asrModel,
        ttsModel: ttsModel ?? this.ttsModel,
        ttsVoice: ttsVoice ?? this.ttsVoice,
        timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'asrModel': asrModel,
        'ttsModel': ttsModel,
        'ttsVoice': ttsVoice,
        'timeoutSeconds': timeoutSeconds,
      };

  String encode() => jsonEncode(toJson());

  static CloudSpeechConfig decode(String? raw) {
    if (raw == null || raw.isEmpty) return const CloudSpeechConfig();
    try {
      final Object? parsed = jsonDecode(raw);
      if (parsed is! Map) return const CloudSpeechConfig();
      return CloudSpeechConfig(
        baseUrl: (parsed['baseUrl'] as String?) ?? '',
        apiKey: (parsed['apiKey'] as String?) ?? '',
        asrModel: (parsed['asrModel'] as String?) ?? '',
        ttsModel: (parsed['ttsModel'] as String?) ?? '',
        ttsVoice: (parsed['ttsVoice'] as String?) ?? '',
        timeoutSeconds: (parsed['timeoutSeconds'] as int?) ?? 45,
      );
    } on FormatException {
      return const CloudSpeechConfig();
    }
  }

  /// `hi-IN` to `hi`. The transcription endpoints take a bare ISO-639-1 code.
  static String languageCode(String languageTag) =>
      languageTag.split('-').first.toLowerCase();

  /// Languages the app offers, and therefore the languages a cloud engine
  /// advertises. Kept identical to the on-device pack languages on purpose: a
  /// phone that can hear Tamil over the network can still hear Tamil, so
  /// capability advertisement to the peer must not change with the engine.
  static const Set<String> languages = <String>{
    'hi-IN',
    'en-IN',
    'bn-IN',
    'ta-IN',
    'te-IN',
    'mr-IN',
    'gu-IN',
    'kn-IN',
    'ml-IN',
    'pa-IN',
    'or-IN',
    'as-IN',
    'ur-IN',
    'ne-IN',
  };
}

/// A provider the settings screen can fill in with one tap.
///
/// The models named here are the ones each provider documents. They are not
/// guesses, and they are not promises: prices, free tiers and model names move,
/// so the note says what to check rather than claiming a number that will be
/// wrong by the time anyone reads it.
class CloudPreset {
  const CloudPreset({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.asrModel,
    required this.ttsModel,
    required this.ttsVoice,
    required this.note,
    required this.docsUrl,
    this.freeTier = false,
  });

  final String id;
  final String name;
  final String baseUrl;
  final String asrModel;
  final String ttsModel;
  final String ttsVoice;
  final String note;
  final String docsUrl;

  /// True when the provider documents a free tier. Said as "documents", because
  /// only the provider can change it and only the user can verify it.
  final bool freeTier;

  static const List<CloudPreset> all = <CloudPreset>[
    CloudPreset(
      id: 'groq',
      name: 'Groq',
      baseUrl: 'https://api.groq.com/openai/v1',
      asrModel: 'whisper-large-v3-turbo',
      ttsModel: '',
      ttsVoice: '',
      note:
          'OpenAI-compatible transcription with a documented free tier and rate '
          'limits, and by far the fastest hosted Whisper. No speech synthesis, '
          'so pair it with the device voice.',
      docsUrl: 'https://console.groq.com/docs/speech-to-text',
      freeTier: true,
    ),
    CloudPreset(
      id: 'openai',
      name: 'OpenAI',
      baseUrl: 'https://api.openai.com/v1',
      asrModel: 'whisper-1',
      ttsModel: 'gpt-4o-mini-tts',
      ttsVoice: 'alloy',
      note:
          'Both directions over the same API. Billed per use with no free tier; '
          'the account must have credit before a request will succeed.',
      docsUrl: 'https://platform.openai.com/docs/guides/speech-to-text',
    ),
    CloudPreset(
      id: 'local',
      name: 'A server on your network',
      baseUrl: 'http://192.168.1.10:8080/v1',
      asrModel: 'whisper-1',
      ttsModel: 'tts-1',
      ttsVoice: 'alloy',
      note:
          'A whisper.cpp server, LM Studio or any other OpenAI-compatible '
          'server you run yourself. Nothing leaves the network, which is the '
          'one way to get cloud-grade accuracy with no third party involved.',
      docsUrl: '',
      freeTier: true,
    ),
  ];

  static CloudPreset? byId(String id) {
    for (final CloudPreset preset in all) {
      if (preset.id == id) return preset;
    }
    return null;
  }
}
