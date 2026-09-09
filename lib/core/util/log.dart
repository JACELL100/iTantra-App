import 'dart:developer' as developer;

/// Minimal logging.
///
/// Uses dart:developer rather than print so release builds do not spam
/// logcat, and provides [redact] because a transcript is often the most
/// sensitive thing this app touches: an emergency message can name people and
/// places, and it must never end up in a bug report verbatim.
class ItLog {
  const ItLog._();

  /// Debug lines are off unless the diagnostics screen turns them on.
  static bool verbose = false;

  static void d(String tag, String message) {
    if (verbose) developer.log(message, name: 'itantra.$tag', level: 500);
  }

  static void i(String tag, String message) =>
      developer.log(message, name: 'itantra.$tag', level: 800);

  static void w(String tag, String message) =>
      developer.log(message, name: 'itantra.$tag', level: 900);

  static void e(
    String tag,
    String message, [
    Object? error,
    StackTrace? stack,
  ]) =>
      developer.log(
        message,
        name: 'itantra.$tag',
        level: 1000,
        error: error,
        stackTrace: stack,
      );

  /// Keeps only the shape of a string: length and first character. Enough to
  /// debug "did the text arrive at all" without recording what was said.
  static String redact(String text) {
    if (text.isEmpty) return '<empty>';
    final int length = text.runes.length;
    return '<$length chars starting "${String.fromCharCode(text.runes.first)}">';
  }
}
