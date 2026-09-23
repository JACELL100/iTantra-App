import 'package:flutter/material.dart';

import '../core/models/model_pack.dart';
import '../core/platform/platform_capabilities.dart';
import '../core/platform/permissions.dart';
import 'animation.dart';
import 'app_controller.dart';
import 'languages.dart';
import 'packs_screen.dart';
import 'theme.dart';
import 'widgets/status_pill.dart';

/// First run.
///
/// Four short pages, and each one earns its place by changing what the user
/// can do rather than by explaining the project: what this actually is, which
/// language to speak, which packs are installed, and whether loud alerts are
/// consented to. Permissions are asked for on the page that needs them, never
/// at launch.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pages = PageController();
  int _page = 0;

  static const int _pageCount = 4;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    await widget.controller.completeOnboarding();
  }

  void _go(int page) {
    _pages.animateToPage(
      page,
      duration: ItantraTheme.medium,
      curve: ItantraTheme.emphasizeCurve,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GradientBackdrop(
        intensity: 0.7,
        child: SafeArea(
          child: Column(
            children: <Widget>[
              Expanded(
                child: PageView(
                  controller: _pages,
                  onPageChanged: (int page) => setState(() => _page = page),
                  children: <Widget>[
                    _PromisePage(onNext: () => _go(1)),
                    _LanguagePage(controller: widget.controller),
                    _PacksPage(controller: widget.controller),
                    _AlertsPage(controller: widget.controller),
                  ],
                ),
              ),
              _Footer(
                page: _page,
                count: _pageCount,
                onSkip: _finish,
                onNext: _page == _pageCount - 1
                    ? _finish
                    : () => _go(_page + 1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.page,
    required this.count,
    required this.onSkip,
    required this.onNext,
  });

  final int page;
  final int count;
  final VoidCallback onSkip;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final bool last = page == count - 1;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: Column(
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              for (int i = 0; i < count; i++)
                AnimatedContainer(
                  duration: ItantraTheme.quick,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  height: 6,
                  width: i == page ? 26 : 6,
                  decoration: BoxDecoration(
                    color: i == page
                        ? context.colors.primary
                        : context.colors.outlineVariant,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 18),
          FilledButton(
            onPressed: onNext,
            child: Text(last ? 'Start using iTantra' : 'Continue'),
          ),
          const SizedBox(height: 4),
          TextButton(
            onPressed: onSkip,
            child: const Text('Skip the introduction'),
          ),
        ],
      ),
    );
  }
}

/// A page laid out the same way every time, so moving between them feels like
/// turning a page rather than arriving somewhere new.
class _PageScaffold extends StatelessWidget {
  const _PageScaffold({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final List<Widget> body;

  @override
  Widget build(BuildContext context) {
    return ResponsiveBody(
      maxWidth: 560,
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: ListView(
        padding: EdgeInsets.zero,
        children: <Widget>[
          const SizedBox(height: 20),
          FadeSlideIn(
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: context.colors.primary.withValues(alpha: 0.12),
                border: Border.all(
                  color: context.colors.primary.withValues(alpha: 0.28),
                ),
              ),
              child: Icon(icon, size: 40, color: context.colors.primary),
            ),
          ),
          const SizedBox(height: 22),
          FadeSlideIn(
            index: 1,
            child: Text(title, style: context.texts.headlineMedium),
          ),
          const SizedBox(height: 14),
          for (int i = 0; i < body.length; i++)
            FadeSlideIn(index: i + 2, child: body[i]),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _PromisePage extends StatelessWidget {
  const _PromisePage({required this.onNext});

  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return _PageScaffold(
      icon: Icons.cell_tower_rounded,
      title: 'Speak. It arrives as speech.',
      body: <Widget>[
        Text(
          'iTantra turns what you say into text, sends that text over a '
          'Wi-Fi or Bluetooth link, and the other phone says it out loud in '
          'the same language. A sentence costs a few hundred bytes instead of '
          'tens of kilobytes, which is what lets it work on a link that could '
          'never carry a voice call.',
          style: context.texts.bodyLarge,
        ),
        const SizedBox(height: 20),
        const _FactRow(
          icon: Icons.lock_outline_rounded,
          title: 'Nothing leaves the two phones',
          detail: 'Recognition and speech run on the device. There is no '
              'account, no server and no upload.',
        ),
        const _FactRow(
          icon: Icons.translate_rounded,
          title: 'Ten languages, same language both ends',
          detail: 'Hindi, Bengali, Gujarati, Marathi, Kannada, Malayalam, '
              'Tamil, Telugu, Odia and Indian English.',
        ),
        const _FactRow(
          icon: Icons.record_voice_over_rounded,
          title: 'Hear it, and read it',
          detail: 'Every message stays on screen, so it can be replayed or '
              'read in a noisy place.',
        ),
        const SizedBox(height: 8),
        const _HonestyNote(
          'What this is not: it is not a voice call. Tone, emotion and '
          'background sound are lost, and a recognition mistake can change a '
          'word. Treat it as a message service, not as a telephone.',
        ),
      ],
    );
  }
}

class _FactRow extends StatelessWidget {
  const _FactRow({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: context.colors.surfaceContainerHigh,
            ),
            child: Icon(icon, size: 20, color: context.colors.onSurfaceVariant),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: context.texts.titleSmall),
                const SizedBox(height: 3),
                Text(
                  detail,
                  style: context.texts.bodyMedium
                      ?.copyWith(color: context.colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HonestyNote extends StatelessWidget {
  const _HonestyNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: ItantraTheme.amber.withValues(alpha: context.isDark ? 0.14 : 0.1),
        border: Border.all(
          color: ItantraTheme.amber.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(Icons.info_outline_rounded,
              size: 19, color: ItantraTheme.amber),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: context.texts.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _LanguagePage extends StatelessWidget {
  const _LanguagePage({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return _PageScaffold(
      icon: Icons.translate_rounded,
      title: 'Which language will you speak?',
      body: <Widget>[
        Text(
          'This is the language you talk in. The other phone reads the '
          'language from each message, so it always answers in the right '
          'voice, whatever its own setting is.',
          style: context.texts.bodyMedium
              ?.copyWith(color: context.colors.onSurfaceVariant),
        ),
        const SizedBox(height: 14),
        for (final LanguageSpec spec in Languages.all)
          _LanguageTile(
            spec: spec,
            selected: controller.languageTag == spec.tag,
            coverage: controller.coverage(spec.tag).describe(),
            onTap: () => controller.setLanguage(spec.tag),
          ),
      ],
    );
  }
}

class _LanguageTile extends StatelessWidget {
  const _LanguageTile({
    required this.spec,
    required this.selected,
    required this.coverage,
    required this.onTap,
  });

  final LanguageSpec spec;
  final bool selected;
  final String coverage;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected
            ? context.colors.primaryContainer
            : context.colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Text(spec.endonym, style: context.texts.titleSmall),
                          const SizedBox(width: 8),
                          Text(
                            spec.englishName,
                            style: context.texts.bodySmall?.copyWith(
                              color: context.colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        coverage,
                        style: context.texts.bodySmall?.copyWith(
                          color: context.colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                AnimatedSwitcher(
                  duration: ItantraTheme.quick,
                  child: selected
                      ? Icon(Icons.check_circle_rounded,
                          key: const ValueKey<String>('on'),
                          color: context.colors.primary)
                      : Icon(Icons.circle_outlined,
                          key: const ValueKey<String>('off'),
                          color: context.colors.outlineVariant),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PacksPage extends StatefulWidget {
  const _PacksPage({required this.controller});

  final AppController controller;

  @override
  State<_PacksPage> createState() => _PacksPageState();
}

class _PacksPageState extends State<_PacksPage> {
  bool _scanning = false;

  Future<void> _rescan() async {
    setState(() => _scanning = true);
    await widget.controller.refreshPacks();
    if (mounted) setState(() => _scanning = false);
  }

  @override
  Widget build(BuildContext context) {
    final List<ModelPack> packs = widget.controller.installedPacks;

    return _PageScaffold(
      icon: Icons.memory_rounded,
      title: 'Language packs',
      body: <Widget>[
        Text(
          'The speech models are not inside the app. They are hundreds of '
          'megabytes and several carry licences that forbid redistribution, so '
          'they are installed on the phone separately. Everything below is '
          'already on this device and stays on it.',
          style: context.texts.bodyMedium
              ?.copyWith(color: context.colors.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            StatusPill(
              label: '${widget.controller.asrCount} recognition',
              tone: widget.controller.asrCount > 0
                  ? PillTone.good
                  : PillTone.caution,
              icon: Icons.mic_rounded,
            ),
            const SizedBox(width: 8),
            StatusPill(
              label: '${widget.controller.ttsCount} voice',
              tone:
                  widget.controller.ttsCount > 0 ? PillTone.good : PillTone.caution,
              icon: Icons.volume_up_rounded,
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (packs.isEmpty)
          const _HonestyNote(
            'No packs found yet. You can still open the app and pair, and '
            'typed messages and alerts will be delivered — but nothing can be '
            'recognised or spoken until a pack is installed.',
          )
        else
          for (final ModelPack pack in packs)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(pack.role == PackRole.asr
                  ? Icons.mic_rounded
                  : Icons.volume_up_rounded),
              title: Text('${pack.languageTag} · ${pack.role.name}'),
              subtitle: Text(
                '${pack.describeSize()} · ${pack.licence}'
                '${pack.isRedistributable ? '' : ' · non-redistributable'}',
              ),
            ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _scanning ? null : _rescan,
                icon: _scanning
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded),
                label: const Text('Rescan'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => PacksScreen(controller: widget.controller),
                  ),
                ),
                icon: const Icon(Icons.folder_open_rounded),
                label: const Text('Manage'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _AlertsPage extends StatefulWidget {
  const _AlertsPage({required this.controller});

  final AppController controller;

  @override
  State<_AlertsPage> createState() => _AlertsPageState();
}

class _AlertsPageState extends State<_AlertsPage> {
  late bool _armed = widget.controller.alertsArmed;
  PermissionOutcome? _mic;
  bool _checkingMic = false;
  bool _tested = false;

  PlatformCapabilities get _capabilities => widget.controller.capabilities;

  Future<void> _armAlerts(bool value) async {
    await widget.controller.setAlertsArmed(value);
    if (mounted) setState(() => _armed = value);
  }

  Future<void> _playTest() async {
    setState(() => _tested = true);
    // A short local alert through the real alert path, so the user hears the
    // volume and the interruption behaviour before relying on it. If no voice
    // pack is installed the test still runs and reports honestly.
    await widget.controller.testAlertTone();
  }

  Future<void> _askMic() async {
    setState(() => _checkingMic = true);
    final PermissionOutcome outcome =
        await Permissions.request(AppPermission.microphone);
    if (!mounted) return;
    setState(() {
      _mic = outcome;
      _checkingMic = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return _PageScaffold(
      icon: Icons.campaign_rounded,
      title: 'Alerts and permissions',
      body: <Widget>[
        _PermissionTile(
          permission: AppPermission.microphone,
          outcome: _mic,
          busy: _checkingMic,
          onRequest: _askMic,
        ),
        const SizedBox(height: 10),
        _PermissionTile(
          permission: AppPermission.notifications,
          outcome: null,
          busy: false,
          onRequest: () async {
            await Permissions.request(AppPermission.notifications);
            if (mounted) setState(() {});
          },
        ),
        const SizedBox(height: 20),
        Material(
          color: context.colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('Allow loud alerts',
                          style: context.texts.titleSmall),
                      const SizedBox(height: 3),
                      Text(
                        'A distress alert takes audio focus, raises the alarm '
                        'volume and repeats itself. Ordinary messages can '
                        'never interrupt one.',
                        style: context.texts.bodySmall
                            ?.copyWith(color: context.colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                Switch(value: _armed, onChanged: _armAlerts),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _armed ? _playTest : null,
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(_tested ? 'Play the test again' : 'Play a test alert'),
        ),
        const SizedBox(height: 16),
        if (!_capabilities.canForceAlertVolume)
          const _HonestyNote(
            'This device does not let an app change the output volume. Alerts '
            'will interrupt other audio and will be heard even with the ringer '
            'silenced, but they play at the level you have set. Turn the volume '
            'up if you intend to rely on them.',
          )
        else
          const _HonestyNote(
            'Alerts play at maximum alarm volume on this device. Android still '
            'lets a phone call take precedence — no app can override that, and '
            'this one does not pretend to.',
          ),
      ],
    );
  }
}

class _PermissionTile extends StatelessWidget {
  const _PermissionTile({
    required this.permission,
    required this.outcome,
    required this.busy,
    required this.onRequest,
  });

  final AppPermission permission;
  final PermissionOutcome? outcome;
  final bool busy;
  final Future<void> Function() onRequest;

  @override
  Widget build(BuildContext context) {
    final PermissionOutcome? status = outcome;

    final (PillTone tone, String label, IconData icon) = switch (status) {
      PermissionOutcome.granted => (PillTone.good, 'Allowed', Icons.check_rounded),
      PermissionOutcome.denied => (
          PillTone.caution,
          'Not now',
          Icons.schedule_rounded
        ),
      PermissionOutcome.permanentlyDenied => (
          PillTone.alert,
          'Blocked in settings',
          Icons.block_rounded
        ),
      PermissionOutcome.notApplicable => (
          PillTone.neutral,
          'Not needed here',
          Icons.remove_circle_outline_rounded
        ),
      null => (PillTone.neutral, 'Not asked yet', Icons.help_outline_rounded),
    };

    return Material(
      color: context.colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(permission.label,
                      style: context.texts.titleSmall),
                ),
                StatusPill(label: label, tone: tone, icon: icon, compact: true),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              permission.rationale,
              style: context.texts.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: busy
                    ? null
                    : status == PermissionOutcome.permanentlyDenied
                        ? () async {
                            await Permissions.openSettings();
                          }
                        : onRequest,
                child: Text(
                  busy
                      ? 'Asking…'
                      : status == PermissionOutcome.permanentlyDenied
                          ? 'Open settings'
                          : status == PermissionOutcome.granted
                              ? 'Allowed'
                              : 'Allow',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
