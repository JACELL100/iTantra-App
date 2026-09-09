import 'package:flutter/material.dart';

import '../../core/storage/entities.dart';
import '../theme.dart';

/// One line of the transcript.
///
/// The transcript exists because speech alone is not accessible: a message
/// that arrives while the phone is in a pocket, or that is spoken in a
/// language the listener reads better than hears, has to remain readable.
/// It also gives an operator something to re-play and something to point at.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    this.onReplay,
  });

  final StoredMessage message;
  final VoidCallback? onReplay;

  @override
  Widget build(BuildContext context) {
    final bool outgoing = message.direction == MessageDirection.outgoing;
    final bool lowConfidence =
        message.confidence < StoredMessage.lowConfidenceThreshold;

    final Color background = message.isAlert
        ? ItantraTheme.alertRed
        : outgoing
            ? ItantraTheme.deepBlue
            : Theme.of(context).colorScheme.surfaceContainerHighest;

    final Color foreground = message.isAlert || outgoing
        ? Colors.white
        : Theme.of(context).colorScheme.onSurface;

    return Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 320),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (message.isAlert)
              Row(
                children: <Widget>[
                  const Icon(Icons.warning_amber_rounded,
                      size: 18, color: Colors.white),
                  const SizedBox(width: 6),
                  Text(
                    (message.severity ?? 'alert').toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
            Text(
              message.text,
              style: TextStyle(
                color: foreground,
                fontSize: 17,
                // Indic scripts stack matras above and below the baseline;
                // the default line height clips them.
                height: ItantraTheme.heightFactor,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  message.languageTag.split('-').first,
                  style: TextStyle(
                    color: foreground.withValues(alpha: 0.7),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(width: 8),
                if (lowConfidence)
                  // A recogniser that was unsure must say so. Silently
                  // presenting a low-confidence transcript as fact is the
                  // failure mode that gets someone sent to the wrong place.
                  Tooltip(
                    message: 'Recognition was uncertain. Please confirm.',
                    child: Icon(Icons.help_outline,
                        size: 14, color: foreground.withValues(alpha: 0.8)),
                  ),
                if (message.latencyMs != null) ...<Widget>[
                  const SizedBox(width: 8),
                  Text(
                    '${message.latencyMs!.round()} ms',
                    style: TextStyle(
                      color: foreground.withValues(alpha: 0.7),
                      fontSize: 12,
                    ),
                  ),
                ],
                const SizedBox(width: 8),
                if (outgoing)
                  Icon(_stateIcon(message.state),
                      size: 14, color: foreground.withValues(alpha: 0.8)),
                if (onReplay != null) ...<Widget>[
                  const SizedBox(width: 4),
                  InkWell(
                    onTap: onReplay,
                    child: Icon(Icons.volume_up,
                        size: 18, color: foreground.withValues(alpha: 0.9)),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  static IconData _stateIcon(DeliveryState state) => switch (state) {
        DeliveryState.pending => Icons.schedule,
        DeliveryState.sent => Icons.check,
        DeliveryState.delivered => Icons.done_all,
        // "Played" is the only acknowledgement that matters here: it means
        // the far end actually spoke the message out loud.
        DeliveryState.played => Icons.record_voice_over,
        DeliveryState.failed => Icons.error_outline,
      };
}
