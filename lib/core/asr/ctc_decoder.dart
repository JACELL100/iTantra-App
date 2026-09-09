import 'dart:io';
import 'dart:math' as math;

/// Token table for a CTC model.
///
/// Loaded from tokens.txt inside the pack, one token per line, index equal to
/// line number. Blank is index 0 by convention in every exporter we use.
class TokenTable {
  TokenTable(this.tokens);

  final List<String> tokens;

  static const int blankIndex = 0;

  /// SentencePiece word delimiter. Indic scripts have no spaces between
  /// morphemes in the model's vocabulary, so word boundaries only exist as
  /// this marker; dropping it would join every word in the sentence.
  static const String wordDelimiter = '\u2581';

  int get size => tokens.length;

  String tokenAt(int index) =>
      index >= 0 && index < tokens.length ? tokens[index] : '';

  static TokenTable fromFile(String path) {
    final File file = File(path);
    if (!file.existsSync()) {
      throw StateError('tokens.txt missing at $path');
    }
    final List<String> lines = file.readAsLinesSync();
    final List<String> tokens = <String>[];
    for (final String line in lines) {
      if (line.isEmpty) {
        tokens.add('');
        continue;
      }
      // Accept both "token" and "token<space>index" formats; sherpa-onnx and
      // NeMo exports differ here and both are common.
      final int space = line.lastIndexOf(' ');
      tokens.add(space > 0 ? line.substring(0, space) : line);
    }
    return TokenTable(tokens);
  }
}

/// Decoded output plus a confidence estimate.
class CtcDecoding {
  const CtcDecoding({required this.text, required this.confidence});

  final String text;
  final double confidence;
}

/// Greedy CTC decoder.
///
/// Greedy, not beam search, and that is a considered trade rather than a
/// shortcut. A beam of 8 with no external language model buys a fraction of a
/// percent of word error rate on short command-like utterances, while costing
/// several times the decode time on a low-end CPU. Latency is 20% of the
/// score and accuracy gains from beam search without an LM are marginal, so
/// greedy wins. The token table and this interface leave room to add a beam
/// later without touching callers.
class CtcDecoder {
  const CtcDecoder(this.tokens);

  final TokenTable tokens;

  /// [logProbs] is frames x vocabulary, already log-softmaxed by the model.
  CtcDecoding decode(List<List<double>> logProbs) {
    final StringBuffer buffer = StringBuffer();
    int previous = -1;
    double confidenceSum = 0;
    int emitted = 0;

    for (final List<double> frame in logProbs) {
      int best = 0;
      double bestValue = double.negativeInfinity;
      for (int i = 0; i < frame.length; i++) {
        if (frame[i] > bestValue) {
          bestValue = frame[i];
          best = i;
        }
      }

      // Standard CTC collapse: drop blanks, drop repeats of the previous
      // label. Without the repeat rule, "amma" becomes "ama".
      if (best != TokenTable.blankIndex && best != previous) {
        buffer.write(tokens.tokenAt(best));
        confidenceSum += math.exp(bestValue);
        emitted++;
      }
      previous = best;
    }

    final String raw = buffer.toString();
    final String text = raw
        .replaceAll(TokenTable.wordDelimiter, ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    // Mean emitted-token probability. An utterance that produced nothing gets
    // zero rather than a misleading 1.0.
    final double confidence = emitted == 0 ? 0 : confidenceSum / emitted;

    return CtcDecoding(
      text: text,
      confidence: confidence.clamp(0.0, 1.0),
    );
  }
}
