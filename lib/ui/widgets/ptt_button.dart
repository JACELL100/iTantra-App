import 'package:flutter/material.dart';

import '../theme.dart';

/// The push-to-talk button.
///
/// Deliberately the largest thing on the screen. This app is meant to be used
/// with cold hands, gloves, or in the dark, by someone who may be under
/// stress and may not read. A 200 dp target that responds on press-down and
/// releases on lift is the only control that reliably works in those
/// conditions, and it maps exactly onto the radio idiom users already know.
class PttButton extends StatelessWidget {
  const PttButton({
    super.key,
    required this.isTalking,
    required this.level,
    required this.enabled,
    required this.onPressStart,
    required this.onPressEnd,
    this.blockedReason,
  });

  final bool isTalking;

  /// Input level, 0..1, driving the ring. Visible feedback that the
  /// microphone is actually hearing something matters: without it a user
  /// whose message failed cannot tell whether they were too quiet or the
  /// link was down.
  final double level;

  final bool enabled;
  final VoidCallback onPressStart;
  final VoidCallback onPressEnd;

  /// Shown instead of the label when the far end holds the floor.
  final String? blockedReason;

  @override
  Widget build(BuildContext context) {
    final bool blocked = blockedReason != null;
    final Color base = !enabled || blocked
        ? Colors.grey.shade600
        : isTalking
            ? ItantraTheme.saffron
            : ItantraTheme.deepBlue;

    return Semantics(
      button: true,
      label: isTalking ? 'Talking. Release to send.' : 'Hold to talk',
      child: GestureDetector(
        // onTapDown / onTapUp rather than onTap: a walkie-talkie must key up
        // the instant the finger lands, and every millisecond here is counted
        // in the measured end-to-end delay.
        onTapDown: enabled && !blocked ? (_) => onPressStart() : null,
        onTapUp: enabled && !blocked ? (_) => onPressEnd() : null,
        onTapCancel: enabled && !blocked ? onPressEnd : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 216,
          height: 216,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: base,
            boxShadow: <BoxShadow>[
              if (isTalking)
                BoxShadow(
                  color: ItantraTheme.saffron.withValues(alpha: 0.45),
                  // The glow grows with input level, so the ring is a live
                  // level meter and not just decoration.
                  blurRadius: 24 + 48 * level.clamp(0.0, 1.0),
                  spreadRadius: 4 + 12 * level.clamp(0.0, 1.0),
                ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(
                isTalking ? Icons.mic : Icons.mic_none,
                size: 72,
                color: Colors.white,
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  blocked
                      ? blockedReason!
                      : isTalking
                          ? 'Release to send'
                          : 'Hold to talk',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
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
