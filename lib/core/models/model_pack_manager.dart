import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../util/log.dart';
import 'model_pack.dart';

/// Scans, validates and reports on installed model packs.
///
/// The scan is the single source of truth for what the app can do: the UI
/// offers a language only when both halves of it are present on disk. That
/// avoids the worst possible field failure, which is a phone that accepts a
/// distress message and then silently cannot speak it.
class ModelPackManager {
  ModelPackManager({Directory? rootOverride}) : _rootOverride = rootOverride;

  final Directory? _rootOverride;

  final Map<String, ModelPack> _packs = <String, ModelPack>{};
  final List<String> _problems = <String>[];

  Directory? _root;

  /// `<app support>/packs`. App support rather than external storage: it is
  /// private to the app, survives reboots, and is removed on uninstall.
  Future<Directory> root() async {
    final Directory? cached = _root;
    if (cached != null) return cached;
    final Directory base =
        _rootOverride ?? await getApplicationSupportDirectory();
    final Directory dir = Directory(p.join(base.path, 'packs'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _root = dir;
    return dir;
  }

  List<ModelPack> get packs =>
      _packs.values.toList(growable: false)
        ..sort((ModelPack a, ModelPack b) => a.id.compareTo(b.id));

  List<String> get problems => List<String>.unmodifiable(_problems);

  int get totalBytes =>
      _packs.values.fold<int>(0, (int sum, ModelPack pack) => sum + pack.sizeBytes);

  List<ModelPack> get nonRedistributablePacks => _packs.values
      .where((ModelPack pack) => !pack.isRedistributable)
      .toList(growable: false);

  /// Languages with both an ASR and a TTS pack, so the full loop works.
  Set<String> get fullyEquippedLanguages {
    final Set<String> asr = <String>{};
    final Set<String> tts = <String>{};
    for (final ModelPack pack in _packs.values) {
      (pack.role == PackRole.asr ? asr : tts).add(pack.languageTag);
    }
    return asr.intersection(tts);
  }

  ModelPack? packFor(String languageTag, PackRole role) =>
      _packs['$languageTag-${role.code}'];

  /// Re-reads the pack directory. Cheap: manifests only, no hashing.
  Future<void> refresh() async {
    _packs.clear();
    _problems.clear();

    final Directory dir = await root();
    for (final FileSystemEntity entity in dir.listSync()) {
      if (entity is! Directory) continue;
      final File manifest = File(p.join(entity.path, 'manifest.json'));
      if (!manifest.existsSync()) {
        _problems.add('${p.basename(entity.path)}: no manifest.json');
        continue;
      }
      try {
        final Object? parsed = jsonDecode(manifest.readAsStringSync());
        if (parsed is! Map<String, Object?>) {
          _problems.add('${p.basename(entity.path)}: manifest is not an object');
          continue;
        }
        final ModelPack pack =
            ModelPack.fromManifest(parsed, directory: entity.path);
        if (!File(pack.modelPath).existsSync()) {
          _problems.add('${pack.id}: model.onnx missing');
          continue;
        }
        _packs[pack.id] = pack;
      } on Object catch (error) {
        _problems.add('${p.basename(entity.path)}: $error');
        ItLog.w('packs', 'failed to read manifest: $error');
      }
    }

    ItLog.i('packs',
        'found ${_packs.length} packs, ${_problems.length} problems');
  }

  /// Full integrity check. Slow on purpose; invoked from settings.
  Future<Map<String, bool>> verify() async {
    final Map<String, bool> results = <String, bool>{};
    for (final ModelPack pack in packs) {
      try {
        results[pack.id] = await pack.verifyDigest();
      } on ModelPackError catch (e) {
        results[pack.id] = false;
        _problems.add('${pack.id}: ${e.message}');
      }
    }
    return results;
  }
}
