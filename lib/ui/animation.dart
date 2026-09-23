import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'theme.dart';

/// Motion primitives.
///
/// Everything animated in this app comes from here, so the whole interface
/// moves at one speed and with one personality. Two rules are behind all of it:
///
///  * **Motion explains, it does not decorate.** An entrance tells you
///    something appeared. A pulse tells you the microphone is live. A bar
///    meter tells you the microphone can hear you. Nothing moves purely to
///    look alive, because on a distress device a moving thing is a claim.
///  * **Every animation is short and cheap.** This runs on a 2 GB phone with
///    the recogniser resident; a decorative animation that drops frames while
///    the user is reading a message is worse than no animation at all.

/// Fades and lifts a child into place once, on first build.
///
/// Used to stagger list entries: pass an increasing [index] and each item
/// arrives a few tens of milliseconds after the one above it, which reads as
/// "this message arrived" rather than "this list jumped".
class FadeSlideIn extends StatefulWidget {
  const FadeSlideIn({
    super.key,
    required this.child,
    this.index = 0,
    this.delay = const Duration(milliseconds: 45),
    this.offset = 14,
    this.duration = ItantraTheme.medium,
    this.animate = true,
  });

  final Widget child;

  /// Position in a sequence. Multiplied by [delay].
  final int index;
  final Duration delay;
  final double offset;
  final Duration duration;

  /// Set false to render the child immediately, for a list that is being
  /// re-sorted rather than appended to.
  final bool animate;

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    // Capped so a long transcript's twentieth row still arrives promptly.
    value: widget.animate ? 0 : 1,
  );

  late final Animation<double> _fade = CurvedAnimation(
    parent: _controller,
    curve: ItantraTheme.enter,
  );

  late final Animation<double> _lift = Tween<double>(
    begin: widget.offset,
    end: 0,
  ).animate(_fade);

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (!widget.animate) return;
    final int steps = widget.index.clamp(0, 12);
    _timer = Timer(widget.delay * steps, () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.animate) return widget.child;
    return AnimatedBuilder(
      animation: _fade,
      builder: (BuildContext context, Widget? child) => Opacity(
        opacity: _fade.value.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, _lift.value),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}

/// Rings that expand outward from the centre, forever.
///
/// This is the app's "the microphone is open" signal. It is deliberately
/// unmistakable at a glance and in peripheral vision, because a user who
/// cannot tell whether they are transmitting will either shout into a dead
/// microphone or stay silent on a live one.
class PulseRings extends StatefulWidget {
  const PulseRings({
    super.key,
    required this.color,
    this.ringCount = 3,
    this.minRadius = 54,
    this.maxRadius = 128,
    this.period = const Duration(milliseconds: 2100),
    this.active = true,
    this.strokeWidth = 2.5,
  });

  final Color color;
  final int ringCount;
  final double minRadius;
  final double maxRadius;
  final Duration period;

  /// When false the rings freeze at zero opacity, so an idle button is still.
  final bool active;
  final double strokeWidth;

  @override
  State<PulseRings> createState() => _PulseRingsState();
}

class _PulseRingsState extends State<PulseRings>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.period,
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant PulseRings old) {
    super.didUpdateWidget(old);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.active && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, _) => CustomPaint(
        painter: _RingPainter(
          progress: _controller.value,
          color: widget.color,
          ringCount: widget.ringCount,
          minRadius: widget.minRadius,
          maxRadius: widget.maxRadius,
          strokeWidth: widget.strokeWidth,
        ),
        size: Size.square(widget.maxRadius * 2.2),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.progress,
    required this.color,
    required this.ringCount,
    required this.minRadius,
    required this.maxRadius,
    required this.strokeWidth,
  });

  final double progress;
  final Color color;
  final int ringCount;
  final double minRadius;
  final double maxRadius;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset centre = Offset(size.width / 2, size.height / 2);

    for (int ring = 0; ring < ringCount; ring++) {
      // Stagger each ring by an equal slice of the period so they chase each
      // other instead of pulsing in unison.
      final double phase = (progress + ring / ringCount) % 1.0;
      final double radius = minRadius + (maxRadius - minRadius) * phase;

      // Fade out as it grows, and fade in from nothing at the start, so no
      // ring ever pops into existence.
      final double alpha = (1 - phase) * (phase < 0.12 ? phase / 0.12 : 1.0);

      canvas.drawCircle(
        centre,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..color = color.withValues(alpha: (alpha * 0.55).clamp(0.0, 1.0)),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.progress != progress || old.color != color;
}

/// A live input meter drawn as a symmetric bar spectrum.
///
/// [level] is 0..1 RMS. The bars are not real FFT bins - computing one per
/// frame would cost more than the recogniser - but deriving the shape
/// deterministically from the level and a slowly advancing phase makes a meter
/// that responds instantly and never looks frozen. The honest part is the
/// height: it is the measured level, not a random walk.
class LiveWaveform extends StatefulWidget {
  const LiveWaveform({
    super.key,
    required this.level,
    required this.active,
    this.barCount = 27,
    this.height = 54,
    this.color,
  });

  final double level;
  final bool active;
  final int barCount;
  final double height;
  final Color? color;

  @override
  State<LiveWaveform> createState() => _LiveWaveformState();
}

class _LiveWaveformState extends State<LiveWaveform>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color tint = widget.color ?? context.palette.signalGlow;
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (BuildContext context, _) => CustomPaint(
          painter: _WavePainter(
            level: widget.level.clamp(0.0, 1.0),
            phase: _controller.value,
            bars: widget.barCount,
            color: tint,
            active: widget.active,
            idleColor: context.colors.outlineVariant,
          ),
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({
    required this.level,
    required this.phase,
    required this.bars,
    required this.color,
    required this.active,
    required this.idleColor,
  });

  final double level;
  final double phase;
  final int bars;
  final Color color;
  final bool active;
  final Color idleColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (bars <= 0) return;

    final double spacing = size.width / bars;
    final double barWidth = math.max(2.0, spacing * 0.42);
    final double mid = size.height / 2;
    final double maxHeight = size.height * 0.92;

    final Paint paint = Paint()..style = PaintingStyle.fill;

    for (int i = 0; i < bars; i++) {
      // A Gaussian envelope centres the energy, which is what a spectrum of
      // speech actually looks like to the eye.
      final double position = bars == 1 ? 0.5 : i / (bars - 1);
      final double envelope =
          math.exp(-math.pow((position - 0.5) * 3.4, 2).toDouble());

      // Each bar gets its own oscillation so the shape ripples inward.
      final double wobble = 0.62 +
          0.38 *
              math.sin((phase * 2 * math.pi) + position * math.pi * 3.2)
                  .abs();

      final double amplitude =
          active ? (0.06 + level * 1.05) * envelope * wobble : 0.0;

      final double barHeight = math.max(
        barWidth,
        (maxHeight * amplitude).clamp(barWidth, maxHeight),
      );

      final double x = i * spacing + (spacing - barWidth) / 2;
      final double top = mid - barHeight / 2;

      if (active) {
        // Brighter at the centre, dimmer at the fringes: same data, but it
        // reads as a single signal rather than a row of blocks.
        paint.color = color.withValues(
          alpha: (0.35 + envelope * 0.65).clamp(0.0, 1.0),
        );
      } else {
        paint.color = idleColor.withValues(alpha: 0.7);
      }

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, top, barWidth, barHeight),
          Radius.circular(barWidth / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      old.level != level || old.phase != phase || old.active != active;
}

/// A frosted, translucent panel.
///
/// Used for the control bar and the status strip. The blur is what makes the
/// transcript underneath read as continuous content rather than being cut off
/// by a hard rectangle, and at these sizes it is cheap enough not to matter on
/// the target hardware.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 24,
    this.blur = 18,
    this.border = true,
    this.fill,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final double blur;
  final bool border;
  final Color? fill;

  @override
  Widget build(BuildContext context) {
    final ItantraPalette palette = context.palette;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: fill ?? palette.glassFill,
            borderRadius: BorderRadius.circular(radius),
            border: border
                ? Border.all(color: palette.glassBorder, width: 1)
                : null,
          ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// The app's page background: a soft two-stop wash with a slow drift.
///
/// A flat fill looks like a wireframe on a large screen. The gradient is
/// static in geometry and animated only in intensity, so it costs one paint
/// per frame and never competes with text for attention.
class GradientBackdrop extends StatefulWidget {
  const GradientBackdrop({
    super.key,
    required this.child,
    this.accent,
    this.intensity = 0.55,
  });

  final Widget child;

  /// Tints one corner. The conversation screen passes the live signal colour.
  final Color? accent;

  /// 0 = flat, 1 = full brand wash.
  final double intensity;

  @override
  State<GradientBackdrop> createState() => _GradientBackdropState();
}

class _GradientBackdropState extends State<GradientBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 14),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ItantraPalette palette = context.palette;
    final Color accent = widget.accent ?? context.colors.primary;

    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        final double t = Curves.easeInOut.transform(_controller.value);
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[
                palette.pageGradient.first,
                Color.lerp(
                  palette.pageGradient.last,
                  accent,
                  widget.intensity * 0.14 * t,
                )!,
                palette.pageGradient.last,
              ],
              stops: <double>[0, 0.45 + 0.1 * t, 1],
            ),
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// A number that animates to its new value.
///
/// Percentile rows and byte counters change while someone is watching them;
/// jumping numbers are hard to read, and a count that slides makes the change
/// itself visible.
class AnimatedCounter extends StatelessWidget {
  const AnimatedCounter({
    super.key,
    required this.value,
    required this.format,
    this.style,
    this.duration = ItantraTheme.slow,
  });

  final double value;
  final String Function(double value) format;
  final TextStyle? style;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: value),
      duration: duration,
      curve: ItantraTheme.settle,
      builder: (BuildContext context, double animated, _) => Text(
        format(animated),
        style: style,
      ),
    );
  }
}

/// A hairline that sweeps back and forth, used while a link is coming up.
class ActivitySweep extends StatefulWidget {
  const ActivitySweep({
    super.key,
    this.height = 3,
    this.color,
    this.active = true,
  });

  final double height;
  final Color? color;
  final bool active;

  @override
  State<ActivitySweep> createState() => _ActivitySweepState();
}

class _ActivitySweepState extends State<ActivitySweep>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1250),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant ActivitySweep old) {
    super.didUpdateWidget(old);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.active && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color tint = widget.color ?? context.colors.primary;
    return SizedBox(
      height: widget.height,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (BuildContext context, _) {
          final double x = _controller.value * 2 - 1;
          return DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment(x - 0.6, 0),
                end: Alignment(x + 0.6, 0),
                colors: <Color>[
                  tint.withValues(alpha: 0),
                  tint.withValues(alpha: 0.85),
                  tint.withValues(alpha: 0),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Section heading used on every page.
///
/// Horizontal padding is zero on purpose: headings are always placed inside a
/// container that already applies the page gutter, so the heading and the text
/// under it share one left edge. When this carried its own 20 px the heading
/// sat 20 px further in than the content it labelled, on every screen.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 26, 0, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 17, color: context.colors.primary),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title.toUpperCase(),
                  style: context.texts.labelMedium?.copyWith(
                    letterSpacing: 1.6,
                    color: context.colors.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      style: context.texts.bodySmall?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Lets a box grow to fill whatever horizontal room it has, capped, and applies
/// the page gutter.
///
/// Superseded by `PageScroll` for full screens, which applies the same gutter
/// and also shows that content continues past the fold. Kept for the places
/// that render a page body inside an already-scrolling host, such as a bottom
/// sheet, where the layout is correct on a 4-inch phone, a 6.7-inch phone and a
/// tablet without a single `Platform.isTablet` check anywhere.
class ResponsiveBody extends StatelessWidget {
  const ResponsiveBody({
    super.key,
    required this.child,
    this.maxWidth = 720,
    this.padding = EdgeInsets.zero,
    this.alignment = Alignment.topCenter,
  });

  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry padding;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(
          padding: padding.add(Gutters.page(context)),
          child: child,
        ),
      ),
    );
  }
}
