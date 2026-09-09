import 'dart:io';

/// Grapheme-to-token mapping for the synthesiser.
///
/// eSpeak NG is the usual choice for a phonemizer, and it is a good one - but
/// it is GPL-3.0, so linking it into a distributed Android binary would force
/// the whole app to GPL. It is therefore used at *build* time only (see
/// ml/export), baking its output into a lexicon that ships with the pack,
/// while the runtime does a pure table lookup. That keeps the app's licence
/// clean and removes a native dependency from the hot path.
///
/// Two tables per pack:
///   graphemes.tsv  grapheme<TAB>tokenId   - always present
///   lexicon.tsv    word<TAB>id id id      - optional, for irregular words
class Phonemizer {
  Phonemizer._(this._graphemes, this._lexicon, this._padId, this._unknownId);

  final Map<String, int> _graphemes;
  final Map<String, List<int>> _lexicon;
  final int _padId;
  final int _unknownId;

  int get padId => _padId;

  static Phonemizer load({
    required String graphemesPath,
    String? lexiconPath,
  }) {
    final File graphemeFile = File(graphemesPath);
    if (!graphemeFile.existsSync()) {
      throw StateError('graphemes.tsv missing at $graphemesPath');
    }

    final Map<String, int> graphemes = <String, int>{};
    for (final String line in graphemeFile.readAsLinesSync()) {
      if (line.isEmpty || line.startsWith('#')) continue;
      final int tab = line.indexOf('\t');
      if (tab <= 0) continue;
      final int? id = int.tryParse(line.substring(tab + 1).trim());
      if (id == null) continue;
      graphemes[line.substring(0, tab)] = id;
    }

    final Map<String, List<int>> lexicon = <String, List<int>>{};
    if (lexiconPath != null && File(lexiconPath).existsSync()) {
      for (final String line in File(lexiconPath).readAsLinesSync()) {
        if (line.isEmpty || line.startsWith('#')) continue;
        final int tab = line.indexOf('\t');
        if (tab <= 0) continue;
        final List<int> ids = line
            .substring(tab + 1)
            .trim()
            .split(RegExp(r'\s+'))
            .map(int.tryParse)
            .whereType<int>()
            .toList(growable: false);
        if (ids.isNotEmpty) lexicon[line.substring(0, tab)] = ids;
      }
    }

    return Phonemizer._(
      graphemes,
      lexicon,
      graphemes['<pad>'] ?? 0,
      graphemes['<unk>'] ?? graphemes['<pad>'] ?? 0,
    );
  }

  /// Converts text to token ids.
  ///
  /// Word-level lexicon lookup first, then grapheme fallback. Indic scripts
  /// are largely phonetic, so the grapheme path is accurate for almost
  /// everything; the lexicon exists for loanwords and abbreviations where it
  /// is not.
  List<int> encode(String text) {
    final List<int> ids = <int>[];

    for (final String word in text.split(' ')) {
      if (word.isEmpty) continue;

      final List<int>? known = _lexicon[word];
      if (known != null) {
        ids.addAll(known);
      } else {
        // Longest-match first, so a two-character conjunct mapped as a unit
        // wins over its parts.
        int index = 0;
        while (index < word.length) {
          final int twoEnd = index + 2 <= word.length ? index + 2 : index + 1;
          final String pair = word.substring(index, twoEnd);
          final int? pairId = pair.length == 2 ? _graphemes[pair] : null;
          if (pairId != null) {
            ids.add(pairId);
            index += 2;
            continue;
          }
          final String single = word.substring(index, index + 1);
          ids.add(_graphemes[single] ?? _unknownId);
          index += 1;
        }
      }

      final int? space = _graphemes[' '];
      if (space != null) ids.add(space);
    }

    // VITS-family models are trained with a blank interleaved between tokens
    // and expect a pad at each end; without it the first phoneme is clipped.
    return <int>[_padId, ...ids, _padId];
  }

  bool get isEmpty => _graphemes.isEmpty;
}
