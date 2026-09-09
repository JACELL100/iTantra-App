import 'package:flutter/material.dart';

import '../core/models/model_pack.dart';
import '../di/service_locator.dart';
import 'languages.dart';
import 'theme.dart';

/// Language packs, link choice, and the privacy statement.
///
/// Packs are the part users actually need: the app ships without model
/// weights (they are hundreds of megabytes and several carry licences that
/// forbid redistribution), so this screen has to explain clearly what is
/// installed, what is missing, and how much space it costs.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final ServiceLocator _locator = ServiceLocator.instance;
  bool _busy = false;

  Future<void> _refresh() async {
    setState(() => _busy = true);
    await _locator.packs.refresh();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final List<ModelPack> packs = _locator.packs.packs;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Rescan packs',
            onPressed: _busy ? null : _refresh,
          ),
        ],
      ),
      body: ListView(
        children: <Widget>[
          const _SectionHeader('Language'),
          for (final LanguageSpec spec in Languages.all)
            RadioListTile<String>(
              value: spec.tag,
              groupValue: _locator.languageTag,
              onChanged: (String? tag) async {
                if (tag == null) return;
                await _locator.setLanguageTag(tag);
                if (mounted) setState(() {});
              },
              title: Text('${spec.endonym}  ·  ${spec.englishName}'),
              subtitle: Text(_coverageLabel(spec.tag)),
            ),

          const _SectionHeader('Installed packs'),
          if (packs.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'No packs found. Copy pack folders into the app\'s packs '
                'directory, or side-load them from an SD card. '
                'See docs/offline_installation.md.',
              ),
            ),
          for (final ModelPack pack in packs)
            ListTile(
              leading: Icon(pack.role == PackRole.asr
                  ? Icons.mic
                  : Icons.volume_up),
              title: Text('${pack.languageTag} · ${pack.role.name}'),
              subtitle: Text(
                '${pack.describeSize()} · ${pack.licence}'
                '${pack.isRedistributable ? '' : ' · not redistributable'}',
              ),
              trailing: pack.isRedistributable
                  ? null
                  // Flagged in the UI as well as the audit script, because a
                  // non-commercial licence on a bundled voice is the kind of
                  // mistake that is invisible until it is expensive.
                  : const Icon(Icons.gavel, color: ItantraTheme.alertRed),
            ),

          if (_locator.packs.problems.isNotEmpty) ...<Widget>[
            const _SectionHeader('Problems'),
            for (final String problem in _locator.packs.problems)
              ListTile(
                leading: const Icon(Icons.warning_amber_rounded),
                title: Text(problem),
              ),
          ],

          const _SectionHeader('Alerts on this device'),
          ListTile(
            leading: Icon(
              _locator.capabilities.canForceAlertVolume
                  ? Icons.volume_up
                  : Icons.volume_down_alt,
              color: _locator.capabilities.canForceAlertVolume
                  ? null
                  : Theme.of(context).colorScheme.error,
            ),
            title: Text(
              _locator.capabilities.canForceAlertVolume
                  ? 'Alerts play at maximum volume'
                  : 'Alerts play at your current volume',
            ),
            // Said plainly, because someone may be relying on this in a
            // distress situation. On iOS the app cannot raise the volume
            // itself, and implying otherwise would be the worst kind of
            // wrong.
            subtitle: Text(
              _locator.capabilities.canForceAlertVolume
                  ? 'This device lets the app override the volume and the '
                      'silent switch for distress and warning messages.'
                  : 'This device does not let an app change the output '
                      'volume. Alerts will interrupt other audio and will '
                      'be heard with the ringer silenced, but only as loud '
                      'as the volume is set. Turn the volume up if you are '
                      'relying on alerts.',
            ),
          ),
          if (!_locator.capabilities.supportsRfcommClassic)
            const ListTile(
              leading: Icon(Icons.bluetooth_disabled),
              title: Text('Bluetooth Classic unavailable'),
              subtitle: Text(
                'This device restricts Classic serial links, so Bluetooth '
                'pairing uses the slower low-energy bridge. Wi-Fi is '
                'unaffected and is the faster choice here.',
              ),
            ),

          const _SectionHeader('Privacy'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'Recognition and speech run entirely on this phone. Audio is '
              'never written to storage and never leaves the device except '
              'as text over the link you paired. '
              '${_locator.capabilities.isAndroid ? 'The app holds no internet permission at all, so this is enforced by Android and not just promised here.' : 'The app contains no HTTP client and only ever connects to link-local addresses, which is checked before every connection.'}',
            ),
          ),

          const _SectionHeader('Storage'),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Clear transcript'),
            subtitle: const Text('Keeps paired devices'),
            onTap: () async {
              await _locator.repository.clear();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Transcript cleared')),
              );
            },
          ),
        ],
      ),
    );
  }

  /// Says plainly what a language can and cannot do right now. "Listen only"
  /// is a real and common state, because ASR and TTS packs are independent.
  String _coverageLabel(String tag) {
    final bool asr = _locator.packs.packFor(tag, PackRole.asr) != null;
    final bool tts = _locator.packs.packFor(tag, PackRole.tts) != null;
    if (asr && tts) return 'Speak and listen';
    if (asr) return 'Speak only — no voice pack installed';
    if (tts) return 'Listen only — no recognition pack installed';
    return 'No packs installed';
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, top: 20, bottom: 4),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              letterSpacing: 1.2,
              color: ItantraTheme.deepBlue,
            ),
      ),
    );
  }
}
