import 'package:flutter_test/flutter_test.dart';
import 'package:itantra/core/tts/number_normalizer.dart';

void main() {
  group('NumberNormalizer', () {
    test('expands ASCII digits into Hindi words', () {
      final String out = NumberNormalizer.normalize('7', 'hi-IN');
      expect(out, 'saat');
    });

    test('leaves no digits behind in any supported language', () {
      // The point of the frontend: a digit that reaches the acoustic model
      // produces silence or a guess, so none may survive.
      const List<String> tags = <String>[
        'hi-IN', 'bn-IN', 'gu-IN', 'mr-IN', 'kn-IN',
        'ml-IN', 'ta-IN', 'te-IN', 'or-IN', 'en-IN',
      ];
      for (final String tag in tags) {
        final String out =
            NumberNormalizer.normalize('grid 47 at 14:30', tag);
        expect(RegExp(r'\d').hasMatch(out), isFalse,
            reason: 'digits survived for $tag: $out');
      }
    });

    test('reads native Devanagari digits', () {
      // \u0968 is Devanagari two.
      final String out = NumberNormalizer.normalize('\u0968', 'hi-IN');
      expect(out, 'do');
    });

    test('reads long digit strings one digit at a time', () {
      // A five-digit grid reference is an identifier, not a quantity, and
      // radio operators read it digit by digit anyway.
      final String out = NumberNormalizer.normalize('12345', 'en-IN');
      expect(out, 'one two three four five');
    });

    test('uses lakh rather than hundred thousand', () {
      final String out = NumberNormalizer.normalize('200000', 'hi-IN');
      expect(out, contains('laakh'));
    });

    test('expands a decimal with a language-specific point word', () {
      final String out = NumberNormalizer.normalize('1.5', 'hi-IN');
      expect(out, 'ek dashamlav paanch');
    });

    test('passes text through for an unknown language', () {
      expect(NumberNormalizer.normalize('7', 'xx-XX'), '7');
    });
  });
}
