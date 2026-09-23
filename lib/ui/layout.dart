import 'package:flutter/material.dart';

import 'animation.dart';
import 'theme.dart';

/// A scrollable page body that always shows that there is more to see.
///
/// Three things together do the work, and all three were missing before:
///
///  * a gutter and a capped content width, so nothing is edge to edge;
///  * generous bottom padding, so the last row is never flush against the
///    bottom of the screen;
///  * a fade over the bottom edge plus a short "more below" marker which
///    appears only while content actually continues past the fold, and fades
///    out the moment the user reaches the end. Without it a scrollable screen
///    and a non-scrollable one look identical, which is exactly the confusion
///    this is here to remove.
class PageScroll extends StatefulWidget {
  const PageScroll({
    super.key,
    required this.child,
    this.controller,
    this.topPadding = Gutters.pageTop,
    this.bottomPadding,
    this.maxWidth = Gutters.contentMaxWidth,
    this.showHint = true,
    this.hintLabel = 'More below',
  });

  final Widget child;
  final ScrollController? controller;
  final double topPadding;

  /// Overrides the default bottom space. Used by screens that host a fixed
  /// bottom bar, which already reserves its own height.
  final double? bottomPadding;

  final double maxWidth;
  final bool showHint;
  final String hintLabel;

  @override
  State<PageScroll> createState() => _PageScrollState();
}

class _PageScrollState extends State<PageScroll> {
  final ScrollController _owned = ScrollController();
  final ValueNotifier<bool> _moreBelow = ValueNotifier<bool>(false);

  ScrollController get _controller => widget.controller ?? _owned;

  /// True when there is content past the bottom edge. A 32 px threshold means
  /// a page that overflows by a sliver does not flash a marker for nothing.
  void _update(ScrollMetrics metrics) {
    final bool more = metrics.extentAfter > 32;
    if (_moreBelow.value != more) _moreBelow.value = more;
  }

  @override
  void dispose() {
    _owned.dispose();
    _moreBelow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double gutter = Gutters.of(context);
    final double bottom =
        widget.bottomPadding ?? Gutters.bottomSpace(context);

    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (ScrollMetricsNotification notification) {
        _update(notification.metrics);
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (ScrollNotification notification) {
          _update(notification.metrics);
          return false;
        },
        child: Stack(
          children: <Widget>[
            SingleChildScrollView(
              controller: _controller,
              // Bouncing physics on both platforms: the overscroll is the
              // clearest possible signal that the list has an end.
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              padding: EdgeInsets.only(
                top: widget.topPadding,
                bottom: bottom,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: widget.maxWidth),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: gutter),
                    child: widget.child,
                  ),
                ),
              ),
            ),
            if (widget.showHint)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: ValueListenableBuilder<bool>(
                    valueListenable: _moreBelow,
                    builder: (BuildContext context, bool more, _) =>
                        ScrollVeil(visible: more, label: widget.hintLabel),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The bottom-edge fade plus the "more below" marker.
///
/// The gradient starts fully transparent and ends on the page's own background
/// colour, so content dissolves into the edge instead of being sliced off by
/// it - the difference between a list that continues and one that is broken.
class ScrollVeil extends StatelessWidget {
  const ScrollVeil({
    super.key,
    required this.visible,
    this.label = 'More below',
    this.height = 74,
  });

  final bool visible;
  final String label;
  final double height;

  @override
  Widget build(BuildContext context) {
    final Color background = Theme.of(context).scaffoldBackgroundColor;
    final bool dark = context.isDark;

    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: ItantraTheme.medium,
      curve: ItantraTheme.settle,
      child: AnimatedSlide(
        offset: visible ? Offset.zero : const Offset(0, 0.35),
        duration: ItantraTheme.medium,
        curve: ItantraTheme.settle,
        child: SizedBox(
          height: height,
          child: Column(
            children: <Widget>[
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[
                        background.withValues(alpha: 0),
                        background.withValues(alpha: dark ? 0.85 : 0.92),
                        background,
                      ],
                      stops: const <double>[0, 0.62, 1],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    _BobbingChevron(dark: dark),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: context.texts.labelSmall?.copyWith(
                        color: context.colors.onSurfaceVariant,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A chevron that drifts up and down a few pixels, so the marker reads as an
/// invitation rather than as a label.
class _BobbingChevron extends StatefulWidget {
  const _BobbingChevron({required this.dark});

  final bool dark;

  @override
  State<_BobbingChevron> createState() => _BobbingChevronState();
}

class _BobbingChevronState extends State<_BobbingChevron>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, _) => Transform.translate(
        offset: Offset(0, 2.5 * Curves.easeInOut.transform(_controller.value)),
        child: Icon(
          Icons.keyboard_arrow_down_rounded,
          size: 16,
          color: context.colors.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// The standard scaffold for every full-screen page.
///
/// A page is: an app bar, the gradient backdrop, and a [PageScroll]. Sub-screens
/// get a back button and a max content width for free, so a settings page on a
/// tablet does not stretch a switch across 1200 px.
class PageScaffold extends StatelessWidget {
  const PageScaffold({
    super.key,
    required this.title,
    required this.child,
    this.actions,
    this.subtitle,
    this.accent,
    this.accentIntensity = 0.55,
    this.topPadding = Gutters.pageTop,
    this.bottomPadding,
    this.maxWidth = Gutters.contentMaxWidth,
    this.showHint = true,
    this.hintLabel = 'More below',
    this.scrollController,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final List<Widget>? actions;
  final Color? accent;
  final double accentIntensity;
  final double topPadding;
  final double? bottomPadding;
  final double maxWidth;
  final bool showHint;
  final String hintLabel;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // The backdrop is painted by GradientBackdrop, so the scaffold itself must
      // not paint over it.
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        titleSpacing: Gutters.of(context),
        title: subtitle == null
            ? Text(title)
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: context.texts.titleLarge),
                  Text(
                    subtitle!,
                    style: context.texts.bodySmall?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
        actions: <Widget>[
          ...?actions,
          SizedBox(width: Gutters.of(context) - 12),
        ],
      ),
      body: GradientBackdrop(
        accent: accent,
        intensity: accentIntensity,
        child: SafeArea(
          top: false,
          child: PageScroll(
            controller: scrollController,
            topPadding: topPadding,
            bottomPadding: bottomPadding,
            maxWidth: maxWidth,
            showHint: showHint,
            hintLabel: hintLabel,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// A bar pinned to the bottom of the screen that respects the gesture bar and
/// keeps the same gutter as the page body.
///
/// Used for the talk controls on the conversation screen. The extra bottom
/// padding is not decoration: without it the talk button sits under the
/// navigation pill on a gesture-navigation phone, and the single most important
/// control in the app becomes hard to press.
class BottomBar extends StatelessWidget {
  const BottomBar({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(vertical: 10),
    this.opaque = true,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool opaque;

  @override
  Widget build(BuildContext context) {
    final Color background = Theme.of(context).scaffoldBackgroundColor;
    final double gutter = Gutters.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: opaque ? background.withValues(alpha: 0.94) : null,
        border: Border(
          top: BorderSide(
            color: context.palette.hairline.withValues(alpha: 0.7),
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: Gutters.contentMaxWidth),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: gutter).add(padding),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// A standard content card: a titled surface with an optional leading icon and
/// trailing widget.
///
/// Replaces the ad-hoc `Card` + `ListTile` + `Padding` stacks that used to be
/// assembled per screen, which is where the spacing drifted.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.child,
    this.title,
    this.icon,
    this.trailing,
    this.padding = const EdgeInsets.all(16),
    this.tone,
  });

  final Widget child;
  final String? title;
  final IconData? icon;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  /// Overrides the surface tint. Used for the alert card, which must not look
  /// like an ordinary setting.
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = context.colors;
    final Color fill = tone?.withValues(alpha: context.isDark ? 0.16 : 0.08) ??
        colors.surfaceContainerLow;

    return Container(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: tone?.withValues(alpha: 0.42) ??
              colors.outlineVariant.withValues(alpha: 0.65),
        ),
      ),
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (title != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: <Widget>[
                  if (icon != null) ...<Widget>[
                    Icon(
                      icon,
                      size: 18,
                      color: tone ?? colors.primary,
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      title!,
                      style: context.texts.titleSmall?.copyWith(
                        color: tone ?? colors.onSurface,
                      ),
                    ),
                  ),
                  if (trailing != null) trailing!,
                ],
              ),
            ),
          child,
        ],
      ),
    );
  }
}

/// A label/value row, aligned the same way everywhere.
class DetailRow extends StatelessWidget {
  const DetailRow({
    super.key,
    required this.label,
    required this.value,
    this.icon,
    this.valueColor,
    this.monospace = false,
  });

  final String label;
  final String value;
  final IconData? icon;
  final Color? valueColor;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 15, color: context.colors.onSurfaceVariant),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              label,
              style: context.texts.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: context.texts.bodyMedium?.copyWith(
                color: valueColor,
                fontFeatures: monospace
                    ? const <FontFeature>[FontFeature.tabularFigures()]
                    : null,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
