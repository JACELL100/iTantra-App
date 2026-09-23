import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The design system.
///
/// Three deliberate choices, all driven by field use rather than taste:
///
///  * **High contrast, no decorative low-opacity greys.** This gets read in
///    direct sunlight on a cheap LCD and never on a calibrated monitor.
///  * **Alert red is reserved.** Nothing decorative uses it, so red on screen
///    always means the same thing. That is a safety property, not a style one.
///  * **Generous line height.** Ten scripts share this UI, and Indic
///    conjuncts - matras above, virama and chillus below - are clipped by the
///    default leading. [heightFactor] is the smallest value that never clipped
///    in testing.
///
/// Both themes are first-class. Dark is not a tinted inversion of light: field
/// use is often at night, and the dark scheme is the one that gets tuned first.
class ItantraTheme {
  const ItantraTheme._();

  // ---------------------------------------------------------------------------
  // Brand
  // ---------------------------------------------------------------------------

  /// Saffron. "Something is happening here right now" - transmit, record.
  static const Color saffron = Color(0xFFE8590C);
  static const Color saffronBright = Color(0xFFFF7A2F);

  /// Deep indigo. The calm, structural colour: received content, chrome.
  static const Color deepBlue = Color(0xFF0B4F8A);
  static const Color deepBlueBright = Color(0xFF2A7FC4);

  /// Reserved. Distress, and nothing else, ever.
  static const Color alertRed = Color(0xFFC1121F);
  static const Color alertRedBright = Color(0xFFFF4D5E);

  /// Caution: low confidence, degraded link, advisory warnings.
  static const Color amber = Color(0xFFB4690E);

  /// Confirmed good: durable delivery, acknowledged.
  static const Color success = Color(0xFF1B7F4D);

  /// Minimum line height for all text. See the class comment.
  static const double heightFactor = 1.45;

  // ---------------------------------------------------------------------------
  // Motion
  // ---------------------------------------------------------------------------

  /// Shared animation timings, so nothing in the app moves at a private speed.
  static const Duration instant = Duration(milliseconds: 90);
  static const Duration quick = Duration(milliseconds: 180);
  static const Duration medium = Duration(milliseconds: 320);
  static const Duration slow = Duration(milliseconds: 560);
  static const Duration deliberate = Duration(milliseconds: 900);

  /// A gentle overshoot. Used for anything that appears in response to a
  /// deliberate user action, so the app feels like it acknowledged the tap.
  static const Curve emphasized = Cubic(0.2, 0.0, 0.0, 1.0);
  static const Curve emphasizeCurve = Cubic(0.2, 0.0, 0.0, 1.0);
  static const Curve settle = Curves.easeOutCubic;
  static const Curve enter = Curves.easeOutQuint;

  // ---------------------------------------------------------------------------
  // Schemes
  // ---------------------------------------------------------------------------

  static ThemeData light() => _build(_lightScheme, Brightness.light);
  static ThemeData dark() => _build(_darkScheme, Brightness.dark);

  static const ColorScheme _lightScheme = ColorScheme(
    brightness: Brightness.light,
    primary: deepBlue,
    onPrimary: Colors.white,
    primaryContainer: Color(0xFFD6E7F7),
    onPrimaryContainer: Color(0xFF062F55),
    secondary: saffron,
    onSecondary: Colors.white,
    secondaryContainer: Color(0xFFFFE0CC),
    onSecondaryContainer: Color(0xFF5C2100),
    tertiary: Color(0xFF1B7F4D),
    onTertiary: Colors.white,
    tertiaryContainer: Color(0xFFC8EBD8),
    onTertiaryContainer: Color(0xFF07351F),
    error: alertRed,
    onError: Colors.white,
    errorContainer: Color(0xFFFFDAD8),
    onErrorContainer: Color(0xFF410004),
    surface: Color(0xFFFAFAF8),
    onSurface: Color(0xFF12161A),
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFF3F5F6),
    surfaceContainer: Color(0xFFEDF0F2),
    surfaceContainerHigh: Color(0xFFE5E9EC),
    surfaceContainerHighest: Color(0xFFDCE2E6),
    onSurfaceVariant: Color(0xFF40484E),
    outline: Color(0xFF8A939A),
    outlineVariant: Color(0xFFC3CBCF),
    shadow: Color(0x1A000000),
    scrim: Color(0x99000000),
    inverseSurface: Color(0xFF232A2F),
    onInverseSurface: Color(0xFFECF1F3),
    inversePrimary: Color(0xFF9CCDF5),
  );

  static const ColorScheme _darkScheme = ColorScheme(
    brightness: Brightness.dark,
    // Saffron leads in the dark theme: on a dim screen in the dark, the warm
    // colour is the one that reads as "live" without being blinding.
    primary: saffronBright,
    onPrimary: Color(0xFF2A0F00),
    primaryContainer: Color(0xFF7A3200),
    onPrimaryContainer: Color(0xFFFFDCC7),
    secondary: Color(0xFF9CCDF5),
    onSecondary: Color(0xFF04223A),
    secondaryContainer: Color(0xFF0B3E68),
    onSecondaryContainer: Color(0xFFD3E8FB),
    tertiary: Color(0xFF6FD8A6),
    onTertiary: Color(0xFF00291A),
    tertiaryContainer: Color(0xFF0A5133),
    onTertiaryContainer: Color(0xFFC7F2DC),
    error: alertRedBright,
    onError: Color(0xFF3A0006),
    errorContainer: Color(0xFF8C0F1C),
    onErrorContainer: Color(0xFFFFDAD8),
    surface: Color(0xFF0D1114),
    onSurface: Color(0xFFE7EDF0),
    surfaceContainerLowest: Color(0xFF080B0D),
    surfaceContainerLow: Color(0xFF151A1E),
    surfaceContainer: Color(0xFF1B2126),
    surfaceContainerHigh: Color(0xFF232A30),
    surfaceContainerHighest: Color(0xFF2C343B),
    onSurfaceVariant: Color(0xFFB4BEC6),
    outline: Color(0xFF6C767E),
    outlineVariant: Color(0xFF39424A),
    shadow: Color(0x66000000),
    scrim: Color(0xCC000000),
    inverseSurface: Color(0xFFE7EDF0),
    onInverseSurface: Color(0xFF1B2126),
    inversePrimary: Color(0xFF0B4F8A),
  );

  // ---------------------------------------------------------------------------
  // Component themes
  // ---------------------------------------------------------------------------

  static ThemeData _build(ColorScheme scheme, Brightness brightness) {
    final bool isDark = brightness == Brightness.dark;

    // Material's own text scale is meaningless for Indic scripts, so the
    // scale is rebuilt from a base with an explicit leading factor.
    final TextTheme base = Typography.material2021(platform: TargetPlatform.android)
        .black
        .apply(
          bodyColor: scheme.onSurface,
          displayColor: scheme.onSurface,
        );

    final TextTheme text = base.copyWith(
      displayLarge: _spaced(base.displayLarge, -0.5),
      displayMedium: _spaced(base.displayMedium, -0.4),
      displaySmall: _spaced(base.displaySmall, -0.3),
      headlineLarge: _spaced(base.headlineLarge, -0.2, FontWeight.w700),
      headlineMedium: _spaced(base.headlineMedium, -0.2, FontWeight.w700),
      headlineSmall: _spaced(base.headlineSmall, -0.1, FontWeight.w700),
      titleLarge: _spaced(base.titleLarge, 0, FontWeight.w700),
      titleMedium: _spaced(base.titleMedium, 0.1, FontWeight.w600),
      titleSmall: _spaced(base.titleSmall, 0.1, FontWeight.w600),
      bodyLarge: _spaced(base.bodyLarge, 0),
      bodyMedium: _spaced(base.bodyMedium, 0),
      bodySmall: _spaced(base.bodySmall, 0),
      labelLarge: _spaced(base.labelLarge, 0.3, FontWeight.w600),
      labelMedium: _spaced(base.labelMedium, 0.5, FontWeight.w600),
      labelSmall: _spaced(base.labelSmall, 0.6, FontWeight.w600),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      textTheme: text,
      extensions: <ThemeExtension<dynamic>>[
        ItantraPalette.forBrightness(brightness),
      ],
      // The app draws its own backgrounds; a page transition that flashes a
      // different surface colour is the single most jarring thing you can do
      // to someone whose eyes are dark-adapted.
      scaffoldBackgroundColor: scheme.surface,
      canvasColor: scheme.surface,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,

      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleLarge,
        systemOverlayStyle:
            isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      ),

      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
      ),

      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.7),
        thickness: 1,
        space: 1,
      ),

      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        titleTextStyle: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
        subtitleTextStyle: text.bodySmall
            ?.copyWith(color: scheme.onSurfaceVariant, height: 1.35),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          // 52 dp: this is used with gloves on.
          minimumSize: const Size.fromHeight(52),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: text.labelLarge?.copyWith(fontSize: 16),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          side: BorderSide(color: scheme.outline.withValues(alpha: 0.8)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: text.labelLarge?.copyWith(fontSize: 16),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(64, 44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: text.labelLarge,
        ),
      ),

      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(48, 48),
          highlightColor: scheme.primary.withValues(alpha: 0.12),
        ),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        selectedColor: scheme.primaryContainer,
        side: BorderSide(color: scheme.outlineVariant),
        labelStyle: text.labelMedium,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),

      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          minimumSize: WidgetStateProperty.all(const Size(0, 48)),
          side: WidgetStateProperty.all(
            BorderSide(color: scheme.outlineVariant),
          ),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          textStyle: WidgetStateProperty.all(text.labelLarge),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        hintStyle: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
        titleTextStyle: text.titleLarge,
        contentTextStyle: text.bodyMedium,
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: scheme.surfaceContainerLow,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),

      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: text.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        actionTextColor: isDark ? saffronBright : const Color(0xFF9CCDF5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        insetPadding: const EdgeInsets.all(16),
      ),

      bannerTheme: MaterialBannerThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        contentTextStyle: text.bodyMedium,
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
          if (states.contains(WidgetState.selected)) return scheme.onPrimary;
          return scheme.outline;
        }),
        trackColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
          if (states.contains(WidgetState.selected)) return scheme.primary;
          return scheme.surfaceContainerHighest;
        }),
      ),

      sliderTheme: SliderThemeData(
        activeTrackColor: scheme.primary,
        thumbColor: scheme.primary,
        inactiveTrackColor: scheme.surfaceContainerHighest,
        trackHeight: 6,
        // Bigger than Material's default: a slider used with cold hands needs
        // a target, not a hint.
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 13),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 26),
      ),

      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((Set<WidgetState> states) =>
            states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.outline),
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
        circularTrackColor: scheme.surfaceContainerHighest,
      ),

      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(10),
        ),
        textStyle: text.bodySmall?.copyWith(color: scheme.onInverseSurface),
        waitDuration: const Duration(milliseconds: 400),
      ),

      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
  }

  static TextStyle? _spaced(
    TextStyle? style,
    double letterSpacing, [
    FontWeight? weight,
  ]) {
    if (style == null) return null;
    return style.copyWith(
      height: heightFactor,
      letterSpacing: letterSpacing,
      fontWeight: weight ?? style.fontWeight,
    );
  }
}

/// Extra tokens the Material [ColorScheme] has no slot for.
///
/// Read as `context.palette.signalGlow`. Kept as a theme extension rather than
/// a bag of constants so a widget rebuilds correctly when the user switches
/// between light and dark at runtime.
@immutable
class ItantraPalette extends ThemeExtension<ItantraPalette> {
  const ItantraPalette({
    required this.signalGlow,
    required this.receivedBubble,
    required this.sentBubble,
    required this.alertBubble,
    required this.pageGradient,
    required this.hairline,
    required this.glassFill,
    required this.glassBorder,
  });

  /// The colour of "live microphone", used for the talk button's aura.
  final Color signalGlow;

  final Color receivedBubble;
  final Color sentBubble;
  final Color alertBubble;

  /// Two-stop background gradient for a screen.
  final List<Color> pageGradient;

  /// A 1 px separator that reads as a line rather than a gap.
  final Color hairline;

  /// Translucent fill for a frosted panel over the gradient.
  final Color glassFill;
  final Color glassBorder;

  static const ItantraPalette _light = ItantraPalette(
    signalGlow: Color(0xFFE8590C),
    receivedBubble: Color(0xFFFFFFFF),
    sentBubble: Color(0xFF0B4F8A),
    alertBubble: Color(0xFFC1121F),
    pageGradient: <Color>[Color(0xFFF4F7F9), Color(0xFFE9EEF2)],
    hairline: Color(0xFFD5DCE1),
    glassFill: Color(0xF2FFFFFF),
    glassBorder: Color(0xFFDCE3E8),
  );

  static const ItantraPalette _dark = ItantraPalette(
    signalGlow: Color(0xFFFF7A2F),
    receivedBubble: Color(0xFF1E262C),
    sentBubble: Color(0xFF0F4C7E),
    alertBubble: Color(0xFF8C0F1C),
    pageGradient: <Color>[Color(0xFF0D1114), Color(0xFF121A20)],
    hairline: Color(0xFF2C343B),
    glassFill: Color(0xE61B2126),
    glassBorder: Color(0xFF333C44),
  );

  static ItantraPalette of(BuildContext context) =>
      Theme.of(context).extension<ItantraPalette>() ??
      (Theme.of(context).brightness == Brightness.dark ? _dark : _light);

  /// The palette matching a theme, for widgets that build a [ThemeData] before
  /// an InheritedWidget exists (splash and preview surfaces).
  static ItantraPalette forBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? _dark : _light;

  @override
  ItantraPalette copyWith({
    Color? signalGlow,
    Color? receivedBubble,
    Color? sentBubble,
    Color? alertBubble,
    List<Color>? pageGradient,
    Color? hairline,
    Color? glassFill,
    Color? glassBorder,
  }) =>
      ItantraPalette(
        signalGlow: signalGlow ?? this.signalGlow,
        receivedBubble: receivedBubble ?? this.receivedBubble,
        sentBubble: sentBubble ?? this.sentBubble,
        alertBubble: alertBubble ?? this.alertBubble,
        pageGradient: pageGradient ?? this.pageGradient,
        hairline: hairline ?? this.hairline,
        glassFill: glassFill ?? this.glassFill,
        glassBorder: glassBorder ?? this.glassBorder,
      );

  @override
  ItantraPalette lerp(ThemeExtension<ItantraPalette>? other, double t) {
    if (other is! ItantraPalette) return this;
    return ItantraPalette(
      signalGlow: Color.lerp(signalGlow, other.signalGlow, t)!,
      receivedBubble: Color.lerp(receivedBubble, other.receivedBubble, t)!,
      sentBubble: Color.lerp(sentBubble, other.sentBubble, t)!,
      alertBubble: Color.lerp(alertBubble, other.alertBubble, t)!,
      pageGradient: <Color>[
        Color.lerp(pageGradient.first, other.pageGradient.first, t)!,
        Color.lerp(pageGradient.last, other.pageGradient.last, t)!,
      ],
      hairline: Color.lerp(hairline, other.hairline, t)!,
      glassFill: Color.lerp(glassFill, other.glassFill, t)!,
      glassBorder: Color.lerp(glassBorder, other.glassBorder, t)!,
    );
  }
}

/// Spacing tokens.
///
/// Every horizontal inset in the app comes from here. Before this existed each
/// screen picked its own number - 8, 12, 16, 20, 24 - so two sections on the
/// same screen could sit 12 px apart from the edge, which is what made the
/// layout read as crowded rather than deliberate. One constant, applied in one
/// place, is the whole fix.
///
/// 20 dp on a phone rather than Material's 16: the target devices are cheap
/// handsets with rounded corners and often a case, and 16 puts the first
/// character of a line hard against the edge of the visible area.
abstract final class Gutters {
  const Gutters._();

  /// Horizontal inset on a phone.
  static const double compact = 20;

  /// Horizontal inset on a tablet or a phone in landscape.
  static const double wide = 32;

  /// Widest a single column of content is allowed to get. Past this, prose
  /// becomes hard to track and a two-column layout is the right answer.
  static const double contentMaxWidth = 760;

  /// Vertical breathing room above the first element of a page body.
  static const double pageTop = 10;

  /// Space left under the last element, so content never ends flush against the
  /// bottom edge - which reads as "the app stopped" rather than "there is more".
  static const double pageBottom = 40;

  static double of(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= 720 ? wide : compact;

  static EdgeInsets page(BuildContext context) =>
      EdgeInsets.symmetric(horizontal: of(context));

  /// Bottom inset that clears both the navigation bar and the last item.
  static double bottomSpace(BuildContext context, {double extra = 0}) =>
      pageBottom + MediaQuery.viewPaddingOf(context).bottom + extra;
}

/// Shorthands so widgets stay readable.
extension ItantraThemeContext on BuildContext {
  ColorScheme get colors => Theme.of(this).colorScheme;
  TextTheme get texts => Theme.of(this).textTheme;
  ItantraPalette get palette => ItantraPalette.of(this);
  bool get isDark => Theme.of(this).brightness == Brightness.dark;

  /// True when the window is wide enough for a two-column layout. Tablets and
  /// phones in landscape cross this; a portrait phone does not.
  bool get isWide => MediaQuery.sizeOf(this).width >= 720;

  /// True when the viewport is short enough that vertical chrome has to shrink
  /// (a phone in landscape, typically).
  bool get isShort => MediaQuery.sizeOf(this).height < 640;

  /// Honours the OS accessibility text scale, clamped to a range the layout
  /// still survives. Refusing to scale at all would break the single most
  /// important accessibility requirement this app has.
  double get textScale =>
      MediaQuery.textScalerOf(this).scale(1.0).clamp(0.85, 2.0);

  /// The canonical horizontal inset for this window size.
  double get gutter => Gutters.of(this);
}
