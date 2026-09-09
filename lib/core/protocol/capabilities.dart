import '../models/model_pack.dart';

/// What this device can do, and what the peer said it can do.
///
/// Exchanged once per link. Without it, a phone happily transmits Odia to a
/// peer that has no Odia voice, and the failure only shows up as silence at
/// the far end - which in a distress scenario is the worst possible failure
/// mode. Knowing the peer's languages lets the sender warn before speaking.
class DeviceCapabilities {
  const DeviceCapabilities({
    required this.asrLanguages,
    required this.ttsLanguages,
    required this.appVersion,
    required this.protocolVersion,
  });

  final Set<String> asrLanguages;
  final Set<String> ttsLanguages;
  final String appVersion;
  final int protocolVersion;

  static const DeviceCapabilities empty = DeviceCapabilities(
    asrLanguages: <String>{},
    ttsLanguages: <String>{},
    appVersion: '0.0.0',
    protocolVersion: 1,
  );

  /// Built from installed packs: capability is what is on disk and verified,
  /// not what the build hoped would be there.
  static DeviceCapabilities fromPacks(
    Iterable<ModelPack> packs, {
    required String appVersion,
    int protocolVersion = 1,
  }) {
    final Set<String> asr = <String>{};
    final Set<String> tts = <String>{};
    for (final ModelPack pack in packs) {
      switch (pack.role) {
        case PackRole.asr:
          asr.add(pack.languageTag);
        case PackRole.tts:
          tts.add(pack.languageTag);
      }
    }
    return DeviceCapabilities(
      asrLanguages: asr,
      ttsLanguages: tts,
      appVersion: appVersion,
      protocolVersion: protocolVersion,
    );
  }

  /// True when the peer can speak what we are about to send.
  bool peerCanSpeak(String languageTag) => ttsLanguages.contains(languageTag);

  /// Languages usable end to end: we can recognise them and the peer can
  /// speak them.
  Set<String> usableWith(DeviceCapabilities peer) =>
      asrLanguages.intersection(peer.ttsLanguages);

  bool get isCompatible => protocolVersion == 1;
}
