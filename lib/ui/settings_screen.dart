import 'package:flutter/material.dart';

import '../core/platform/platform_capabilities.dart';
import '../core/session/session_controller.dart';
import '../core/session/session_launcher.dart';
import '../core/version.dart';
import '../di/service_locator.dart';
import 'animation.dart';
import 'app_controller.dart';
import 'format.dart';
import 'languages.dart';
import 'packs_screen.dart';
import 'theme.dart';
import 'widgets/status_pill.dart';

/// Everything the user can change, in one place.
///
/// Ordered by how often it is touched, not by how it is implemented: appearance
/// and the talk behaviour first, then language, then packs. The pack section
/// stays near the top despite being rarely pressed because it is the one thing
/// that explains why a language is greyed out - and on this app an unexplained
/// greyed-out language looks like a bug rather than a missing download.
///
/// Device limitations are stated rather than hidden. On iOS the app cannot
/// raise the output volume, so the alert row says so plainly: a guarantee that
/// cannot be kept is worse than an honest caveat, especially for a distress
/// feature.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false;
  Map<String, bool>? _verify;

  AppController get _controller => widget.controller;

  Future<void> _rescan() async {
    setState(() => _busy = true);
    await _controller.refreshPacks();
    if (mounted) {
      setState(() {
        _busy = false;
        _verify = null;
      });
    }
  }

  Future<void> _verifyPacks() async {
    setState(() => _busy = true);
    final Map<String, bool> result = await _controller.verifyPacks();
    if (mounted) {
      setState(() {
        _verify = result;
        _busy = false;
      });
    }
  }

  Future<void> _clearTranscript() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Clear the transcript?'),
        content: const Text(
          'Every message on this phone is deleted. Paired devices and your '
          'language packs are kept.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _controller.clearHistory();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Transcript cleared')),
      );
    }
  }

  Future<void> _editName() async {
    final TextEditingController field =
        TextEditingController(text: _controller.displayName);
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Name this phone'),
        content: TextField(
          controller: field,
          autofocus: true,
          maxLength: 24,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Shown on the other phone',
            hintText: 'Rescue team 1',
          ),
          onSubmitted: (String value) => Navigator.of(context).pop(value),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(field.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    field.dispose();
    if (name == null || name.trim().isEmpty) return;
    await _controller.setDisplayName(name.trim());
  }

  Future<void> _openPacks() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PacksScreen(controller: _controller),
      ),
    );
    if (mounted) await _rescan();
  }

  @override
  Widget build(BuildContext context) {
    final AppController controller = _controller;
    final PlatformCapabilities caps = controller.capabilities;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Rescan packs',
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
            onPressed: _busy ? null : _rescan,
          ),
        ],
      ),
      body: GradientBackdrop(
        intensity: 0.35,
        child: ListView(
          children: <Widget>[
            ResponsiveBody(
              maxWidth: 760,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // -----------------------------------------------------------
                  // Appearance
                  // -----------------------------------------------------------
                  const SectionHeader(
                    title: 'Appearance',
                    subtitle: 'Both themes are tuned for field use, not for a '
                        'calibrated screen',
                    icon: Icons.palette_rounded,
                  ),
                  _ChoiceCard<ThemeMode>(
                    value: controller.themeMode,
                    options: const <_Choice<ThemeMode>>[
                      _Choice<ThemeMode>(
                        ThemeMode.system,
                        'Match the phone',
                        Icons.brightness_auto_rounded,
                      ),
                      _Choice<ThemeMode>(
                        ThemeMode.light,
                        'Light',
                        Icons.light_mode_rounded,
                      ),
                      _Choice<ThemeMode>(
                        ThemeMode.dark,
                        'Dark',
                        Icons.dark_mode_rounded,
                      ),
                    ],
                    onChanged: controller.setThemeMode,
                  ),

                  // -----------------------------------------------------------
                  // Talking
                  // -----------------------------------------------------------
                  const SectionHeader(
                    title: 'Talking',
                    subtitle: 'How the microphone behaves on this phone',
                    icon: Icons.record_voice_over_rounded,
                  ),
                  _ChoiceCard<SessionMode>(
                    value: controller.mode,
                    options: const <_Choice<SessionMode>>[
                      _Choice<SessionMode>(
                        SessionMode.pushToTalk,
                        'Push to talk',
                        Icons.touch_app_rounded,
                      ),
                      _Choice<SessionMode>(
                        SessionMode.handsFree,
                        'Hands-free',
                        Icons.hearing_rounded,
                      ),
                    ],
                    onChanged: controller.setMode,
                  ),
                  GlassPanel(
                    padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
                    child: SwitchListTile(
                      value: controller.hapticsEnabled,
                      onChanged: controller.setHapticsEnabled,
                      title: const Text('Vibrate for each outcome'),
                      subtitle: const Text(
                        'A different pattern for talking, sent, delivered, '
                        'warnings, alerts and failures, so the state of the app '
                        'can be followed without looking at it. Turn this off '
                        'to stay silent - alerts still sound.',
                      ),
                    ),
                  ),
                  const _Explain(
                    'Push-to-talk keeps the microphone closed until you hold '
                    'the button, which is why the app can sit idle for hours on '
                    'one charge. Hands-free listens continuously and decides '
                    'where sentences end, which is friendlier but costs battery.',
                  ),

                  const SectionHeader(
                    title: 'Link profile',
                    subtitle: 'Simulate a constrained radio, or use the link at '
                        'full speed',
                    icon: Icons.speed_rounded,
                  ),
                  _SpeedCard(
                    value: controller.speedProfile,
                    onChanged: controller.setSpeedProfile,
                  ),

                  // -----------------------------------------------------------
                  // Alerts
                  // -----------------------------------------------------------
                  const SectionHeader(
                    title: 'Alerts',
                    subtitle: 'The loudest thing this app can do',
                    icon: Icons.campaign_rounded,
                  ),
                  GlassPanel(
                    padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
                    child: Column(
                      children: <Widget>[
                        SwitchListTile(
                          value: controller.alertsArmed,
                          onChanged: controller.setAlertsArmed,
                          title: const Text('Allow alerts to take over audio'),
                          subtitle: Text(
                            caps.canForceAlertVolume
                                ? 'A distress or warning message will interrupt '
                                    'whatever is playing, ignore the silent '
                                    'switch and play at maximum volume.'
                                : 'A distress message will interrupt whatever is '
                                    'playing and ignore the silent switch. This '
                                    'device does not let an app change the '
                                    'volume itself, so turn the volume up if '
                                    'you are relying on alerts.',
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            children: <Widget>[
                              StatusPill(
                                label: caps.canForceAlertVolume
                                    ? 'Volume can be forced'
                                    : 'Volume stays as set',
                                tone: caps.canForceAlertVolume
                                    ? PillTone.good
                                    : PillTone.caution,
                                icon: caps.canForceAlertVolume
                                    ? Icons.volume_up_rounded
                                    : Icons.volume_off_rounded,
                                compact: true,
                              ),
                              const Spacer(),
                              TextButton.icon(
                                onPressed: controller.testAlertTone,
                                icon: const Icon(Icons.play_arrow_rounded),
                                label: const Text('Hear it'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  // -----------------------------------------------------------
                  // Language
                  // -----------------------------------------------------------
                  const SectionHeader(
                    title: 'Language',
                    subtitle: 'What this phone speaks and listens in',
                    icon: Icons.translate_rounded,
                  ),
                  GlassPanel(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      children: <Widget>[
                        for (final LanguageSpec spec in Languages.all)
                          _LanguageTile(
                            spec: spec,
                            selected: spec.tag == controller.languageTag,
                            report: controller.coverage(spec.tag),
                            onTap: () => controller.setLanguage(spec.tag),
                          ),
                      ],
                    ),
                  ),

                  // -----------------------------------------------------------
                  // Packs
                  // -----------------------------------------------------------
                  const SectionHeader(
                    title: 'Language packs',
                    subtitle: 'Model weights live outside the app, so you choose '
                        'the licences',
                    icon: Icons.inventory_2_rounded,
                  ),
                  GlassPanel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: Text('On this phone',
                                  style: context.texts.titleSmall),
                            ),
                            Text(
                              bytes(controller.packBytes),
                              style: context.texts.titleSmall
                                  ?.copyWith(color: context.colors.primary),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: <Widget>[
                            StatusPill(
                              label: '${controller.asrCount} recognition',
                              tone: controller.asrCount > 0
                                  ? PillTone.good
                                  : PillTone.caution,
                              icon: Icons.mic_rounded,
                              compact: true,
                            ),
                            StatusPill(
                              label: '${controller.ttsCount} voice',
                              tone: controller.ttsCount > 0
                                  ? PillTone.good
                                  : PillTone.caution,
                              icon: Icons.volume_up_rounded,
                              compact: true,
                            ),
                            if (_verify != null)
                              StatusPill(
                                label: _verify!.values
                                        .every((bool ok) => ok)
                                    ? 'Checksums good'
                                    : 'Checksum failure',
                                tone: _verify!.values
                                        .every((bool ok) => ok)
                                    ? PillTone.good
                                    : PillTone.alert,
                                icon: _verify!.values
                                        .every((bool ok) => ok)
                                    ? Icons.verified_rounded
                                    : Icons.report_gmailerrorred_rounded,
                                compact: true,
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _busy ? null : _verifyPacks,
                                icon: const Icon(Icons.verified_rounded),
                                label: const Text('Check files'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: _openPacks,
                                icon: const Icon(Icons.folder_rounded),
                                label: const Text('Manage'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (controller.packProblems.isNotEmpty)
                    _WarnList(problems: controller.packProblems),

                  // -----------------------------------------------------------
                  // Device
                  // -----------------------------------------------------------
                  const SectionHeader(
                    title: 'This device',
                    subtitle: 'Probed from the operating system at launch',
                    icon: Icons.phone_android_rounded,
                  ),
                  GlassPanel(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      children: <Widget>[
                        _Fact('Model', caps.deviceModel),
                        _Fact(
                          'System',
                          '${caps.platform == 'ios' ? 'iOS' : 'Android'} '
                              '${caps.osVersion}',
                        ),
                        _Fact(
                          'Identity',
                          controller.displayName,
                          onTap: _editName,
                          action: 'Change',
                        ),
                        _Fact(
                          'Wi-Fi links',
                          caps.supportsWifiTcp ? 'Supported' : 'Unavailable',
                        ),
                        _Fact(
                          'Bluetooth Classic',
                          caps.supportsRfcommClassic
                              ? 'Supported'
                              : 'Restricted on this device',
                        ),
                        _Fact(
                          'Radio bridge',
                          caps.supportsBleBridge ? 'Supported' : 'Unavailable',
                        ),
                        _Fact(
                          'Can create a network',
                          caps.canHostSoftAp
                              ? 'Yes — this phone can host'
                              : 'No — this phone must join',
                        ),
                        _Fact(
                          'Audio with screen off',
                          caps.backgroundAudioMode ? 'Keeps playing' : 'Pauses',
                        ),
                        if (!caps.canHostSoftAp)
                          const _Explain(
                            'In a mixed pair with an iPhone, this phone should '
                            'be the one that joins, because an iPhone cannot '
                            'create a local network. Two Android phones can '
                            'connect either way round.',
                          ),
                      ],
                    ),
                  ),

                  // -----------------------------------------------------------
                  // Privacy
                  // -----------------------------------------------------------
                  const SectionHeader(
                    title: 'Privacy',
                    subtitle: 'What leaves this phone, and what does not',
                    icon: Icons.shield_rounded,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Text(
                      'Recognition and speech run entirely on this phone. Audio '
                      'is never written to storage and never leaves the device '
                      'except as text over the link you paired, and that text '
                      'is encrypted whenever the handshake completes.\n\n'
                      '${caps.isAndroid ? 'Android requires the INTERNET permission before an app may open any socket at all, including a purely local one, so that permission is declared - and every socket this app opens is checked against a local-address allow-list first. Only 127/8, 169.254/16 and the private ranges are reachable; a hostname is refused outright, because resolving one is itself network activity.' : 'This build contains no HTTP client of any kind, and only ever connects to link-local addresses, checked immediately before every connection.'}',
                      style: context.texts.bodySmall
                          ?.copyWith(color: context.colors.onSurfaceVariant),
                    ),
                  ),

                  // -----------------------------------------------------------
                  // Storage and about
                  // -----------------------------------------------------------
                  const SectionHeader(
                    title: 'Storage and about',
                    icon: Icons.storage_rounded,
                  ),
                  GlassPanel(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      children: <Widget>[
                        ListTile(
                          leading: const Icon(Icons.school_rounded),
                          title: const Text('Show the introduction again'),
                          subtitle: const Text(
                            'Repeats the permission and alert-consent steps',
                          ),
                          onTap: controller.replayIntro,
                        ),
                        ListTile(
                          leading: Icon(
                            Icons.delete_outline_rounded,
                            color: context.colors.error,
                          ),
                          title: Text(
                            'Clear transcript',
                            style: TextStyle(color: context.colors.error),
                          ),
                          subtitle: Text('${controller.messages.length} saved'),
                          onTap: _clearTranscript,
                        ),
                        const _Fact('App version', appVersion),
                        const _Fact(
                          'Link protocol',
                          'Version $protocolVersion',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Building blocks
// -----------------------------------------------------------------------------

/// One option in a [_ChoiceCard].
class _Choice<T> {
  const _Choice(this.value, this.label, this.icon);

  final T value;
  final String label;
  final IconData icon;
}

/// A row of large, equally weighted options.
///
/// Used instead of a dropdown for anything with three or fewer options: a
/// dropdown hides the alternatives, and this app is operated under stress where
/// seeing every possibility at once is worth more than compactness.
class _ChoiceCard<T> extends StatelessWidget {
  const _ChoiceCard({
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final T value;
  final List<_Choice<T>> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < options.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: 10),
            Expanded(
              child: _ChoiceTile<T>(
                choice: options[i],
                selected: options[i].value == value,
                onTap: () => onChanged(options[i].value),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ChoiceTile<T> extends StatelessWidget {
  const _ChoiceTile({
    required this.choice,
    required this.selected,
    required this.onTap,
  });

  final _Choice<T> choice;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = context.colors;
    return Semantics(
      button: true,
      selected: selected,
      label: choice.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: AnimatedContainer(
          duration: ItantraTheme.quick,
          curve: ItantraTheme.settle,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primary.withValues(alpha: context.isDark ? 0.22 : 0.1)
                : scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                choice.icon,
                size: 22,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(height: 8),
              Text(
                choice.label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.texts.labelLarge?.copyWith(
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SpeedCard extends StatelessWidget {
  const _SpeedCard({required this.value, required this.onChanged});

  final SpeedProfile value;
  final ValueChanged<SpeedProfile> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GlassPanel(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          children: <Widget>[
            for (final SpeedProfile profile in SpeedProfile.values)
              ListTile(
                onTap: () => onChanged(profile),
                leading: Icon(
                  profile == value
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: profile == value
                      ? context.colors.primary
                      : context.colors.outline,
                ),
                title: Text(profile.label),
                subtitle: Text(
                  profile.isThrottled
                      ? 'A message of about 40 characters takes roughly '
                          '${millis(profile.estimatedMillisFor(210).toDouble())} '
                          'to cross, one way.'
                      : 'No artificial limit. Use this for a real link.',
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LanguageTile extends StatelessWidget {
  const _LanguageTile({
    required this.spec,
    required this.selected,
    required this.report,
    required this.onTap,
  });

  final LanguageSpec spec;
  final bool selected;
  final CoverageReport report;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // The dot is the selection; the pills are the capability. Both are shown
    // side by side so "is it selected" and "will it work" are never confused.
    final bool listens = report.canRecognise;
    final bool speaks = report.canSpeakLocally;

    return ListTile(
      onTap: onTap,
      leading: Icon(
        selected
            ? Icons.radio_button_checked_rounded
            : Icons.radio_button_unchecked_rounded,
        color: selected ? context.colors.primary : context.colors.outline,
      ),
      title: Text('${spec.endonym}  ·  ${spec.englishName}'),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            StatusPill(
              label: listens ? 'Listens' : 'No recognition',
              tone: listens ? PillTone.good : PillTone.neutral,
              icon: Icons.mic_rounded,
              compact: true,
            ),
            StatusPill(
              label: speaks ? 'Speaks' : 'No voice',
              tone: speaks ? PillTone.good : PillTone.neutral,
              icon: Icons.volume_up_rounded,
              compact: true,
            ),
            if (selected && !report.peerCanSpeak)
              const StatusPill(
                label: 'Peer has no voice for this',
                tone: PillTone.caution,
                icon: Icons.warning_amber_rounded,
                compact: true,
              ),
          ],
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value, {this.onTap, this.action});

  final String label;
  final String value;
  final VoidCallback? onTap;
  final String? action;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(label),
      subtitle: Text(value),
      trailing: onTap == null
          ? null
          : TextButton(onPressed: onTap, child: Text(action ?? 'Change')),
    );
  }
}

/// A single explanatory paragraph under a control.
class _Explain extends StatelessWidget {
  const _Explain(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Text(
        text,
        style: context.texts.bodySmall
            ?.copyWith(color: context.colors.onSurfaceVariant),
      ),
    );
  }
}

class _WarnList extends StatelessWidget {
  const _WarnList({required this.problems});

  final List<String> problems;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: GlassPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.warning_amber_rounded,
                    color: ItantraTheme.amber, size: 18),
                const SizedBox(width: 8),
                Text('Packs that could not be read',
                    style: context.texts.titleSmall),
              ],
            ),
            const SizedBox(height: 8),
            for (final String problem in problems)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '• $problem',
                  style: context.texts.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
