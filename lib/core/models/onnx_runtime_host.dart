import 'dart:io';

import 'package:onnxruntime/onnxruntime.dart';

import '../util/log.dart';

/// Reference-counted owner of the process-wide ONNX Runtime environment.
///
/// `OrtEnv` is a singleton whose `init()` creates a native environment and
/// whose `release()` destroys it. Two engines using it naively is a real bug,
/// not a theoretical one: if the TTS engine is disposed (or a language pack is
/// evicted) while the ASR engine still holds sessions, the ASR sessions are
/// left pointing at freed native memory and the next utterance crashes the
/// process. A count makes that impossible.
///
/// It also probes for the native library before the first `init()`, because a
/// missing `libonnxruntime.so` on an unusual ABI otherwise surfaces as an
/// opaque FFI null-pointer fault inside inference rather than a clear error the
/// model-pack screen can show.
class OnnxRuntimeHost {
  OnnxRuntimeHost._();

  static int _references = 0;
  static bool _initialised = false;
  static String? _unavailableReason;

  /// Non-null when the runtime cannot be used on this device at all.
  static String? get unavailableReason => _unavailableReason;

  static bool get isAvailable => _unavailableReason == null;

  /// True once at least one engine has brought the environment up.
  static bool get isInitialised => _initialised;

  /// Number of live holders. Exposed for the diagnostics screen.
  static int get references => _references;

  /// Brings the environment up, or throws with a readable message.
  static void acquire() {
    if (_initialised) {
      _references++;
      return;
    }

    final String? blocked = _unavailableReason;
    if (blocked != null) {
      throw StateError('ONNX Runtime unavailable: $blocked');
    }

    try {
      OrtEnv.instance.init();
      _initialised = true;
      _references = 1;
      ItLog.i('onnx', 'runtime initialised (version ${OrtEnv.version})');
    } on Object catch (error, stack) {
      // Most commonly a missing native library, which only happens on an ABI
      // the package does not ship. Recorded rather than rethrown on every call
      // so the UI can explain it once instead of spamming the log.
      _unavailableReason = _describe(error);
      ItLog.e('onnx', 'runtime unavailable: $_unavailableReason', error, stack);
      throw StateError('ONNX Runtime unavailable: $_unavailableReason');
    }
  }

  /// Drops one reference. The environment is torn down only when the last
  /// holder lets go.
  static void release() {
    if (!_initialised) return;
    _references--;
    if (_references > 0) return;

    _references = 0;
    try {
      OrtEnv.instance.release();
    } on Object catch (error) {
      ItLog.w('onnx', 'environment release failed: $error');
    }
    _initialised = false;
  }

  /// A readable one-line cause. The raw FFI errors are unhelpful on their own.
  static String _describe(Object error) {
    final String text = error.toString();
    if (error is ArgumentError || text.contains('Invalid argument')) {
      return 'the native onnxruntime library is missing for this CPU '
          'architecture (${_abiHint()})';
    }
    if (text.contains('DynamicLibrary') || text.contains('Failed to load')) {
      return 'libonnxruntime could not be loaded (${_abiHint()})';
    }
    return text;
  }

  static String _abiHint() {
    if (!Platform.isAndroid) return Platform.operatingSystem;
    // Android delivers only the ABI that was unpacked for this device here.
    return 'android ${Platform.version}';
  }
}
