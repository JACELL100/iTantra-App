/// Where speech is turned into text.
///
/// Three options, and the app is explicit about which one is in use, because
/// they differ in ways a user has to be able to see: what it costs, whether it
/// needs a connection, and whether their voice leaves the phone.
enum RecognitionSource {
  /// An ONNX pack on this phone. The default, and the only one that works with
  /// the radio switched off.
  packs(
    code: 'packs',
    label: 'On this phone',
    shortLabel: 'On-device model',
    summary: 'Speech is recognised locally. Works with no connection.',
  ),

  /// A hosted or self-hosted OpenAI-compatible endpoint.
  cloud(
    code: 'cloud',
    label: 'Cloud',
    shortLabel: 'Cloud model',
    summary: 'Audio is sent to the endpoint you configure. Needs a key and a '
        'connection.',
  ),

  /// No model at all. For demonstrating the rest of the pipeline.
  simulated(
    code: 'simulated',
    label: 'Demonstration',
    shortLabel: 'Simulated',
    summary: 'Produces a fixed demonstration sentence instead of your words. '
        'Nothing is recognised.',
  );

  const RecognitionSource({
    required this.code,
    required this.label,
    required this.shortLabel,
    required this.summary,
  });

  final String code;
  final String label;
  final String shortLabel;
  final String summary;

  /// True when audio leaves the device.
  bool get leavesDevice => this == RecognitionSource.cloud;

  /// True when selecting this needs something the user must still supply.
  bool get needsSetup => this == RecognitionSource.cloud;

  static RecognitionSource fromCode(String? code) {
    for (final RecognitionSource source in RecognitionSource.values) {
      if (source.code == code) return source;
    }
    return RecognitionSource.packs;
  }
}

/// Where text is turned back into speech.
enum VoiceSource {
  /// An ONNX voice pack on this phone.
  packs(
    code: 'packs',
    label: 'Voice pack',
    summary: 'The app\'s own voice model. Works with no connection.',
  ),

  /// The phone's built-in synthesiser, which every Android and iOS device has.
  device(
    code: 'device',
    label: 'Device voice',
    summary: 'The voice already installed on this phone. No download, no '
        'connection, no model to add.',
  ),

  /// A hosted OpenAI-compatible speech endpoint.
  cloud(
    code: 'cloud',
    label: 'Cloud',
    summary: 'Text is sent to the endpoint you configure and audio comes back.',
  ),

  /// No voice. Text is still stored and shown.
  none(
    code: 'none',
    label: 'Text only',
    summary: 'Nothing is spoken. Messages are still received and stored.',
  );

  const VoiceSource({
    required this.code,
    required this.label,
    required this.summary,
  });

  final String code;
  final String label;
  final String summary;

  bool get leavesDevice => this == VoiceSource.cloud;

  static VoiceSource fromCode(String? code) {
    for (final VoiceSource source in VoiceSource.values) {
      if (source.code == code) return source;
    }
    return VoiceSource.packs;
  }
}
