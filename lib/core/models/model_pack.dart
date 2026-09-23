import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

/// Which half of the pipeline a pack serves.
enum PackRole {
  asr('asr'),
  tts('tts');

  const PackRole(this.code);

  final String code;

  static PackRole fromCode(String code) =>
      code == 'tts' ? PackRole.tts : PackRole.asr;
}

/// Where a pack came from. Shown in the UI because it is the difference
/// between "a model we validated" and "a file somebody put on this phone",
/// and the user is entitled to know which they are trusting.
enum PackOrigin {
  bundled('bundled', 'Ships with the app'),
  downloaded('download', 'Downloaded'),
  imported('import', 'Imported from a file'),
  built('built', 'Built on this phone');

  const PackOrigin(this.code, this.label);

  final String code;
  final String label;

  static PackOrigin fromCode(String? code) {
    for (final PackOrigin origin in PackOrigin.values) {
      if (origin.code == code) return origin;
    }
    return PackOrigin.downloaded;
  }
}

class ModelPackError implements Exception {
  const ModelPackError(this.message);

  final String message;

  @override
  String toString() => 'ModelPackError: $message';
}

/// Tensor names a pack's graph actually uses.
///
/// The exporter's names (`audio_signal`, `input_lengths`, ...) are only the
/// convention. A model exported by somebody else - a Piper voice, an MMS-TTS
/// graph, an export from the team's own tooling - may call the same tensors
/// something else entirely, and ONNX Runtime has no way to guess. Recording the
/// real names at install time is what lets an outside model run at all instead
/// of failing with "invalid input name" the first time someone speaks.
class TensorNames {
  const TensorNames({
    required this.input,
    this.length,
    this.scales,
    this.output,
  });

  static const TensorNames asrDefaults = TensorNames(
    input: 'audio_signal',
    length: 'length',
  );

  static const TensorNames ttsDefaults = TensorNames(
    input: 'input',
    length: 'input_lengths',
    scales: 'scales',
    output: 'audio',
  );

  final String input;

  /// Null when the graph takes a single input, which several exported VITS and
  /// Whisper graphs do.
  final String? length;
  final String? scales;

  /// Null means "whichever tensor the graph returns first".
  final String? output;

  Map<String, Object?> toJson() => <String, Object?>{
        'input': input,
        if (length != null) 'length': length,
        if (scales != null) 'scales': scales,
        if (output != null) 'output': output,
      };

  static TensorNames? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? input = raw['input'];
    if (input is! String || input.isEmpty) return null;
    return TensorNames(
      input: input,
      length: raw['length'] as String?,
      scales: raw['scales'] as String?,
      output: raw['output'] as String?,
    );
  }
}

/// One installed model pack: an ONNX graph plus its vocabulary.
///
/// Packs are sideloaded into app support rather than bundled in the APK, for
/// two unrelated but equally hard reasons. First, size: ten languages times
/// two directions is well over a gigabyte, and an APK that large cannot be
/// installed on the low-end devices this must run on. Second, licensing: some
/// otherwise excellent Indic voices are released non-commercial only (the MMS
/// Odia voice is CC-BY-NC), and shipping one inside a distributed binary
/// would contaminate the licence of the whole app. Keeping packs external
/// lets the operator choose, and lets this repository stay cleanly licensed.
class ModelPack {
  const ModelPack({
    required this.languageTag,
    required this.role,
    required this.directory,
    required this.digestHex,
    required this.sizeBytes,
    required this.licence,
    required this.sourceUrl,
    this.isRedistributable = true,
    this.sampleRateHz,
    this.notes,
    this.origin = PackOrigin.downloaded,
    this.names,
  });

  final String languageTag;
  final PackRole role;

  /// Absolute path of the pack directory.
  final String directory;

  /// SHA-256 of the model file, checked on demand. A pack truncated by a
  /// failed copy would otherwise surface as garbled speech instead of an
  /// error, which is a miserable thing to debug in the field.
  final String digestHex;

  final int sizeBytes;
  final String licence;
  final String sourceUrl;

  /// False for non-commercial or otherwise restricted weights. The UI shows a
  /// warning and tools/license_audit.py fails a release build.
  final bool isRedistributable;

  final int? sampleRateHz;
  final String? notes;

  /// How this pack got here.
  final PackOrigin origin;

  /// Tensor names declared by the pack. Null means the exporter convention,
  /// which is what every pack built by ml/export uses.
  final TensorNames? names;

  /// The names to use when opening this graph.
  TensorNames get tensorNames => names ??
      (role == PackRole.asr ? TensorNames.asrDefaults : TensorNames.ttsDefaults);

  String get id => '$languageTag-${role.code}';

  String get modelPath => p.join(directory, 'model.onnx');

  /// Auxiliary file inside the pack, e.g. tokens.txt or graphemes.tsv.
  String assetPath(String name) => p.join(directory, name);

  String get manifestPath => p.join(directory, 'manifest.json');

  static ModelPack fromManifest(
    Map<String, Object?> json, {
    required String directory,
  }) {
    final Object? language = json['language'];
    final Object? role = json['role'];
    if (language is! String || role is! String) {
      throw const ModelPackError('manifest needs language and role');
    }
    return ModelPack(
      languageTag: language,
      role: PackRole.fromCode(role),
      directory: directory,
      digestHex: (json['sha256'] as String?) ?? '',
      sizeBytes: (json['sizeBytes'] as int?) ?? 0,
      licence: (json['licence'] as String?) ?? 'unknown',
      sourceUrl: (json['sourceUrl'] as String?) ?? '',
      isRedistributable: (json['redistributable'] as bool?) ?? true,
      sampleRateHz: json['sampleRateHz'] as int?,
      notes: json['notes'] as String?,
      origin: PackOrigin.fromCode(json['origin'] as String?),
      names: TensorNames.fromJson(json['tensors']),
    );
  }

  Map<String, Object?> toManifest() => <String, Object?>{
        'language': languageTag,
        'role': role.code,
        'sha256': digestHex,
        'sizeBytes': sizeBytes,
        'licence': licence,
        'sourceUrl': sourceUrl,
        'redistributable': isRedistributable,
        'origin': origin.code,
        if (sampleRateHz != null) 'sampleRateHz': sampleRateHz,
        if (notes != null) 'notes': notes,
        if (names != null) 'tensors': names!.toJson(),
      };

  /// Verifies the model file against the manifest digest.
  ///
  /// Hashing 100-500 MB takes seconds, so this runs on demand from the
  /// settings screen and once after an install, never on every launch.
  Future<bool> verifyDigest() async {
    if (digestHex.isEmpty) return true;
    final File file = File(modelPath);
    if (!file.existsSync()) {
      throw ModelPackError('missing model file for $id');
    }

    // Streamed rather than read into memory: a 500 MB read would be fatal on
    // a 2 GB handset.
    final crypto.Digest actual =
        await crypto.sha256.bind(file.openRead()).first;

    return actual.toString().toLowerCase() == digestHex.toLowerCase();
  }

  String describeSize() {
    if (sizeBytes >= 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(sizeBytes / 1024).toStringAsFixed(0)} KB';
  }
}
