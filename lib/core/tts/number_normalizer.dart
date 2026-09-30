/// Numbers, times and common symbols spelled out for the synthesiser.
///
/// A VITS-style model trained on read speech has never seen the digit "7";
/// feeding it one produces either silence or a guess. Since the most
/// operationally important messages in this app are exactly the ones full of
/// numbers - coordinates, casualty counts, times, frequencies - the frontend
/// must expand them, and it must do so in the target language, not English.
///
/// Coverage here is deliberately shallow but correct: digits, teens, tens,
/// hundred/thousand/lakh, and clock times. Full grammatical number agreement
/// for ten languages is a research project; reading "47" as "four seven" in
/// the right language is intelligible and always available, and that is the
/// bar an alert has to clear.
class NumberNormalizer {
  const NumberNormalizer._();

  /// Digit names per language, index 0-9.
  static const Map<String, List<String>> _digits = <String, List<String>>{
    'hi-IN': <String>[
      'shoonya', 'ek', 'do', 'teen', 'chaar',
      'paanch', 'chhah', 'saat', 'aath', 'nau',
    ],
    'mr-IN': <String>[
      'shunya', 'ek', 'don', 'teen', 'chaar',
      'paach', 'saha', 'saat', 'aath', 'nau',
    ],
    'bn-IN': <String>[
      'shunno', 'ek', 'dui', 'teen', 'chaar',
      'paach', 'chhoy', 'saat', 'aat', 'noy',
    ],
    'gu-IN': <String>[
      'shunya', 'ek', 'be', 'tran', 'chaar',
      'paanch', 'chha', 'saat', 'aath', 'nav',
    ],
    'or-IN': <String>[
      'shunya', 'eka', 'dui', 'tini', 'chaari',
      'paancha', 'chha', 'saata', 'aatha', 'na',
    ],
    'ta-IN': <String>[
      'poojiyam', 'onru', 'irandu', 'moondru', 'naangu',
      'aindhu', 'aaru', 'ezhu', 'ettu', 'onbadhu',
    ],
    'te-IN': <String>[
      'sunna', 'okati', 'rendu', 'moodu', 'naalugu',
      'aidu', 'aaru', 'edu', 'enimidi', 'tommidi',
    ],
    'kn-IN': <String>[
      'sonne', 'ondu', 'eradu', 'mooru', 'naalku',
      'aidu', 'aaru', 'elu', 'entu', 'ombattu',
    ],
    'ml-IN': <String>[
      'poojyam', 'onnu', 'randu', 'moonnu', 'naalu',
      'anchu', 'aaru', 'ezhu', 'ettu', 'onpathu',
    ],
    'en-IN': <String>[
      'zero', 'one', 'two', 'three', 'four',
      'five', 'six', 'seven', 'eight', 'nine',
    ],
  };

  /// Scale words. Lakh and crore are included because an Indian speaker reads
  /// 250000 as "two lakh fifty thousand", not "two hundred fifty thousand".
  static const Map<String, Map<String, String>> _scales =
      <String, Map<String, String>>{
    'hi-IN': <String, String>{
      'hundred': 'sau',
      'thousand': 'hazaar',
      'lakh': 'laakh',
      'crore': 'karod',
      'point': 'dashamlav',
    },
    'mr-IN': <String, String>{
      'hundred': 'shambhar',
      'thousand': 'hajaar',
      'lakh': 'lakh',
      'crore': 'koti',
      'point': 'dashaansh',
    },
    'bn-IN': <String, String>{
      'hundred': 'sho',
      'thousand': 'hajar',
      'lakh': 'lokkho',
      'crore': 'koti',
      'point': 'doshomik',
    },
    'gu-IN': <String, String>{
      'hundred': 'so',
      'thousand': 'hajaar',
      'lakh': 'lakh',
      'crore': 'karod',
      'point': 'dashansh',
    },
    'or-IN': <String, String>{
      'hundred': 'sha',
      'thousand': 'hajaara',
      'lakh': 'lakhya',
      'crore': 'koti',
      'point': 'dashamika',
    },
    'ta-IN': <String, String>{
      'hundred': 'nooru',
      'thousand': 'aayiram',
      'lakh': 'laksham',
      'crore': 'kodi',
      'point': 'pulli',
    },
    'te-IN': <String, String>{
      'hundred': 'vanda',
      'thousand': 'vela',
      'lakh': 'laksha',
      'crore': 'koti',
      'point': 'bindhuvu',
    },
    'kn-IN': <String, String>{
      'hundred': 'nooru',
      'thousand': 'saavira',
      'lakh': 'laksha',
      'crore': 'koti',
      'point': 'chukke',
    },
    'ml-IN': <String, String>{
      'hundred': 'nooru',
      'thousand': 'aayiram',
      'lakh': 'laksham',
      'crore': 'kodi',
      'point': 'dashamsham',
    },
    'en-IN': <String, String>{
      'hundred': 'hundred',
      'thousand': 'thousand',
      'lakh': 'lakh',
      'crore': 'crore',
      'point': 'point',
    },
  };

  /// First code point of each script's own digit block. Text arriving from
  /// the recogniser can contain either ASCII or native digits.
  static const Map<String, int> _nativeDigitBase = <String, int>{
    'hi-IN': 0x0966,
    'mr-IN': 0x0966,
    'bn-IN': 0x09E6,
    'gu-IN': 0x0AE6,
    'or-IN': 0x0B66,
    'ta-IN': 0x0BE6,
    'te-IN': 0x0C66,
    'kn-IN': 0x0CE6,
    'ml-IN': 0x0D66,
  };

  /// Main entry point: replaces every number in [text] with words.
  static String normalize(String text, String languageTag) {
    final List<String>? digits = _digits[languageTag];
    if (digits == null) return text;

    final String ascii = _toAsciiDigits(text, languageTag);
    final String withTimes = _expandTimes(ascii, languageTag);

    return withTimes.replaceAllMapped(
      RegExp(r'\d+(?:\.\d+)?'),
      (Match match) => _speakNumber(match.group(0)!, languageTag),
    );
  }

  /// Converts native digits to ASCII so one code path handles both.
  static String _toAsciiDigits(String text, String languageTag) {
    final int? base = _nativeDigitBase[languageTag];
    if (base == null) return text;
    final StringBuffer out = StringBuffer();
    for (final int rune in text.runes) {
      if (rune >= base && rune <= base + 9) {
        out.write(rune - base);
      } else {
        out.writeCharCode(rune);
      }
    }
    return out.toString();
  }

  /// "14:30" becomes the spoken equivalent of "fourteen thirty".
  static String _expandTimes(String text, String languageTag) {
    return text.replaceAllMapped(RegExp(r'\b(\d{1,2}):(\d{2})\b'),
        (Match match) {
      final String hour = _speakNumber(match.group(1)!, languageTag);
      final String minute = match.group(2) == '00'
          ? ''
          : ' ${_speakNumber(match.group(2)!, languageTag)}';
      return '$hour$minute';
    });
  }

  static String _speakNumber(String token, String languageTag) {
    final List<String> digits = _digits[languageTag]!;
    final Map<String, String> scales = _scales[languageTag]!;

    if (token.contains('.')) {
      final List<String> parts = token.split('.');
      final String whole = _speakNumber(parts[0], languageTag);
      final String fraction = parts[1]
          .split('')
          .map((String d) => digits[int.parse(d)])
          .join(' ');
      return '$whole ${scales['point']} $fraction';
    }

    final int? value = int.tryParse(token);
    if (value == null) return token;

    // Digit strings that are identifiers rather than quantities - a five
    // digit grid reference, say - are read digit by digit, which is how
    // radio operators read them anyway and avoids inventing wrong grammar.
    // Round quantities (ending in 00, like 200000 for 2 lakh) are spoken with scale words.
    final bool isRoundQuantity = value >= 100 && value % 100 == 0;
    if ((token.length > 4 && !isRoundQuantity) ||
        (token.length > 1 && token.startsWith('0')) ||
        token.length > 9) {
      return token.split('').map((String d) => digits[int.parse(d)]).join(' ');
    }

    return _speakInteger(value, digits, scales);
  }

  static String _speakInteger(
    int value,
    List<String> digits,
    Map<String, String> scales,
  ) {
    if (value < 10) return digits[value];

    final List<String> parts = <String>[];

    void take(int unit, String word) {
      final int count = value ~/ unit;
      if (count == 0) return;
      parts.add('${_speakInteger(count, digits, scales)} $word');
      value = value % unit;
    }

    take(10000000, scales['crore']!);
    take(100000, scales['lakh']!);
    take(1000, scales['thousand']!);
    take(100, scales['hundred']!);

    if (value > 0) {
      // Two-digit remainders are read digit by digit rather than with a
      // dedicated word for each of 11-99. Every one of these languages has
      // irregular teens and tens, and a wrong word is worse than a
      // digit-wise reading that is always understood.
      parts.add(value < 10
          ? digits[value]
          : value
              .toString()
              .split('')
              .map((String d) => digits[int.parse(d)])
              .join(' '));
    }

    return parts.join(' ');
  }
}
