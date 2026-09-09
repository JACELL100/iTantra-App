/// One supported language.
class LanguageSpec {
  const LanguageSpec({
    required this.tag,
    required this.englishName,
    required this.endonym,
    this.hasNativeDigits = true,
  });

  final String tag;
  final String englishName;

  /// The language's own name, shown in the picker. A person who reads only
  /// Odia should not have to find "Odia" written in Latin script.
  final String endonym;

  final bool hasNativeDigits;
}

/// The ten languages named in the brief.
class Languages {
  const Languages._();

  static const List<LanguageSpec> all = <LanguageSpec>[
    LanguageSpec(
      tag: 'hi-IN',
      englishName: 'Hindi',
      endonym: '\u0939\u093F\u0928\u094D\u0926\u0940',
    ),
    LanguageSpec(
      tag: 'bn-IN',
      englishName: 'Bengali',
      endonym: '\u09AC\u09BE\u0982\u09B2\u09BE',
    ),
    LanguageSpec(
      tag: 'gu-IN',
      englishName: 'Gujarati',
      endonym: '\u0A97\u0AC1\u0A9C\u0AB0\u0ABE\u0AA4\u0AC0',
    ),
    LanguageSpec(
      tag: 'mr-IN',
      englishName: 'Marathi',
      endonym: '\u092E\u0930\u093E\u0920\u0940',
    ),
    LanguageSpec(
      tag: 'kn-IN',
      englishName: 'Kannada',
      endonym: '\u0C95\u0CA8\u0CCD\u0CA8\u0CA1',
    ),
    LanguageSpec(
      tag: 'ml-IN',
      englishName: 'Malayalam',
      endonym: '\u0D2E\u0D32\u0D2F\u0D3E\u0D33\u0D02',
    ),
    LanguageSpec(
      tag: 'ta-IN',
      englishName: 'Tamil',
      endonym: '\u0BA4\u0BAE\u0BBF\u0BB4\u0BCD',
    ),
    LanguageSpec(
      tag: 'te-IN',
      englishName: 'Telugu',
      endonym: '\u0C24\u0C46\u0C32\u0C41\u0C17\u0C41',
    ),
    LanguageSpec(
      tag: 'or-IN',
      englishName: 'Odia',
      endonym: '\u0B13\u0B21\u0B3F\u0B06',
    ),
    LanguageSpec(
      tag: 'en-IN',
      englishName: 'English (India)',
      endonym: 'English',
      hasNativeDigits: false,
    ),
  ];

  static LanguageSpec? byTag(String tag) {
    for (final LanguageSpec spec in all) {
      if (spec.tag == tag) return spec;
    }
    return null;
  }

  /// Short label for chips and message bubbles.
  static String labelFor(String tag) => byTag(tag)?.endonym ?? tag;

  static String englishNameFor(String tag) =>
      byTag(tag)?.englishName ?? tag;
}
