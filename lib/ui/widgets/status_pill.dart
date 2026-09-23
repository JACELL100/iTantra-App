import 'package:flutter/material.dart';

import '../animation.dart';
import '../theme.dart';

/// How a status reads.
enum PillTone { neutral, good, caution, alert, live }

/// A compact status chip.
///
/// Used for the link state, the delivery state and the pack-coverage state.
/// Every pill carries an icon and a word as well as a colour, because colour
/// alone is not a status signal for a user who cannot distinguish red from
/// green - and on this app the difference between "sent" and "failed" is not
/// decorative.
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    required this.tone,
    this.icon,
    this.busy = false,
    this.compact = false,
    this.onTap,
    this.tooltip,
  });

  final String label;
  final PillTone tone;
  final IconData? icon;

  /// Shows a sweeping activity line through the pill.
  final bool busy;

  final bool compact;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final _PillColors colors = _PillColors.of(context, tone);

    final Widget pill = AnimatedContainer(
      duration: ItantraTheme.quick,
      curve: ItantraTheme.settle,
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 9 : 12,
        vertical: compact ? 4 : 7,
      ),
      decoration: BoxDecoration(
        color: colors.fill,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colors.border),
        boxShadow: tone == PillTone.live || tone == PillTone.alert
            ? <BoxShadow>[
                BoxShadow(
                  color: colors.foreground.withValues(alpha: 0.22),
                  blurRadius: 14,
                  spreadRadius: -2,
                ),
              ]
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: compact ? 13 : 15, color: colors.foreground),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.foreground,
                fontSize: compact ? 11.5 : 12.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
                height: 1.2,
              ),
            ),
          ),
        ],
      ),
    );

    final Widget withBusy = busy
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              pill,
              const Padding(
                padding: EdgeInsets.only(top: 3),
                child: ClipRRect(
                  borderRadius: BorderRadius.all(Radius.circular(2)),
                  child: ActivitySweep(height: 2),
                ),
              ),
            ],
          )
        : pill;

    final Widget tappable = onTap == null
        ? withBusy
        : InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(999),
            child: withBusy,
          );

    final String? tip = tooltip;
    return tip == null ? tappable : Tooltip(message: tip, child: tappable);
  }
}

class _PillColors {
  const _PillColors({
    required this.fill,
    required this.border,
    required this.foreground,
  });

  final Color fill;
  final Color border;
  final Color foreground;

  static _PillColors of(BuildContext context, PillTone tone) {
    final ColorScheme scheme = context.colors;
    final bool dark = context.isDark;

    switch (tone) {
      case PillTone.good:
        final Color base = dark ? const Color(0xFF6FD8A6) : ItantraTheme.success;
        return _PillColors(
          fill: base.withValues(alpha: dark ? 0.18 : 0.12),
          border: base.withValues(alpha: 0.45),
          foreground: dark ? base : const Color(0xFF0F5C38),
        );
      case PillTone.caution:
        final Color base = dark ? const Color(0xFFF2B354) : ItantraTheme.amber;
        return _PillColors(
          fill: base.withValues(alpha: dark ? 0.18 : 0.12),
          border: base.withValues(alpha: 0.45),
          foreground: dark ? base : const Color(0xFF6E3F00),
        );
      case PillTone.alert:
        final Color base =
            dark ? ItantraTheme.alertRedBright : ItantraTheme.alertRed;
        return _PillColors(
          fill: base.withValues(alpha: dark ? 0.22 : 0.12),
          border: base.withValues(alpha: 0.55),
          foreground: dark ? base : const Color(0xFF8C0F1C),
        );
      case PillTone.live:
        final Color base = dark ? ItantraTheme.saffronBright : ItantraTheme.saffron;
        return _PillColors(
          fill: base.withValues(alpha: dark ? 0.22 : 0.14),
          border: base.withValues(alpha: 0.55),
          foreground: dark ? base : const Color(0xFF7A3200),
        );
      case PillTone.neutral:
        return _PillColors(
          fill: scheme.surfaceContainerHigh,
          border: scheme.outlineVariant,
          foreground: scheme.onSurfaceVariant,
        );
    }
  }
}
