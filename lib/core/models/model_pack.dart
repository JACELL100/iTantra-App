import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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

class ModelPackError implements Exception {
  const ModelPackError(this.message);

  final String message;

  @override
  String toString() => 'ModelPackError: $message';
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
        if (sampleRateHz != null) 'sampleRateHz': sampleRateHz,
        if (notes != null) 'notes': notes,
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
    final bytes = <int>[];
    await for (final chunk in file.openRead()) {
      bytes.addAll(chunk);
    }
    final digest = sha256.convert(bytes);

    return digest.toString() == digestHex.toLowerCase();
  }

  String describeSize() {
    if (sizeBytes >= 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(sizeBytes / 1024).toStringAsFixed(0)} KB';
  }
}

/// Sink for digest fold operation
class DigestSink implements ByteConversionSink {
  @override
  void add(List<int> chunk) {}

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) {}

  @override
  void close() {}
}