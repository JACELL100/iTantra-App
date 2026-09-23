import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:path/path.dart' as p;

import '../util/log.dart';
import 'model_pack.dart';
import 'model_pack_manager.dart';
import 'onnx_runtime_host.dart';

/// What the installer is doing, so the UI can show it.
enum InstallPhase {
  preparing('Checking the destination'),
  downloading('Downloading'),
  extracting('Reading the model'),
  vocabulary('Building the vocabulary'),
  inspecting('Checking the graph'),
  writing('Saving the manifest'),
  done('Ready');

  const InstallPhase(this.label);

  final String label;
}

@immutable
class PackInstallProgress {
  const PackInstallProgress({
    required this.phase,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.detail,
  });

  final InstallPhase phase;
  final int receivedBytes;
  final int totalBytes;
  final String? detail;

  /// 0..1, or null when the total size is not known. A determinate bar that
  /// guesses is worse than an honest spinner.
  double? get fraction {
    if (totalBytes <= 0) return null;
    return (receivedBytes / totalBytes).clamp(0.0, 1.0);
  }
}

class PackInstallException implements Exception {
  const PackInstallException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The outcome of an install, including anything the user should know about.
class PackInstallResult {
  const PackInstallResult({required this.pack, this.warnings = const <String>[]});

  final ModelPack pack;

  /// Non-fatal problems: inferred tensor names, an unknown sample rate, a
  /// vocabulary that had to be guessed at. Shown to the user rather than
  /// buried in a log, because each one predicts a specific way the pack may
  /// sound wrong.
  final List<String> warnings;

  bool get hasWarnings => warnings.isNotEmpty;
}

/// Installs, imports and builds model packs.
///
/// This is the only place in the app that performs outbound network I/O, and it
/// only ever does so because a person pressed a button to fetch a model. The
/// messaging path is unaffected and still goes through
/// [core/transport/offline_guard.dart], which is what the offline guarantee is
/// actually about. The distinction is deliberate and stated in the UI: a phone
/// with no packs still sends and receives messages with the radio off.
///
/// Three ways in, and they exist because they serve genuinely different users:
///
///  * **fetch** - a URL to a model file, for a team that publishes packs and
///    wants one-tap setup;
///  * **import** - files already on the phone, for a user who has their own
///    exported model;
///  * **build** - an imported model where the app derives the vocabulary and
///    the tensor mapping itself, so a raw ONNX file from a model hub has a
///    chance of working instead of only failing later on the first utterance.
class PackInstaller {
  PackInstaller({required ModelPackManager packs}) : _packs = packs;

  final ModelPackManager _packs;

  /// Beyond this the file is almost certainly not a phone model, and filling
  /// the user's storage to find out is not a kindness.
  static const int warnAboveBytes = 700 * 1024 * 1024;

  /// Fetches a model over the network and installs it as a pack.
  ///
  /// [auxiliary] maps a file name inside the pack to a URL - `tokens.txt`,
  /// `graphemes.tsv`, `lexicon.tsv`, `config.json`. Anything not listed is
  /// derived from the model itself where that is possible.
  Future<PackInstallResult> fetch({
    required Uri modelUrl,
    required String languageTag,
    required PackRole role,
    Map<String, Uri> auxiliary = const <String, Uri>{},
    String? licence,
    String? notes,
    int? sampleRateHz,
    bool redistributable = true,
    bool allowAnyHost = false,
    void Function(PackInstallProgress)? onProgress,
  }) async {
    final Directory destination = await _stagingDirectory(languageTag, role);
    try {
      final File model = File(p.join(destination.path, 'model.onnx'));
      await _download(
        modelUrl,
        model,
        onProgress: onProgress,
        allowAnyHost: allowAnyHost,
      );

      for (final MapEntry<String, Uri> entry in auxiliary.entries) {
        // The name becomes a path inside the pack, so it is sanitised: a
        // manifest from a URL is not a trusted source, and `../` in a file name
        // would let it write anywhere the app can.
        final String safe = p.basename(entry.key);
        await _download(
          entry.value,
          File(p.join(destination.path, safe)),
          onProgress: onProgress,
          allowAnyHost: allowAnyHost,
        );
      }

      return await _finalise(
        directory: destination,
        languageTag: languageTag,
        role: role,
        licence: licence ?? 'unknown — check the model card',
        sourceUrl: modelUrl.toString(),
        notes: notes,
        sampleRateHz: sampleRateHz,
        origin: PackOrigin.downloaded,
        redistributable: redistributable,
        vocabularyAlreadyPresent: auxiliary.keys.any(
          (String name) => name.endsWith('.txt') || name.endsWith('.tsv'),
        ),
        onProgress: onProgress,
      );
    } on Object {
      await _discard(destination);
      rethrow;
    }
  }

  /// Installs a model the user already has on the phone.
  ///
  /// [modelPath] is the `.onnx` file. [vocabularyPath] is optional and may be
  /// a `tokens.txt` (one token per line), a `graphemes.tsv`, or a JSON
  /// vocabulary in either `{"token": id}` or `["token", ...]` form - the two
  /// shapes every model hub actually publishes.
  Future<PackInstallResult> import({
    required String modelPath,
    required String languageTag,
    required PackRole role,
    String? vocabularyPath,
    String? licence,
    String? notes,
    int? sampleRateHz,
    String sourceUrl = '',
    void Function(PackInstallProgress)? onProgress,
  }) async {
    final File model = File(modelPath);
    if (!model.existsSync()) {
      throw PackInstallException('there is no file at $modelPath');
    }

    final Directory destination = await _stagingDirectory(languageTag, role);
    try {
      onProgress?.call(const PackInstallProgress(phase: InstallPhase.preparing));
      // Copied rather than referenced: a pack has to keep working after the
      // user clears their Downloads folder.
      await model.copy(p.join(destination.path, 'model.onnx'));
      onProgress?.call(const PackInstallProgress(phase: InstallPhase.extracting));

      bool vocabularyPresent = false;
      if (vocabularyPath != null && vocabularyPath.isNotEmpty) {
        vocabularyPresent = await _placeVocabulary(
          sourcePath: vocabularyPath,
          role: role,
          directory: destination,
          onProgress: onProgress,
        );
      }

      return await _finalise(
        directory: destination,
        languageTag: languageTag,
        role: role,
        licence: licence ?? 'unknown — imported by the user',
        sourceUrl: sourceUrl,
        notes: notes,
        sampleRateHz: sampleRateHz,
        origin: PackOrigin.imported,
        redistributable: false,
        vocabularyAlreadyPresent: vocabularyPresent,
        onProgress: onProgress,
      );
    } on Object {
      await _discard(destination);
      rethrow;
    }
  }

  /// Deletes a pack directory and rescans.
  Future<void> remove(ModelPack pack) async {
    final Directory dir = Directory(pack.directory);
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
      ItLog.i('packs', 'removed ${pack.id}');
    }
    await _packs.refresh();
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  Future<Directory> _stagingDirectory(String languageTag, PackRole role) async {
    final Directory root = await _packs.root();
    final Directory destination =
        Directory(p.join(root.path, '$languageTag-${role.code}'));
    // Replacing a pack wholesale rather than merging: a stale tokens.txt from a
    // previous model of the same name and language is a silent source of
    // nonsense output, and there is no way to tell one model's vocabulary from
    // another's afterwards.
    if (destination.existsSync()) {
      await destination.delete(recursive: true);
    }
    destination.createSync(recursive: true);
    return destination;
  }

  Future<void> _discard(Directory destination) async {
    try {
      if (destination.existsSync()) {
        await destination.delete(recursive: true);
      }
    } on Object catch (error) {
      ItLog.w('packs', 'could not clean up ${destination.path}: $error');
    }
  }

  Future<void> _download(
    Uri url,
    File target, {
    void Function(PackInstallProgress)? onProgress,
    bool allowAnyHost = false,
  }) async {
    if (url.scheme != 'https' && !(allowAnyHost && url.scheme == 'http')) {
      throw PackInstallException(
        'refusing ${url.scheme}://${url.host}: model files are only fetched '
        'over https',
      );
    }

    onProgress?.call(PackInstallProgress(
      phase: InstallPhase.downloading,
      detail: url.host,
    ));

    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..userAgent = 'iTantra/1.0';
    try {
      final HttpClientRequest request = await client.getUrl(url);
      final HttpClientResponse response = await request.close();

      if (response.statusCode != HttpStatus.ok) {
        throw PackInstallException(
          '${url.host} answered ${response.statusCode} for ${p.basename(url.path)}',
        );
      }

      final int total = response.contentLength;
      if (total > warnAboveBytes) {
        ItLog.w('packs', 'downloading ${(total / 1048576).round()} MB model');
      }

      final IOSink sink = target.openWrite();
      int received = 0;
      try {
        await for (final List<int> chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(PackInstallProgress(
            phase: InstallPhase.downloading,
            receivedBytes: received,
            totalBytes: total,
            detail: p.basename(url.path),
          ));
        }
      } finally {
        await sink.flush();
        await sink.close();
      }

      if (received == 0) {
        throw const PackInstallException('the download was empty');
      }
    } on SocketException catch (error) {
      throw PackInstallException(
        'could not reach ${url.host}: ${error.message}. Check the connection '
        'and try again.',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Copies a vocabulary file into the pack, converting JSON if needed.
  ///
  /// Returns true when a usable vocabulary file was written.
  Future<bool> _placeVocabulary({
    required String sourcePath,
    required PackRole role,
    required Directory directory,
    void Function(PackInstallProgress)? onProgress,
  }) async {
    onProgress?.call(const PackInstallProgress(phase: InstallPhase.vocabulary));

    final File source = File(sourcePath);
    if (!source.existsSync()) {
      throw PackInstallException('there is no vocabulary file at $sourcePath');
    }

    final String lower = sourcePath.toLowerCase();
    final String text = await source.readAsString();

    // Already in this project's own format: a straight copy.
    if (lower.endsWith('.tsv') && role == PackRole.tts) {
      await File(p.join(directory.path, 'graphemes.tsv')).writeAsString(text);
      return true;
    }
    if (lower.endsWith('.txt') && role == PackRole.asr) {
      await File(p.join(directory.path, 'tokens.txt')).writeAsString(text);
      return true;
    }

    return _convertVocabulary(text, role, directory);
  }

  /// Builds `tokens.txt` / `graphemes.tsv` from a JSON vocabulary.
  Future<bool> _convertVocabulary(
    String text,
    PackRole role,
    Directory directory,
  ) async {
    final Object? parsed;
    try {
      parsed = jsonDecode(text);
    } on FormatException {
      throw const PackInstallException(
        'that vocabulary file is neither JSON nor a file this app '
        'recognises. Supply tokens.txt (one token per line) for recognition, '
        'or graphemes.tsv (grapheme, tab, id) for speech.',
      );
    }

    // Ordered id -> token, because both formats below are indexed by id and a
    // vocabulary with a gap in it must not silently shift every token.
    final Map<int, String> byId = <int, String>{};

    if (parsed is Map) {
      for (final MapEntry<Object?, Object?> entry in parsed.entries) {
        final Object? id = entry.value;
        if (entry.key is! String || id is! int) continue;
        byId[id] = entry.key as String;
      }
    } else if (parsed is List) {
      for (int i = 0; i < parsed.length; i++) {
        final Object? token = parsed[i];
        if (token is String) byId[i] = token;
      }
    }

    if (byId.isEmpty) {
      throw const PackInstallException(
        'the vocabulary file has no token table this app can read. Expected '
        '{"token": id} or ["token", ...].',
      );
    }

    final int maxId = byId.keys.reduce((int a, int b) => a > b ? a : b);
    final List<String> buffer = List<String>.filled(maxId + 1, '');
    for (final MapEntry<int, String> entry in byId.entries) {
      buffer[entry.key] = entry.value;
    }

    if (role == PackRole.asr) {
      // One token per line, blank (index 0) first. A token containing a newline
      // is dropped rather than corrupting every index after it.
      await File(p.join(directory.path, 'tokens.txt'))
          .writeAsString('${buffer.join('\n')}\n');
      return true;
    }

    // TTS: grapheme, tab, id.
    final StringBuffer tsv = StringBuffer();
    for (int id = 0; id < buffer.length; id++) {
      final String token = buffer[id];
      if (token.isEmpty) continue;
      tsv.writeln('${token.replaceAll('\t', ' ')}\t$id');
    }
    await File(p.join(directory.path, 'graphemes.tsv')).writeAsString('$tsv');
    return true;
  }

  /// Inspects the graph, records its tensor names, and writes the manifest.
  Future<PackInstallResult> _finalise({
    required Directory directory,
    required String languageTag,
    required PackRole role,
    required String licence,
    required String sourceUrl,
    required String? notes,
    required int? sampleRateHz,
    required PackOrigin origin,
    required bool redistributable,
    required bool vocabularyAlreadyPresent,
    void Function(PackInstallProgress)? onProgress,
  }) async {
    final List<String> warnings = <String>[];

    onProgress?.call(const PackInstallProgress(phase: InstallPhase.inspecting));
    final TensorNames names = _inspect(
      File(p.join(directory.path, 'model.onnx')),
      role,
      warnings,
    );

    if (!vocabularyAlreadyPresent) {
      final bool derived = await _deriveMissingVocabulary(
        directory: directory,
        role: role,
        warnings: warnings,
        onProgress: onProgress,
      );
      if (!derived) {
        throw PackInstallException(
          role == PackRole.asr
              ? 'this pack has no tokens.txt and no vocabulary file was '
                  'supplied, so a transcript could not be assembled from the '
                  'model output.'
              : 'this pack has no graphemes.tsv and no vocabulary file was '
                  'supplied, so the model would have no way to turn text into '
                  'tokens.',
        );
      }
    }

    onProgress?.call(const PackInstallProgress(phase: InstallPhase.writing));

    final File model = File(p.join(directory.path, 'model.onnx'));
    final crypto.Digest digest =
        await crypto.sha256.bind(model.openRead()).first;
    final int size = await model.length();

    if (size > warnAboveBytes) {
      warnings.add(
        'This model is ${(size / 1048576).round()} MB. Loading it needs rough'
        'ly that much free memory next to the operating system.',
      );
    }

    final ModelPack pack = ModelPack(
      languageTag: languageTag,
      role: role,
      directory: directory.path,
      digestHex: digest.toString(),
      sizeBytes: size,
      licence: licence,
      sourceUrl: sourceUrl,
      isRedistributable: redistributable,
      sampleRateHz: role == PackRole.tts ? (sampleRateHz ?? 22050) : null,
      notes: notes,
      origin: origin,
      names: names,
    );

    if (role == PackRole.tts && sampleRateHz == null) {
      warnings.add(
        'Assuming 22050 Hz output. If speech sounds slow or squeaky, the model '
        'was trained at a different rate.',
      );
    }

    await File(pack.manifestPath)
        .writeAsString(const JsonEncoder.withIndent('  ').convert(
      pack.toManifest(),
    ));

    await _packs.refresh();
    onProgress?.call(const PackInstallProgress(phase: InstallPhase.done));

    ItLog.i('packs',
        'installed ${pack.id} (${pack.describeSize()}) as ${origin.code}');

    return PackInstallResult(pack: pack, warnings: warnings);
  }

  /// Opens the graph and works out which input is which.
  ///
  /// This is the step that makes importing somebody else's model realistic. The
  /// exporter convention is only a convention, and ONNX Runtime will not guess:
  /// given the wrong input name it fails with a message about a missing input
  /// that says nothing about which tensor it wanted. So the graph is opened
  /// once here, at install time, where the answer can be recorded and any
  /// problem can be reported while the user is still looking at the install
  /// sheet.
  TensorNames _inspect(File model, PackRole role, List<String> warnings) {
    OnnxRuntimeHost.acquire();
    OrtSessionOptions? options;
    OrtSession? session;
    try {
      options = OrtSessionOptions()
        ..setIntraOpNumThreads(1)
        ..setInterOpNumThreads(1);
      session = OrtSession.fromFile(model, options);

      final List<String> inputs = session.inputNames;
      final List<String> outputs = session.outputNames;

      ItLog.i('packs',
          'graph inputs: ${inputs.join(', ')} | outputs: ${outputs.join(', ')}');

      if (inputs.isEmpty || outputs.isEmpty) {
        throw const PackInstallException(
          'the model file has no inputs or no outputs, so it is not a usable '
          'ONNX graph.',
        );
      }

      final TensorNames fallback =
          role == PackRole.asr ? TensorNames.asrDefaults : TensorNames.ttsDefaults;
      final String input =
          inputs.contains(fallback.input) ? fallback.input : inputs.first;
      if (input != fallback.input) {
        warnings.add(
          'Using "$input" as the audio input. The graph does not use the '
          'expected name "${fallback.input}".',
        );
      }

      String? length;
      String? scales;
      final String? output = outputs.first;

      if (role == PackRole.asr) {
        // Two inputs is the whole convention: features and a length vector.
        // With more than two there is no reliable way to tell which is which
        // without reading tensor shapes, so the user is told the names instead
        // of being handed a pack that fails on the first word.
        final List<String> others =
            inputs.where((String name) => name != input).toList();
        if (others.length == 1) {
          length = others.first;
        } else if (others.length > 1) {
          throw PackInstallException(
            'this graph has more than one input besides "$input" '
            '(${others.join(', ')}), which this app cannot map safely. Name the '
            'audio input "audio_signal" and the length input "length".',
          );
        } else if (fallback.length != null) {
          warnings.add(
            'The graph takes a single input, so no length vector is supplied.',
          );
        }
      } else {
        final List<String> others =
            inputs.where((String name) => name != input).toList();
        // Piper and several other VITS exports pass exactly (input,
        // input_lengths, scales). Anything beyond that is a model this app has
        // no contract with.
        if (others.length <= 2) {
          length = others.isNotEmpty ? others[0] : null;
          scales = others.length > 1 ? others[1] : null;
        } else {
          throw PackInstallException(
            'this graph takes ${inputs.length} inputs '
            '(${inputs.join(', ')}), which this app cannot map safely. The '
            'voice contract is "input" (int64 tokens), "input_lengths" '
            '(int64), "scales" (float32 x3).',
          );
        }
      }

      return TensorNames(
        input: input,
        length: length,
        scales: scales,
        output: output,
      );
    } on PackInstallException {
      rethrow;
    } on Object catch (error) {
      throw PackInstallException(
        'the model file could not be opened as an ONNX graph: $error',
      );
    } finally {
      session?.release();
      options?.release();
      OnnxRuntimeHost.release();
    }
  }

  /// Tries to build the vocabulary from a file inside the pack.
  ///
  /// Only reached when neither the download nor the import supplied one. A
  /// `vocab.json` next to the model is common enough to be worth picking up
  /// automatically, which is what turns "download a folder from a model hub"
  /// into something that works.
  Future<bool> _deriveMissingVocabulary({
    required Directory directory,
    required PackRole role,
    required List<String> warnings,
    void Function(PackInstallProgress)? onProgress,
  }) async {
    final String target = role == PackRole.asr ? 'tokens.txt' : 'graphemes.tsv';
    if (File(p.join(directory.path, target)).existsSync()) return true;

    for (final String candidate in <String>[
      'vocab.json',
      'tokens.json',
      'vocabulary.json',
    ]) {
      final File file = File(p.join(directory.path, candidate));
      if (!file.existsSync()) continue;
      onProgress?.call(const PackInstallProgress(phase: InstallPhase.vocabulary));
      final bool ok =
          await _convertVocabulary(await file.readAsString(), role, directory);
      if (ok) {
        warnings.add('Vocabulary read from $candidate.');
        return true;
      }
    }
    return false;
  }
}
