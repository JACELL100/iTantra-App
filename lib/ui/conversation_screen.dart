import 'package:flutter/material.dart';

import '../core/session/session_controller.dart';
import '../core/session/session_launcher.dart';
import '../core/storage/entities.dart';
import '../core/util/async.dart';
import 'animation.dart';
import 'app_controller.dart';
import 'diagnostics_screen.dart';
import 'format.dart';
import 'languages.dart';
import 'models_screen.dart';
import 'packs_screen.dart';
import 'theme.dart';
import 'widgets/alert_composer.dart';
import 'widgets/connect_sheet.dart';
import 'widgets/message_bubble.dart';
import 'widgets/ptt_button.dart';
import 'widgets/status_pill.dart';

/// The screen the app is really about.
///
/// Layout priority is deliberate and does not change with screen size: the talk
/// button first, the transcript second, everything else behind a menu. In a
/// distress situation the user needs one enormous target and no decisions.
///
/// On a wide screen the same two things appear side by side rather than stacked,
/// because a tablet or a phone in landscape has the horizontal room and none of
/// the vertical.
class ConversationScreen extends StatefulWidget {
  const ConversationScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  /// Guards the pairing sheet so a handshake retransmission cannot stack two
  /// copies of the verification dialog on top of each other.
  bool _pairingShown = false;

  AppController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _maybeShowPairing());
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    _maybeShowPairing();
    _drainToast();
  }

  void _maybeShowPairing() {
    if (!mounted) return;
    final LaunchState launch = _controller.launch;

    if (launch is! LaunchAwaitingVerification) {
      _pairingShown = false;
      return;
    }
    if (_pairingShown) return;
    _pairingShown = true;

    unawaited(_runVerification(launch));
  }

  Future<void> _runVerification(LaunchAwaitingVerification launch) async {
    final bool matched = await showPairingSheet(
      context,
      shortAuthString: launch.shortAuthString,
      linkLabel: launch.linkLabel,
      peerLabel: launch.peerLabel,
    );
    if (!mounted) return;

    if (matched) {
      await _controller.confirmVerification();
    } else {
      await _controller.rejectVerification();
    }
  }

  void _drainToast() {
    if (!mounted) return;
    final String? note = _controller.consumeToast();
    if (note == null) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(note)));
  }

  @override
  Widget build(BuildContext context) {
    _drainToast();
    final bool wide = context.isWide;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) _confirmEndSession();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: GradientBackdrop(
          intensity: 1,
          accent: _accent(context),
          child: SafeArea(
            child: Column(
              children: <Widget>[
                _SessionBar(controller: _controller, onEnd: _confirmEndSession),
                if (_controller.isDemo) const _DemoNotice(),
                if (_controller.banner case final AppBanner banner)
                  _InlineBanner(
                    banner: banner,
                    controller: _controller,
                    onDismiss: _controller.dismissBanner,
                  ),
                Expanded(
                  child: wide
                      ? Row(
                          children: <Widget>[
                            Expanded(child: _Transcript(controller: _controller)),
                            const VerticalDivider(width: 1),
                            SizedBox(
                              width: 400,
                              child: _ControlDeck(controller: _controller),
                            ),
                          ],
                        )
                      : Column(
                          children: <Widget>[
                            Expanded(
                              child: _Transcript(controller: _controller),
                            ),
                            _ControlDeck(controller: _controller),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The backdrop tint tracks what is live, so the screen's temperature matches
  /// the session without any element having to say so.
  Color _accent(BuildContext context) {
    final TalkState state = _controller.talkState;
    return switch (state) {
      TalkState.talking => ItantraTheme.saffron,
      TalkState.finishing => ItantraTheme.saffron,
      TalkState.ready => context.colors.primary,
      TalkState.blocked => ItantraTheme.amber,
      TalkState.setupNeeded => ItantraTheme.amber,
      TalkState.preparing => context.colors.primary,
      TalkState.offline => context.colors.outline,
    };
  }

  Future<void> _confirmEndSession() async {
    final bool? end = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('End this link?'),
        content: const Text(
          'The microphone stops and the session closes. Your transcript stays '
          'on this phone and can be cleared separately.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Stay connected'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('End link'),
          ),
        ],
      ),
    );
    if (end == true) await _controller.disconnect();
  }
}

/// The persistent top strip: who, over what, encrypted or not.
class _SessionBar extends StatelessWidget {
  const _SessionBar({required this.controller, required this.onEnd});

  final AppController controller;
  final Future<void> Function() onEnd;

  @override
  Widget build(BuildContext context) {
    final String language = controller.languageTag;
    final LanguageSpec? spec = Languages.byTag(language);
    final TalkState state = controller.talkState;

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: 'End the link',
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => onEnd(),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  controller.peerLabel ?? 'Linked phone',
                  style: context.texts.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: <Widget>[
                    StatusPill(
                      label: controller.linkLabel,
                      tone: PillTone.neutral,
                      icon: Icons.lan_rounded,
                      compact: true,
                    ),
                    StatusPill(
                      label: controller.isEncrypted ? 'Encrypted' : 'Not encrypted',
                      tone: controller.isEncrypted
                          ? PillTone.good
                          : PillTone.caution,
                      icon: controller.isEncrypted
                          ? Icons.lock_rounded
                          : Icons.lock_open_rounded,
                      compact: true,
                      tooltip: controller.isEncrypted
                          ? 'Every frame is authenticated and encrypted with '
                              'per-session keys.'
                          : 'The single-phone demonstration has no second device '
                              'to exchange keys with.',
                    ),
                    if (state == TalkState.blocked)
                      const StatusPill(
                        label: 'They have the floor',
                        tone: PillTone.caution,
                        icon: Icons.record_voice_over_rounded,
                        compact: true,
                      ),
                  ],
                ),
              ],
            ),
          ),
          StatusPill(
            label: spec?.endonym ?? language,
            tone: PillTone.live,
            icon: Icons.translate_rounded,
            compact: true,
            onTap: () => _changeLanguage(context),
          ),
          IconButton(
            tooltip: 'Diagnostics',
            icon: const Icon(Icons.speed_rounded),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => DiagnosticsScreen(controller: controller),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _changeLanguage(BuildContext context) async {
    final String? chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Speaking language', style: context.texts.titleLarge),
            ),
            for (final LanguageSpec spec in Languages.all)
              ListTile(
                selected: spec.tag == controller.languageTag,
                title: Text('${spec.endonym}  ·  ${spec.englishName}'),
                subtitle: Text(controller.coverage(spec.tag).describe()),
                onTap: () => Navigator.of(context).pop(spec.tag),
              ),
          ],
        ),
      ),
    );
    if (chosen != null) await controller.setLanguage(chosen);
  }
}

class _DemoNotice extends StatelessWidget {
  const _DemoNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: context.colors.primary.withValues(alpha: 0.1),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      child: Row(
        children: <Widget>[
          Icon(Icons.science_rounded, size: 15, color: context.colors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Single-phone demonstration. The far end is simulated here, so '
              'your own message is spoken back to you.',
              style: context.texts.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _InlineBanner extends StatelessWidget {
  const _InlineBanner({
    required this.banner,
    required this.controller,
    required this.onDismiss,
  });

  final AppBanner banner;
  final AppController controller;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final (Color tint, IconData icon) = switch (banner.severity) {
      BannerSeverity.error => (
          context.colors.error,
          Icons.error_outline_rounded
        ),
      BannerSeverity.warning => (
          ItantraTheme.amber,
          Icons.warning_amber_rounded
        ),
      BannerSeverity.missingPack => (
          ItantraTheme.saffron,
          Icons.download_for_offline_rounded
        ),
      BannerSeverity.info => (
          context.colors.primary,
          Icons.info_outline_rounded
        ),
    };

    return Container(
      width: double.infinity,
      color: tint.withValues(alpha: context.isDark ? 0.16 : 0.1),
      padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 18, color: tint),
          const SizedBox(width: 10),
          Expanded(
            child: Text(banner.message, style: context.texts.bodySmall),
          ),
          if (banner.severity == BannerSeverity.missingPack)
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PacksScreen(controller: controller),
                ),
              ),
              child: const Text('Packs'),
            ),
          IconButton(
            tooltip: 'Dismiss',
            icon: const Icon(Icons.close_rounded, size: 17),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}

/// The transcript, newest at the bottom.
class _Transcript extends StatelessWidget {
  const _Transcript({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final List<StoredMessage> messages = controller.messages;

    if (messages.isEmpty) return const _EmptyTranscript();

    return ListView.builder(
      // Newest first in the list, rendered bottom-up: this avoids a
      // scroll-to-end animation on every arrival, which on a low-end phone is
      // jank exactly when the user is reading.
      reverse: true,
      padding: const EdgeInsets.only(top: 10, bottom: 16),
      itemCount: messages.length,
      itemBuilder: (BuildContext context, int index) {
        final StoredMessage message = messages[index];
        final StoredMessage? older =
            index + 1 < messages.length ? messages[index + 1] : null;
        final bool newDay = older == null ||
            isDifferentDay(message.createdAtMs, older.createdAtMs);

        return Column(
          children: <Widget>[
            // Bubbles are laid out oldest-first inside a reversed list, so the
            // entrance stagger has to be counted from the bottom.
            MessageBubble(
              message: message,
              index: index.clamp(0, 10),
              onReplay: () => controller.replay(message),
              onRetry: message.state == DeliveryState.failed
                  ? () => controller.retry(message)
                  : null,
            ),
            if (newDay && older != null)
              const _DayDivider(),
          ],
        );
      },
    );
  }
}

class _DayDivider extends StatelessWidget {
  const _DayDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
      child: Row(
        children: <Widget>[
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              'Earlier',
              style: context.texts.labelSmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }
}

class _EmptyTranscript extends StatelessWidget {
  const _EmptyTranscript();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ResponsiveBody(
        maxWidth: 420,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            FadeSlideIn(
              child: Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: context.colors.primary.withValues(alpha: 0.1),
                ),
                child: Icon(
                  Icons.record_voice_over_rounded,
                  size: 44,
                  color: context.colors.primary,
                ),
              ),
            ),
            const SizedBox(height: 20),
            FadeSlideIn(
              index: 1,
              child: Text(
                'Hold the button and speak',
                textAlign: TextAlign.center,
                style: context.texts.titleLarge,
              ),
            ),
            const SizedBox(height: 8),
            FadeSlideIn(
              index: 2,
              child: Text(
                'Your words are written down here and sent as text. The other '
                'phone reads them out loud. Everything stays on the two '
                'devices.',
                textAlign: TextAlign.center,
                style: context.texts.bodyMedium
                    ?.copyWith(color: context.colors.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Everything the user operates, in one panel.
class _ControlDeck extends StatelessWidget {
  const _ControlDeck({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        child: GlassPanel(
          radius: 28,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _ModeRow(controller: controller),
              const SizedBox(height: 10),
              _Meter(controller: controller),
              const SizedBox(height: 6),
              PttButton(
                state: controller.talkState,
                level: controller.level,
                blockedReason: controller.blockedReason,
                onPressStart: controller.pressTalk,
                onPressEnd: controller.releaseTalk,
                onNeedsSetup: () => openModels(context, controller),
              ),
              const SizedBox(height: 12),
              _ActionRow(controller: controller),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeRow extends StatelessWidget {
  const _ModeRow({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<SessionMode>(
      showSelectedIcon: false,
      segments: const <ButtonSegment<SessionMode>>[
        ButtonSegment<SessionMode>(
          value: SessionMode.pushToTalk,
          label: Text('Walkie-talkie'),
          icon: Icon(Icons.radio_button_checked_rounded, size: 18),
        ),
        ButtonSegment<SessionMode>(
          value: SessionMode.handsFree,
          label: Text('Hands-free'),
          icon: Icon(Icons.hearing_rounded, size: 18),
        ),
      ],
      selected: <SessionMode>{controller.mode},
      onSelectionChanged: (Set<SessionMode> selection) =>
          controller.setMode(selection.first),
    );
  }
}

/// The honest status line above the button.
class _Meter extends StatelessWidget {
  const _Meter({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final TalkState state = controller.talkState;
    final bool live = state == TalkState.talking;

    final String caption = switch (state) {
      TalkState.talking => 'Listening — release to send',
      TalkState.finishing => 'Recognising and sending',
      TalkState.ready => controller.mode == SessionMode.handsFree
          ? 'Hands-free: speak whenever you like'
          : 'Hold the button while you talk',
      TalkState.blocked => 'Half-duplex: waiting for the other phone',
      TalkState.setupNeeded =>
        'Add a recognition model to talk — typing works already',
      TalkState.preparing => 'Preparing the recogniser',
      TalkState.offline => 'Not connected',
    };

    return Column(
      children: <Widget>[
        SizedBox(
          height: 30,
          child: LiveWaveform(
            level: controller.level,
            active: live || state == TalkState.finishing,
            height: 30,
            barCount: 31,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          caption,
          textAlign: TextAlign.center,
          style: context.texts.bodySmall
              ?.copyWith(color: context.colors.onSurfaceVariant),
        ),
        if (controller.speedProfile.isThrottled)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              'Link limited to ${controller.speedProfile.bitsPerSecond} bit/s · '
              'a sentence takes about '
              '${(controller.estimatedMillisForMessage(40) / 1000).toStringAsFixed(1)}s',
              textAlign: TextAlign.center,
              style: context.texts.labelSmall?.copyWith(
                color: ItantraTheme.amber,
              ),
            ),
          ),
      ],
    );
  }
}

class _ActionRow extends StatefulWidget {
  const _ActionRow({required this.controller});

  final AppController controller;

  @override
  State<_ActionRow> createState() => _ActionRowState();
}

class _ActionRowState extends State<_ActionRow> {
  final TextEditingController _composer = TextEditingController();
  bool _composing = false;

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final String text = _composer.text.trim();
    if (text.isEmpty) return;
    await widget.controller.sendTyped(text);
    _composer.clear();
    if (mounted) setState(() => _composing = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_composing) {
      return Row(
        children: <Widget>[
          IconButton(
            tooltip: 'Cancel',
            icon: const Icon(Icons.close_rounded),
            onPressed: () => setState(() => _composing = false),
          ),
          Expanded(
            child: TextField(
              controller: _composer,
              autofocus: true,
              textInputAction: TextInputAction.send,
              maxLines: 3,
              minLines: 1,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                hintText: 'Type it, and the other phone will say it',
                suffixIcon: IconButton(
                  tooltip: 'Send',
                  icon: const Icon(Icons.send_rounded),
                  onPressed: _send,
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Row(
      children: <Widget>[
        _DeckAction(
          icon: Icons.keyboard_rounded,
          label: 'Type',
          onTap: () async {
            setState(() => _composing = true);
          },
        ),
        _DeckAction(
          icon: Icons.replay_rounded,
          label: 'Repeat',
          // Sends the one phrase that is worth having pre-written: in an
          // emergency, "say that again" should not depend on the recogniser
          // having just worked.
          onTap: () => widget.controller.sendTyped('Please repeat that.'),
        ),
        _DeckAction(
          icon: Icons.campaign_rounded,
          label: 'Alert',
          tint: ItantraTheme.alertRed,
          onTap: () => showAlertComposer(context, widget.controller),
        ),
        _DeckAction(
          icon: Icons.volume_off_rounded,
          label: 'Silence',
          onTap: widget.controller.silenceAlerts,
        ),
      ],
    );
  }
}

class _DeckAction extends StatelessWidget {
  const _DeckAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.tint,
  });

  final IconData icon;
  final String label;
  final Future<void> Function() onTap;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final Color color = tint ?? context.colors.onSurfaceVariant;
    return Expanded(
      child: Semantics(
        button: true,
        label: label,
        child: InkWell(
          onTap: () => unawaited(onTap()),
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(icon, size: 22, color: color),
                const SizedBox(height: 3),
                Text(
                  label,
                  style: context.texts.labelSmall?.copyWith(color: color),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
