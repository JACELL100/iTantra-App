import 'package:flutter/material.dart';

import '../core/models/engine_sources.dart';
import '../core/session/session_launcher.dart';
import '../core/storage/entities.dart';
import '../core/transport/transport_adapter.dart';
import 'animation.dart';
import 'app_controller.dart';
import 'format.dart';
import 'languages.dart';
import 'layout.dart';
import 'models_screen.dart';
import 'packs_screen.dart';
import 'settings_screen.dart';
import 'theme.dart';
import 'widgets/connect_sheet.dart';
import 'widgets/message_bubble.dart';
import 'widgets/status_pill.dart';

/// Session setup, and the app's front door once onboarding is done.
///
/// The screen answers one question - "how do I get connected to the other
/// phone?" - and then gets out of the way. Everything that is not part of that
/// question lives on another screen or behind a menu.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    // The toast queue is drained here rather than in a post-frame callback so
    // it lands on the first frame that actually has a Scaffold to host it.
    WidgetsBinding.instance.addPostFrameCallback((_) => _drainToast());
  }

  void _drainToast() {
    if (!mounted) return;
    final String? note = widget.controller.consumeToast();
    if (note == null) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(note)));
  }

  @override
  Widget build(BuildContext context) {
    final AppController controller = widget.controller;
    _drainToast();

    return PageScaffold(
      title: 'iTantra',
      accentIntensity: 0.9,
      actions: <Widget>[
        _ThemeToggle(controller: controller),
        IconButton(
          tooltip: 'Settings',
          icon: const Icon(Icons.tune_rounded),
          onPressed: () => _open(
            SettingsScreen(controller: controller),
          ),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (controller.banner case final AppBanner banner)
            _BannerCard(
              banner: banner,
              onDismiss: controller.dismissBanner,
            ),
          _StatusHero(controller: controller),
          const SizedBox(height: 8),
          _ConnectActions(controller: controller),
          _SpeedSection(controller: controller),
          _ModelSourceSection(controller: controller),
          _LanguageSection(controller: controller),
          _PackSummary(controller: controller),
          _RecentSection(controller: controller),
        ],
      ),
    );
  }

  void _open(Widget screen) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => screen),
    );
  }
}

class _ThemeToggle extends StatelessWidget {
  const _ThemeToggle({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final IconData icon = switch (controller.themeMode) {
      ThemeMode.light => Icons.light_mode_rounded,
      ThemeMode.dark => Icons.dark_mode_rounded,
      ThemeMode.system => Icons.brightness_auto_rounded,
    };

    return IconButton(
      tooltip: 'Appearance',
      icon: AnimatedSwitcher(
        duration: ItantraTheme.quick,
        child: Icon(icon, key: ValueKey<IconData>(icon)),
      ),
      onPressed: () => controller.setThemeMode(switch (controller.themeMode) {
        ThemeMode.system => ThemeMode.light,
        ThemeMode.light => ThemeMode.dark,
        ThemeMode.dark => ThemeMode.system,
      }),
    );
  }
}

/// The big piece of state on the home screen.
///
/// It has to answer "what is happening right now" without being read: a user
/// walking up to a phone should know from across a room whether it is linked,
/// starting up, or idle.
class _StatusHero extends StatelessWidget {
  const _StatusHero({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final LaunchState launch = controller.launch;
    final bool connecting = launch is LaunchConnecting;
    final bool verifying = launch is LaunchAwaitingVerification;
    final bool failed = launch is LaunchFailed;
    final bool idle = launch is LaunchIdle;

    final (IconData icon, String title, String detail, Color tint) =
        switch (launch) {
      LaunchConnecting(label: final String label, isHost: final bool host) => (
          host ? Icons.wifi_tethering_rounded : Icons.sync_rounded,
          host ? 'Waiting for the other phone' : 'Connecting',
          label,
          context.colors.primary,
        ),
      LaunchAwaitingVerification() => (
          Icons.verified_user_rounded,
          'Check the six digits',
          'Compare them with the other phone before continuing',
          ItantraTheme.amber,
        ),
      LaunchFailed(message: final String message) => (
          Icons.error_outline_rounded,
          'Could not connect',
          message,
          context.colors.error,
        ),
      _ => (
          Icons.cell_tower_rounded,
          'Ready to link',
          controller.hasRecognition
              ? 'Choose how to reach the other phone'
              : 'Install a recognition pack to speak — typing still works',
          context.colors.onSurfaceVariant,
        ),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 12, 0, 4),
      child: GlassPanel(
        radius: 26,
        padding: const EdgeInsets.all(20),
        child: Column(
          children: <Widget>[
            Stack(
              alignment: Alignment.center,
              children: <Widget>[
                if (connecting || verifying)
                  PulseRings(
                    color: tint,
                    minRadius: 40,
                    maxRadius: 62,
                    ringCount: 2,
                    strokeWidth: 2,
                  ),
                Container(
                  width: 84,
                  height: 84,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: tint.withValues(alpha: 0.14),
                    border: Border.all(color: tint.withValues(alpha: 0.35)),
                  ),
                  child: Icon(icon, size: 40, color: tint),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: context.texts.titleLarge,
            ),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: context.texts.bodyMedium
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
            if (connecting || verifying) ...<Widget>[
              const SizedBox(height: 14),
              const ClipRRect(
                borderRadius: BorderRadius.all(Radius.circular(3)),
                child: ActivitySweep(height: 3),
              ),
            ],
            if (!idle && !failed) ...<Widget>[
              const SizedBox(height: 14),
              TextButton.icon(
                onPressed: controller.disconnect,
                icon: const Icon(Icons.link_off_rounded, size: 18),
                label: const Text('Cancel'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ConnectActions extends StatelessWidget {
  const _ConnectActions({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final LaunchState launch = controller.launch;
    final bool busy = launch is LaunchConnecting || launch is LaunchAwaitingVerification;
    final ConnectionSpec? last = controller.lastConnection;

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 14, 0, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FilledButton.icon(
            onPressed: busy ? null : () => _startDemo(context),
            icon: const Icon(Icons.phone_iphone_rounded),
            label: const Text('Try it on this phone'),
          ),
          const SizedBox(height: 8),
          Text(
            'Runs the whole path — recognise, send, store, speak — with the '
            'far end simulated here. No second device needed.',
            textAlign: TextAlign.center,
            style: context.texts.bodySmall
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
          const SizedBox(height: 18),
          Row(
            children: <Widget>[
              const Expanded(child: Divider()),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  'OR LINK TWO PHONES',
                  style: context.texts.labelSmall
                      ?.copyWith(color: context.colors.onSurfaceVariant),
                ),
              ),
              const Expanded(child: Divider()),
            ],
          ),
          const SizedBox(height: 10),
          if (last != null && last.kind != TransportKind.loopback) ...<Widget>[
            OutlinedButton.icon(
              onPressed: busy ? null : controller.reconnectLast,
              icon: const Icon(Icons.history_rounded),
              label: Text('Reconnect · ${_kindLabel(last.kind)}'),
            ),
            const SizedBox(height: 10),
          ],
          FilledButton.tonalIcon(
            onPressed: busy
                ? null
                : () => showConnectSheet(context, controller),
            icon: const Icon(Icons.add_link_rounded),
            label: const Text('Set up a new link'),
          ),
        ],
      ),
    );
  }

  /// Starts the demonstration, setting up whatever is missing first.
  ///
  /// With nothing configured, the demonstration used to be a dead end: the
  /// talk button reported a missing model and the only way forward was a
  /// download. It now offers the one-tap combination that makes the whole loop
  /// work immediately - a labelled demonstration transcript and the voice the
  /// phone already has - and says plainly that the transcript is not recognised
  /// from speech. A real model is offered as the alternative in the same sheet.
  Future<void> _startDemo(BuildContext context) async {
    if (controller.hasRecognition && controller.hasVoice) {
      await controller.startDemo();
      return;
    }
    if (!context.mounted) return;

    final _DemoChoice? choice = await showModalBottomSheet<_DemoChoice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext context) => _DemoSetupSheet(controller: controller),
    );
    if (choice == null || !context.mounted) return;

    switch (choice) {
      case _DemoChoice.demonstration:
        if (!controller.hasRecognition) {
          await controller.setRecognitionSource(RecognitionSource.simulated);
        }
        if (!controller.hasVoice) {
          await controller.setVoiceSource(VoiceSource.device);
        }
        await controller.startDemo();
      case _DemoChoice.getModel:
        if (!context.mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ModelsScreen(controller: controller),
          ),
        );
    }
  }

  static String _kindLabel(TransportKind kind) => switch (kind) {
        TransportKind.wifiTcp => 'Wi-Fi',
        TransportKind.bluetoothRfcomm => 'Bluetooth',
        TransportKind.bleBridge => 'Radio bridge',
        TransportKind.loopback => 'This phone',
      };
}

enum _DemoChoice { demonstration, getModel }

/// What to do when the demonstration is asked for with nothing installed.
class _DemoSetupSheet extends StatelessWidget {
  const _DemoSetupSheet({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final List<String> missing = <String>[
      if (!controller.hasRecognition) 'recognise speech',
      if (!controller.hasVoice) 'speak replies',
    ];

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text('Nothing here can ${missing.join(' or ')} yet',
                style: context.texts.titleLarge),
            const SizedBox(height: 6),
            Text(
              'The demonstration needs a recogniser and a voice. Two ways to get '
              'them, and only one of them needs a download.',
              style: context.texts.bodyMedium
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
            const SizedBox(height: 18),
            _DemoOption(
              icon: Icons.bolt_rounded,
              title: 'Start now, no download',
              detail:
                  'Uses a demonstration transcript in place of recognition and '
                  'the voice this phone already has. The transcript is a fixed '
                  'example, not your words - the link, storage, playback and '
                  'timings are all real.',
              emphasised: true,
              onTap: () => Navigator.of(context).pop(_DemoChoice.demonstration),
            ),
            const SizedBox(height: 10),
            _DemoOption(
              icon: Icons.memory_rounded,
              title: 'Install a real model first',
              detail:
                  'Download a pack or import one you already have. Slower to set '
                  'up, and the only way the transcript is produced from speech.',
              onTap: () => Navigator.of(context).pop(_DemoChoice.getModel),
            ),
          ],
        ),
      ),
    );
  }
}

class _DemoOption extends StatelessWidget {
  const _DemoOption({
    required this.icon,
    required this.title,
    required this.detail,
    required this.onTap,
    this.emphasised = false,
  });

  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback onTap;
  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: emphasised
              ? context.colors.primaryContainer
                  .withValues(alpha: context.isDark ? 0.3 : 0.5)
              : context.colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: emphasised
                ? context.colors.primary.withValues(alpha: 0.7)
                : context.colors.outlineVariant,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(icon, size: 20, color: context.colors.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: context.texts.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    detail,
                    style: context.texts.bodySmall
                        ?.copyWith(color: context.colors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SpeedSection extends StatelessWidget {
  const _SpeedSection({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final SpeedProfile selected = controller.speedProfile;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionHeader(
          title: 'Link budget',
          subtitle: 'The same conversation, honestly measured on a slower link',
          icon: Icons.speed_rounded,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 0),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final SpeedProfile profile in SpeedProfile.values)
                ChoiceChip(
                  selected: profile == selected,
                  onSelected: (_) => controller.setSpeedProfile(profile),
                  label: Text(profile.label),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 10, 0, 0),
          child: Text(
            selected.isThrottled
                ? 'Messages are rate-limited to ${selected.bitsPerSecond} bit/s '
                    'with ${selected.oneWayLatencyMs} ms of one-way delay, which '
                    'is what a real narrowband link costs.'
                : 'No artificial limit. Timing is whatever the radio and the '
                    'recogniser actually take.',
            style: context.texts.bodySmall
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

/// Where recognition and speech happen, as a pair of pills that double as the
/// way into the settings.
///
/// On the front screen because it changes what the app can do, and because the
/// demonstrations a judge or a user runs depend on it. Three taps deep is where
/// a setting like this becomes invisible.
class _ModelSourceSection extends StatelessWidget {
  const _ModelSourceSection({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final bool canHear = controller.hasRecognition;
    final bool canSpeak = controller.hasVoice;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SectionHeader(
          title: 'Speech engines',
          subtitle: 'Recognition and voice, and where each one runs',
          icon: Icons.tune_rounded,
          trailing: TextButton(
            onPressed: () => _open(context),
            child: const Text('Change'),
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            StatusPill(
              label: controller.recognitionSource.shortLabel,
              tone: canHear ? PillTone.good : PillTone.caution,
              icon: canHear
                  ? Icons.hearing_rounded
                  : Icons.hearing_disabled_rounded,
              onTap: () => _open(context),
            ),
            StatusPill(
              label: controller.voiceSource.label,
              tone: canSpeak ? PillTone.good : PillTone.caution,
              icon: canSpeak
                  ? Icons.graphic_eq_rounded
                  : Icons.volume_off_rounded,
              onTap: () => _open(context),
            ),
            if (controller.isSimulatedRecognition)
              const StatusPill(
                label: 'Simulated text',
                tone: PillTone.caution,
                icon: Icons.science_outlined,
                tooltip: 'Text on screen is a fixed example, not recognised '
                    'speech',
              ),
            if (controller.recognitionLeavesDevice ||
                controller.voiceLeavesDevice)
              StatusPill(
                label: 'Cloud · ${controller.cloudConfig.host}',
                tone: PillTone.caution,
                icon: Icons.cloud_outlined,
                tooltip: 'Audio or text leaves this phone',
              ),
          ],
        ),
        if (!canHear || !canSpeak)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              !canHear && !canSpeak
                  ? 'Nothing on this phone can recognise or speak yet. Typed '
                      'messages and alerts still work, and the demonstration '
                      'can run without any download.'
                  : !canHear
                      ? 'Speech cannot be recognised yet. Typed messages and '
                          'alerts still work.'
                      : 'Replies will be silent. Messages are still stored and '
                          'shown.',
              style: context.texts.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ),
      ],
    );
  }

  void _open(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ModelsScreen(controller: controller),
      ),
    );
  }
}

class _LanguageSection extends StatelessWidget {
  const _LanguageSection({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final List<LanguageSpec> installed = controller.installedLanguages;
    final LanguageSpec? current = Languages.byTag(controller.languageTag);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SectionHeader(
          title: 'Speaking language',
          subtitle: current == null
              ? controller.languageTag
              : '${current.endonym} · ${current.englishName}',
          icon: Icons.translate_rounded,
          trailing: TextButton(
            onPressed: () => _pick(context),
            child: const Text('Change'),
          ),
        ),
        if (installed.isEmpty)
          Text(
            'No language packs installed, so nothing can be recognised or '
            'spoken yet. Typed messages and alerts still work.',
            style: context.texts.bodySmall
                ?.copyWith(color: context.colors.onSurfaceVariant),
          )
        else
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.zero,
              itemCount: installed.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (BuildContext context, int index) {
                final LanguageSpec spec = installed[index];
                final bool ready = controller.readyLanguages.contains(spec.tag);
                return FilterChip(
                  selected: spec.tag == controller.languageTag,
                  avatar: Icon(
                    ready
                        ? Icons.check_circle_rounded
                        : Icons.info_outline_rounded,
                    size: 17,
                  ),
                  label: Text(spec.endonym),
                  onSelected: (_) => controller.setLanguage(spec.tag),
                );
              },
            ),
          ),
      ],
    );
  }

  Future<void> _pick(BuildContext context) async {
    final String? chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext context) => _LanguageSheet(controller: controller),
    );
    if (chosen != null) await controller.setLanguage(chosen);
  }
}

class _LanguageSheet extends StatelessWidget {
  const _LanguageSheet({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 12),
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text('Speaking language',
                style: context.texts.titleLarge),
          ),
          for (final LanguageSpec spec in Languages.all)
            _LanguageRow(
              spec: spec,
              selected: spec.tag == controller.languageTag,
              summary: controller.coverage(spec.tag).describe(),
              onTap: () => Navigator.of(context).pop(spec.tag),
            ),
        ],
      ),
    );
  }
}

class _LanguageRow extends StatelessWidget {
  const _LanguageRow({
    required this.spec,
    required this.selected,
    required this.summary,
    required this.onTap,
  });

  final LanguageSpec spec;
  final bool selected;
  final String summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: AnimatedContainer(
        duration: ItantraTheme.quick,
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: selected
              ? context.colors.primary
              : context.colors.surfaceContainerHigh,
        ),
        child: Center(
          child: Text(
            spec.tag.split('-').first.toUpperCase(),
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 12,
              color: selected
                  ? context.colors.onPrimary
                  : context.colors.onSurfaceVariant,
            ),
          ),
        ),
      ),
      title: Row(
        children: <Widget>[
          Flexible(child: Text(spec.endonym)),
          const SizedBox(width: 8),
          Text(
            spec.englishName,
            style: context.texts.bodySmall
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
        ],
      ),
      subtitle: Text(summary),
      trailing: selected
          ? Icon(Icons.check_circle_rounded, color: context.colors.primary)
          : null,
    );
  }
}

class _PackSummary extends StatelessWidget {
  const _PackSummary({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SectionHeader(
          title: 'On this phone',
          subtitle: 'Recognition and speech models, stored locally',
          icon: Icons.memory_rounded,
          trailing: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => PacksScreen(controller: controller),
              ),
            ),
            child: const Text('Manage'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 0),
          child: Row(
            children: <Widget>[
              StatusPill(
                label: '${controller.asrCount} recognition',
                tone: controller.asrCount > 0 ? PillTone.good : PillTone.caution,
                icon: Icons.mic_rounded,
              ),
              const SizedBox(width: 8),
              StatusPill(
                label: '${controller.ttsCount} voice',
                tone: controller.ttsCount > 0 ? PillTone.good : PillTone.caution,
                icon: Icons.volume_up_rounded,
              ),
              const SizedBox(width: 8),
              StatusPill(
                label: bytes(controller.packBytes),
                tone: PillTone.neutral,
                icon: Icons.sd_storage_rounded,
              ),
            ],
          ),
        ),
        if (controller.packProblems.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 10, 0, 0),
            child: Text(
              '${controller.packProblems.length} pack problem'
              '${controller.packProblems.length == 1 ? '' : 's'} reported. '
              'Open Manage to see which.',
              style: context.texts.bodySmall?.copyWith(
                color: context.colors.error,
              ),
            ),
          ),
      ],
    );
  }
}

class _RecentSection extends StatelessWidget {
  const _RecentSection({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final List<StoredMessage> recent =
        controller.messages.take(4).toList(growable: false);
    if (recent.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionHeader(
          title: 'Recent',
          subtitle: 'Restored from this phone, before any link exists',
          icon: Icons.history_rounded,
        ),
        for (int i = 0; i < recent.length; i++)
          Opacity(
            // Older entries fade out, so the section reads as a tail rather
            // than as a list that happens to be short.
            opacity: 1 - i * 0.18,
            child: MessageBubble(
              message: recent[i],
              index: i,
              onReplay: () => controller.replay(recent[i]),
            ),
          ),
      ],
    );
  }
}

class _BannerCard extends StatelessWidget {
  const _BannerCard({required this.banner, required this.onDismiss});

  final AppBanner banner;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final (Color tint, IconData icon) = switch (banner.severity) {
      BannerSeverity.error => (context.colors.error, Icons.error_outline_rounded),
      BannerSeverity.warning => (ItantraTheme.amber, Icons.warning_amber_rounded),
      BannerSeverity.missingPack => (
          ItantraTheme.saffron,
          Icons.download_for_offline_rounded
        ),
      BannerSeverity.info => (
          context.colors.primary,
          Icons.info_outline_rounded
        ),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        decoration: BoxDecoration(
          color: tint.withValues(alpha: context.isDark ? 0.16 : 0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: tint.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 20, color: tint),
            const SizedBox(width: 12),
            Expanded(
              child: Text(banner.message, style: context.texts.bodyMedium),
            ),
            if (banner.action case final Future<void> Function() action)
              TextButton(
                onPressed: () => action(),
                child: Text(banner.actionLabel ?? 'Retry'),
              ),
            IconButton(
              tooltip: 'Dismiss',
              icon: const Icon(Icons.close_rounded, size: 18),
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}
