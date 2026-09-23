import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../animation.dart';
import '../haptics.dart';
import '../theme.dart';

/// What the talk button is currently doing.
///
/// A single enum rather than a handful of booleans, because these states are
/// mutually exclusive and the button must never be able to render "talking and
/// blocked" at the same time.
enum TalkState {
  /// No link. The button is inert and says why.
  offline,

  /// Link is coming up, or the recogniser is loading.
  preparing,

  /// The link is fine, but nothing on this phone can turn speech into text.
  ///
  /// Deliberately not folded into [preparing]: waiting will never fix this, so
  /// a button that simply looked busy would be a lie. This state carries a call
  /// to action instead.
  setupNeeded,

  /// Link up, microphone armed, waiting for a finger.
  ready,

  /// Transmitting.
  talking,

  /// Finger lifted, utterance still being recognised and sent.
  finishing,

  /// The peer holds the floor.
  blocked,
}

/// The push-to-talk button.
///
/// Deliberately the largest thing on the screen. This app is meant to be used
/// with cold hands, gloves, or in the dark, by someone who may be under stress
/// and may not read. A single 200 dp target that keys up on touch-down and
/// releases on lift is the only control that reliably works in those
/// conditions, and it maps exactly onto the radio idiom users already know.
///
/// Four things are being communicated at once, and each has its own channel so
/// that colour is never the only signal:
///
/// | Channel | Meaning |
/// | --- | --- |
/// | shape and fill | ready / talking / blocked |
/// | pulse rings | the microphone is open |
/// | live bars | the microphone can hear you, and how loudly |
/// | label and icon | the same thing in words |
class PttButton extends StatefulWidget {
  const PttButton({
    super.key,
    required this.state,
    required this.level,
    required this.onPressStart,
    required this.onPressEnd,
    this.onNeedsSetup,
    this.blockedReason,
    this.size,
    this.semanticLabel,
  });

  final TalkState state;

  /// Input level 0..1, driving the glow and the bars. Visible feedback that the
  /// microphone is hearing something matters: without it a user whose message
  /// failed cannot tell whether they were too quiet or the link was down.
  final double level;

  final VoidCallback onPressStart;
  final VoidCallback onPressEnd;

  /// Tapped while [TalkState.setupNeeded]. The button is not a hold-to-talk
  /// target in that state, so a tap has to mean something else - and the only
  /// useful thing it can mean is "fix this".
  final VoidCallback? onNeedsSetup;

  /// Shown in place of the label when [TalkState.blocked].
  final String? blockedReason;

  /// Overrides the responsive default. Used by the landscape layout, which has
  /// far less vertical room.
  final double? size;

  final String? semanticLabel;

  static const double _minSize = 152;
  static const double _preferredSize = 224;

  @override
  State<PttButton> createState() => _PttButtonState();
}

class _PttButtonState extends State<PttButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: ItantraTheme.instant,
    reverseDuration: ItantraTheme.quick,
  );

  bool get _interactive =>
      widget.state == TalkState.ready ||
      widget.state == TalkState.talking ||
      widget.state == TalkState.finishing;

  bool get _talking => widget.state == TalkState.talking;

  @override
  void initState() {
    super.initState();
    _press.addListener(_hapticAtThreshold);
  }

  // Fires the key-up haptic exactly once per press rather than on every frame.
  bool _hapticFired = false;

  void _hapticAtThreshold() {
    if (_press.value > 0.6 && !_hapticFired) {
      _hapticFired = true;
      Haptics.fireAndForget(Haptic.press);
    } else if (_press.value < 0.2 && _hapticFired) {
      _hapticFired = false;
    }
  }

  void _start() {
    if (!_interactive) return;
    _press.forward();
    widget.onPressStart();
  }

  void _end() {
    if (!_interactive) return;
    _press.reverse();
    // A softer, shorter tap than the press, so the pair reads as brackets
    // around one utterance rather than as two unrelated events.
    Haptics.fireAndForget(Haptic.release);
    widget.onPressEnd();
  }

  @override
  void dispose() {
    _press.removeListener(_hapticAtThreshold);
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double size = widget.size ??
        (context.isShort
            ? PttButton._minSize
            : (MediaQuery.sizeOf(context).width *
                    (context.isWide ? 0.22 : 0.56))
                .clamp(PttButton._minSize, PttButton._preferredSize));

    final _TalkVisual visual = _TalkVisual.of(context, widget.state);

    return Semantics(
      button: true,
      enabled: _interactive,
      label: widget.semanticLabel ??
          switch (widget.state) {
            TalkState.talking => 'Transmitting. Release to send.',
            TalkState.ready => 'Hold to talk',
            TalkState.preparing => 'Preparing',
            TalkState.setupNeeded => 'No recognition model. Install one to talk.',
            TalkState.finishing => 'Sending',
            TalkState.blocked => widget.blockedReason ?? 'Wait',
            TalkState.offline => 'Not connected',
          },
      hint: _interactive
          ? 'Press and hold, then speak, then release'
          : widget.state == TalkState.setupNeeded
              ? 'Opens the screen where a model can be installed'
              : null,
      child: GestureDetector(
        // onTapDown / onTapUp rather than onTap: a walkie-talkie must key up
        // the instant the finger lands, and every millisecond here is counted
        // in the measured end-to-end delay.
        behavior: HitTestBehavior.opaque,
        onTapDown: _interactive ? (_) => _start() : null,
        onTapUp: _interactive ? (_) => _end() : null,
        onTapCancel: _interactive ? _end : null,
        onLongPressEnd: _interactive ? (_) => _end() : null,
        // Nothing to hold, so the tap opens the one screen that unblocks it.
        onTap: widget.state == TalkState.setupNeeded
            ? widget.onNeedsSetup
            : null,
        child: SizedBox(
          width: size * 1.42,
          height: size * 1.42,
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              // Rings expand past the button edge, so the hit target stays the
              // circle while the live indicator has room to breathe.
              if (_talking)
                PulseRings(
                  color: visual.glow,
                  minRadius: size * 0.5,
                  maxRadius: size * 0.7,
                  strokeWidth: 2.5,
                ),

              // The aura: a soft radial glow whose reach tracks the input
              // level. This is the level meter, read at arm's length.
              AnimatedContainer(
                duration: ItantraTheme.quick,
                curve: ItantraTheme.settle,
                width: size + (_talking ? 30 + 54 * widget.level.clamp(0, 1) : 0),
                height:
                    size + (_talking ? 30 + 54 * widget.level.clamp(0, 1) : 0),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: <BoxShadow>[
                    if (_talking || widget.state == TalkState.ready)
                      BoxShadow(
                        color: (widget.state == TalkState.talking
                                ? visual.glow
                                : context.colors.primary)
                            .withValues(
                          alpha: _talking
                              ? (0.20 + 0.34 * widget.level.clamp(0, 1))
                              : 0.12,
                        ),
                        blurRadius: _talking
                            ? 34 + 54 * widget.level.clamp(0, 1)
                            : 22,
                        spreadRadius: 2,
                      ),
                  ],
                ),
              ),

              // The button itself: a hair larger, so it sits inside the aura.
              // Not a circular ImageFilter blur - that is very expensive to
              // re-rasterise every frame on a low-end GPU.
              ScaleTransition(
                scale: Tween<double>(begin: 1, end: 0.945).animate(
                  CurvedAnimation(parent: _press, curve: ItantraTheme.settle),
                ),
                child: AnimatedContainer(
                  duration: ItantraTheme.quick,
                  curve: ItantraTheme.settle,
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: visual.gradient,
                    ),
                    border: Border.all(
                      color: visual.border,
                      width: _talking ? 3 : 1.5,
                    ),
                  ),
                  child: ClipOval(
                    child: _TalkFace(
                      state: widget.state,
                      level: widget.level,
                      visual: visual,
                      blockedReason: widget.blockedReason,
                      size: size,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TalkFace extends StatelessWidget {
  const _TalkFace({
    required this.state,
    required this.level,
    required this.visual,
    required this.size,
    this.blockedReason,
  });

  final TalkState state;
  final double level;
  final _TalkVisual visual;
  final double size;
  final String? blockedReason;

  @override
  Widget build(BuildContext context) {
    final bool compact = size < 190;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        AnimatedSwitcher(
          duration: ItantraTheme.quick,
          switchInCurve: ItantraTheme.emphasized,
          child: Icon(
            visual.icon,
            key: ValueKey<IconData>(visual.icon),
            size: compact ? 52 : (size * 0.30).clamp(52, 76),
            color: Colors.white,
          ),
        ),
        if (state == TalkState.talking) ...<Widget>[
          const SizedBox(height: 6),
          SizedBox(
            width: size * 0.62,
            child: LiveWaveform(
              level: level,
              active: true,
              height: compact ? 22 : 30,
              barCount: 19,
              color: Colors.white,
            ),
          ),
        ],
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Text(
            visual.textFor(blockedReason),
            textAlign: TextAlign.center,
            maxLines: 2,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.96),
              fontSize: compact ? 15 : 17,
              height: 1.2,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
        ),
      ],
    );
  }
}

/// Colours and copy for one talk state.
class _TalkVisual {
  const _TalkVisual({
    required this.gradient,
    required this.glow,
    required this.border,
    required this.icon,
    required this.label,
  });

  final List<Color> gradient;
  final Color glow;
  final Color border;
  final IconData icon;
  final String label;

  /// A blocked reason is only substituted for a state that is actually waiting
  /// on something. Overwriting "Release to send" with "the other side is
  /// talking" while a finger is down would be actively misleading.
  String textFor(String? blockedReason) {
    final String? override = blockedReason;
    if (override == null || override.isEmpty) return label;
    if (icon != Icons.hourglass_top_rounded) return label;
    return override;
  }

  static _TalkVisual of(BuildContext context, TalkState state) {
    final ColorScheme colors = context.colors;
    final bool dark = context.isDark;

    switch (state) {
      case TalkState.talking:
        return _TalkVisual(
          gradient: const <Color>[Color(0xFFF97316), Color(0xFFC2410C)],
          glow: dark ? ItantraTheme.saffronBright : ItantraTheme.saffron,
          border: Colors.white.withValues(alpha: 0.34),
          icon: Icons.mic_rounded,
          label: 'Release to send',
        );
      case TalkState.finishing:
        return _TalkVisual(
          gradient: const <Color>[Color(0xFFF08A3C), Color(0xFFB54B0A)],
          glow: ItantraTheme.saffron,
          border: Colors.white.withValues(alpha: 0.3),
          icon: Icons.graphic_eq_rounded,
          label: 'Sending…',
        );
      case TalkState.ready:
        return _TalkVisual(
          gradient: dark
              ? const <Color>[Color(0xFF2A7FC4), Color(0xFF0B4F8A)]
              : const <Color>[Color(0xFF1C6FB0), Color(0xFF0B4F8A)],
          glow: colors.primary,
          border: Colors.white.withValues(alpha: 0.22),
          icon: Icons.mic_none_rounded,
          label: 'Hold to talk',
        );
      case TalkState.preparing:
        return _TalkVisual(
          gradient: <Color>[
            colors.surfaceContainerHighest,
            colors.surfaceContainerHigh,
          ],
          glow: colors.outline,
          border: colors.outline.withValues(alpha: 0.5),
          icon: Icons.hourglass_top_rounded,
          label: 'One moment…',
        );
      case TalkState.setupNeeded:
        // Amber, not grey: this needs an action, and amber is the app's colour
        // for "attention, not danger". Red stays reserved for distress.
        return _TalkVisual(
          gradient: dark
              ? const <Color>[Color(0xFF8A5A12), Color(0xFF5E3B06)]
              : const <Color>[Color(0xFFC97F17), Color(0xFF8A5A12)],
          glow: ItantraTheme.amber,
          border: Colors.white.withValues(alpha: 0.22),
          icon: Icons.download_for_offline_rounded,
          label: 'Add a model',
        );
      case TalkState.blocked:
        return _TalkVisual(
          gradient: <Color>[
            colors.surfaceContainerHighest,
            colors.surfaceContainerHigh,
          ],
          glow: colors.outline,
          border: colors.outline.withValues(alpha: 0.5),
          icon: Icons.hourglass_top_rounded,
          label: 'Their turn',
        );
      case TalkState.offline:
        return _TalkVisual(
          gradient: <Color>[
            colors.surfaceContainerHighest,
            colors.surfaceContainerHigh,
          ],
          glow: colors.outlineVariant,
          border: colors.outlineVariant,
          icon: Icons.link_off_rounded,
          label: 'Not connected',
        );
    }
  }
}

/// A rotating arc used while the recogniser is loading.
///
/// Shown inside the talk button's ring so a user who presses before the model
/// is warm understands why nothing happened, rather than concluding the app is
/// broken.
class IndeterminateArc extends StatefulWidget {
  const IndeterminateArc({
    super.key,
    this.size = 28,
    this.strokeWidth = 3,
    this.color,
  });

  final double size;
  final double strokeWidth;
  final Color? color;

  @override
  State<IndeterminateArc> createState() => _IndeterminateArcState();
}

class _IndeterminateArcState extends State<IndeterminateArc>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, _) => Transform.rotate(
        angle: _controller.value * 2 * math.pi,
        child: CustomPaint(
          size: Size.square(widget.size),
          painter: _ArcPainter(
            color: widget.color ?? context.colors.primary,
            strokeWidth: widget.strokeWidth,
            sweep: 0.28 + 0.18 * math.sin(_controller.value * math.pi * 2),
          ),
        ),
      ),
    );
  }
}

class _ArcPainter extends CustomPainter {
  _ArcPainter({
    required this.color,
    required this.strokeWidth,
    required this.sweep,
  });

  final Color color;
  final double strokeWidth;
  final double sweep;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = strokeWidth
      ..color = color;

    canvas.drawArc(
      rect.deflate(strokeWidth / 2),
      -math.pi / 2,
      sweep * 2 * math.pi,
      false,
      paint,
    );
    canvas.drawArc(
      rect.deflate(strokeWidth / 2),
      -math.pi / 2 + math.pi,
      sweep * math.pi,
      false,
      paint..color = color.withValues(alpha: 0.35),
    );
  }

  @override
  bool shouldRepaint(covariant _ArcPainter old) =>
      old.sweep != sweep || old.color != color;
}
