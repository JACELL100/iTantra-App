import 'package:flutter/material.dart';

import '../../core/storage/entities.dart';
import '../animation.dart';
import '../format.dart';
import '../theme.dart';

/// One line of the transcript.
///
/// The transcript exists because speech alone is not accessible: a message that
/// arrives while the phone is in a pocket, or that is spoken in a language the
/// listener reads better than hears, has to remain readable. It also gives an
/// operator something to point at and something to replay.
///
/// The bubble carries more than text on purpose. Language, confidence and
/// delivery state are all things a user needs in order to decide whether to
/// act on a message, and hiding them behind a tap would be the wrong trade in
/// an emergency.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    this.index = 0,
    this.animate = true,
    this.onReplay,
    this.onRetry,
  });

  final StoredMessage message;

  /// Position in the list, used only to stagger the entrance.
  final int index;
  final bool animate;

  final VoidCallback? onReplay;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final bool outgoing = message.direction == MessageDirection.outgoing;
    final bool lowConfidence = message.isLowConfidence && !message.isAlert;

    final _BubbleSkin skin = _BubbleSkin.of(context, message, outgoing);

    return FadeSlideIn(
      index: index,
      animate: animate,
      offset: outgoing ? 18 : -18,
      child: Semantics(
        label: <String>[
          if (message.isAlert) 'Alert.',
          outgoing ? 'You said:' : 'They said:',
          message.text,
          'Language ${message.languageTag}.',
          if (lowConfidence) 'Recognition was uncertain.',
          if (outgoing) _stateWord(message.state),
        ].join(' '),
        child: Align(
          alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
          child: Padding(
            padding: EdgeInsets.only(
              left: outgoing ? 56 : 12,
              right: outgoing ? 12 : 56,
              top: 4,
              bottom: 4,
            ),
            child: _Bubble(
              message: message,
              outgoing: outgoing,
              lowConfidence: lowConfidence,
              skin: skin,
              onReplay: onReplay,
              onRetry: onRetry,
            ),
          ),
        ),
      ),
    );
  }

  static String _stateWord(DeliveryState state) => switch (state) {
        DeliveryState.pending => 'Waiting to send.',
        DeliveryState.sent => 'Sent.',
        DeliveryState.delivered => 'Delivered.',
        DeliveryState.played => 'Played on the other phone.',
        DeliveryState.failed => 'Failed to send.',
      };
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.outgoing,
    required this.lowConfidence,
    required this.skin,
    this.onReplay,
    this.onRetry,
  });

  final StoredMessage message;
  final bool outgoing;
  final bool lowConfidence;
  final _BubbleSkin skin;
  final VoidCallback? onReplay;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final String languageLabel =
        message.languageTag.split('-').first.toUpperCase();

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: skin.gradient,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(20),
          topRight: const Radius.circular(20),
          bottomLeft: Radius.circular(outgoing ? 20 : 6),
          bottomRight: Radius.circular(outgoing ? 6 : 20),
        ),
        border: Border.all(color: skin.border, width: skin.borderWidth),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: skin.shadow,
            blurRadius: message.isAlert ? 22 : 10,
            offset: const Offset(0, 4),
            spreadRadius: message.isAlert ? -2 : -4,
          ),
        ],
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(14, message.isAlert ? 10 : 11, 14, 9),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (message.isAlert) _AlertHeader(message: message),
            SelectableText(
              message.text,
              style: TextStyle(
                color: skin.foreground,
                fontSize: 17,
                // Indic scripts stack matras above and below the baseline; the
                // default line height clips them.
                height: ItantraTheme.heightFactor,
                fontWeight: message.isAlert ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            const SizedBox(height: 7),
            _Footer(
              message: message,
              outgoing: outgoing,
              lowConfidence: lowConfidence,
              languageLabel: languageLabel,
              skin: skin,
              onReplay: onReplay,
              onRetry: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}

class _AlertHeader extends StatelessWidget {
  const _AlertHeader({required this.message});

  final StoredMessage message;

  @override
  Widget build(BuildContext context) {
    final String severity = (message.severity ?? 'alert').toUpperCase();
    final bool distress = severity == 'DISTRESS';

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            distress ? Icons.warning_rounded : Icons.warning_amber_rounded,
            size: 17,
            color: Colors.white,
          ),
          const SizedBox(width: 6),
          Text(
            distress ? 'DISTRESS' : 'WARNING',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 11.5,
              letterSpacing: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.message,
    required this.outgoing,
    required this.lowConfidence,
    required this.languageLabel,
    required this.skin,
    this.onReplay,
    this.onRetry,
  });

  final StoredMessage message;
  final bool outgoing;
  final bool lowConfidence;
  final String languageLabel;
  final _BubbleSkin skin;
  final VoidCallback? onReplay;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final Color muted = skin.foreground.withValues(alpha: 0.72);
    final bool failed = outgoing && message.state == DeliveryState.failed;

    return Wrap(
      spacing: 10,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              clockTime(message.createdAtMs),
              style: TextStyle(color: muted, fontSize: 11.5, height: 1.2),
            ),
            const SizedBox(width: 6),
            _Tag(text: languageLabel, color: muted),
          ],
        ),

        if (lowConfidence)
          // A recogniser that was unsure must say so. Silently presenting a
          // low-confidence transcript as fact is the failure mode that gets
          // someone sent to the wrong place.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.error_outline_rounded, size: 13, color: muted),
              const SizedBox(width: 3),
              Text(
                '${percent(message.confidence)} sure',
                style: TextStyle(color: muted, fontSize: 11.5, height: 1.2),
              ),
            ],
          ),

        if (message.latencyMs != null && message.latencyMs! > 0)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.timer_outlined, size: 13, color: muted),
              const SizedBox(width: 3),
              Text(
                millis(message.latencyMs!),
                style: TextStyle(color: muted, fontSize: 11.5, height: 1.2),
              ),
            ],
          ),

        if (outgoing)
          _DeliveryMark(state: message.state, color: muted),

        if (onReplay != null && !failed)
          _MiniAction(
            icon: Icons.volume_up_rounded,
            tooltip: 'Play again',
            color: skin.foreground,
            onTap: onReplay!,
          ),

        if (failed && onRetry != null)
          _MiniAction(
            icon: Icons.refresh_rounded,
            tooltip: 'Try sending again',
            color: skin.foreground,
            onTap: onRetry!,
          ),
      ],
    );
  }
}

class _DeliveryMark extends StatelessWidget {
  const _DeliveryMark({required this.state, required this.color});

  final DeliveryState state;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, String label) = switch (state) {
      DeliveryState.pending => (Icons.schedule_rounded, 'Waiting to send'),
      DeliveryState.sent => (Icons.check_rounded, 'Sent'),
      DeliveryState.delivered => (Icons.done_all_rounded, 'Delivered'),
      // "Played" is the only acknowledgement that matters: it means the far
      // end actually spoke the message out loud.
      DeliveryState.played => (Icons.record_voice_over_rounded, 'Played there'),
      DeliveryState.failed => (Icons.error_outline_rounded, 'Send failed'),
    };

    return Tooltip(
      message: label,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(color: color, fontSize: 11.5, height: 1.2),
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
          height: 1.3,
        ),
      ),
    );
  }
}

class _MiniAction extends StatelessWidget {
  const _MiniAction({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(icon, size: 17, color: color),
        ),
      ),
    );
  }
}

/// Colours for one bubble, resolved once.
class _BubbleSkin {
  const _BubbleSkin({
    required this.foreground,
    required this.border,
    required this.shadow,
    this.gradient,
    this.borderWidth = 1,
  });

  final Color foreground;
  final Color border;
  final Color shadow;

  /// Set for outgoing and alert bubbles; null for a received one, which uses a
  /// flat surface colour so the transcript does not turn into a wall of
  /// gradients.
  final Gradient? gradient;

  final double borderWidth;

  static _BubbleSkin of(
    BuildContext context,
    StoredMessage message,
    bool outgoing,
  ) {
    final ColorScheme scheme = context.colors;
    final bool dark = context.isDark;

    if (message.isAlert) {
      final bool distress =
          (message.severity ?? '').toLowerCase() == 'distress';
      return _BubbleSkin(
        foreground: Colors.white,
        border: Colors.white.withValues(alpha: 0.28),
        shadow: ItantraTheme.alertRed.withValues(alpha: 0.35),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: distress
              ? const <Color>[Color(0xFFD61F2C), Color(0xFF8C0F1C)]
              : const <Color>[Color(0xFFE8590C), Color(0xFF9A3606)],
        ),
        borderWidth: 1.4,
      );
    }

    if (outgoing) {
      return _BubbleSkin(
        foreground: Colors.white,
        border: Colors.white.withValues(alpha: 0.14),
        shadow: ItantraTheme.deepBlue.withValues(alpha: dark ? 0.4 : 0.22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? const <Color>[Color(0xFF14598F), Color(0xFF0A3556)]
              : const <Color>[Color(0xFF1667A6), Color(0xFF0B4F8A)],
        ),
      );
    }

    final bool low = message.isLowConfidence;
    final Color base = low
        ? (dark ? const Color(0xFFF2B354) : ItantraTheme.amber)
        : scheme.outline;

    return _BubbleSkin(
      foreground: scheme.onSurface,
      border: low
          ? base.withValues(alpha: 0.65)
          : scheme.outlineVariant.withValues(alpha: 0.75),
      shadow: low
          ? base.withValues(alpha: 0.22)
          : Colors.black.withValues(alpha: dark ? 0.3 : 0.07),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[
          context.palette.receivedBubble,
          context.palette.receivedBubble,
        ],
      ),
      borderWidth: low ? 1.5 : 1,
    );
  }
}
