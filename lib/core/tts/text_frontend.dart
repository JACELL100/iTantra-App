import 'number_normalizer.dart';

/// One synthesisable chunk of text.
class TextChunk {
  const TextChunk({required this.text, required this.index, required this.isLast});

  final String text;
  final int index;
  final bool isLast;
}

/// Text preparation before synthesis.
///
/// Two jobs. First, expand numbers and symbols into words, because the
/// acoustic model has never seen a digit. Second, split long text into
/// sentence-sized chunks so playback can start on the first chunk while the
/// rest is still being generated - the single biggest perceived-latency win
/// available on the receive side.
class TextFrontend {
  const TextFrontend({this.maxCharactersPerChunk = 160});

  final int maxCharactersPerChunk;

  /// Devanagari danda and double danda. These, not the full stop, are the
  /// sentence terminators in most of these scripts, and splitting on "."
  /// alone would treat a whole Hindi paragraph as one chunk.
  static const String danda = '\u0964';
  static const String doubleDanda = '\u0965';

  List<TextChunk> prepare(String rawText, String languageTag) {
    final String expanded =
        NumberNormalizer.normalize(_expandSymbols(rawText), languageTag);

    final List<String> sentences = _splitSentences(expanded);
    final List<String> chunks = <String>[];

    final StringBuffer current = StringBuffer();
    for (final String sentence in sentences) {
      if (current.length + sentence.length > maxCharactersPerChunk &&
          current.isNotEmpty) {
        chunks.add(current.toString().trim());
        current.clear();
      }
      if (sentence.length > maxCharactersPerChunk) {
        // A single very long sentence with no punctuation still has to be
        // broken, or the model runs out of memory on a low-end device.
        chunks.addAll(_splitOnWords(sentence));
        continue;
      }
      current.write('$sentence ');
    }
    if (current.isNotEmpty) chunks.add(current.toString().trim());

    final List<String> nonEmpty =
        chunks.where((String c) => c.isNotEmpty).toList(growable: false);

    return <TextChunk>[
      for (int i = 0; i < nonEmpty.length; i++)
        TextChunk(
          text: nonEmpty[i],
          index: i,
          isLast: i == nonEmpty.length - 1,
        ),
    ];
  }

  List<String> _splitSentences(String text) {
    final List<String> out = <String>[];
    final StringBuffer buffer = StringBuffer();
    for (final int rune in text.runes) {
      final String char = String.fromCharCode(rune);
      buffer.write(char);
      if (char == danda || char == doubleDanda || char == '.' ||
          char == '?' || char == '!') {
        out.add(buffer.toString().trim());
        buffer.clear();
      }
    }
    if (buffer.isNotEmpty) out.add(buffer.toString().trim());
    return out.where((String s) => s.isNotEmpty).toList(growable: false);
  }

  List<String> _splitOnWords(String sentence) {
    final List<String> out = <String>[];
    final StringBuffer current = StringBuffer();
    for (final String word in sentence.split(' ')) {
      if (current.length + word.length + 1 > maxCharactersPerChunk &&
          current.isNotEmpty) {
        out.add(current.toString().trim());
        current.clear();
      }
      current.write('$word ');
    }
    if (current.isNotEmpty) out.add(current.toString().trim());
    return out;
  }

  /// Symbols that appear constantly in field messages and are silent to the
  /// model if left as glyphs.
  static String _expandSymbols(String text) => text
      .replaceAll('%', ' percent ')
      .replaceAll('&', ' and ')
      .replaceAll('+', ' plus ')
      .replaceAll('@', ' at ')
      .replaceAll('/', ' ')
      .replaceAll('-', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
