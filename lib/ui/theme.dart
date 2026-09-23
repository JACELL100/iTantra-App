import 'package:flutter/material.dart';

/// Colours and type.
///
/// Three deliberate choices, all driven by field use rather than taste:
///  * High contrast, no low-opacity greys. This gets read in sunlight.
///  * Alert red is reserved. Nothing decorative uses it, so red on screen
///    always means the same thing.
///  * Generous line height, because ten scripts share this UI and Indic
///    conjuncts get clipped by tight leading.
class ItantraTheme {
  const ItantraTheme._();

  static const Color saffron = Color(0xFFE8590C);
  static const Color deepBlue = Color(0xFF0B4F8A);
  static const Color alertRed = Color(0xFFC1121F);

  /// Line height multiplier for Indic scripts (Devanagari, Bengali, Tamil, Malayalam).
  /// 1.45 is the smallest value that never clips conjuncts in testing.
  static const double heightFactor = 1.45;

  static ThemeData light() => _base(Brightness.light);

  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness brightness) {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: deepBlue,
      brightness: brightness,
      primary: brightness == Brightness.light ? deepBlue : saffron,
      error: alertRed,
    );

    final TextTheme text = Typography.material2021().black.apply(
          bodyColor: scheme.onSurface,
          displayColor: scheme.onSurface,
          // Devanagari, Bengali, Tamil and Malayalam conjuncts need vertical
          // room; 1.45 is the smallest value that never clipped in testing.
          heightFactor: 1.45,
        );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      textTheme: brightness == Brightness.light
          ? text
          : text.apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        centerTitle: false,
        elevation: 0,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          // 52 dp minimum: this is used with gloves on.
          minimumSize: const Size.fromHeight(52),
          textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          textStyle: const TextStyle(fontSize: 17),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
      ),
    );
  }
}
