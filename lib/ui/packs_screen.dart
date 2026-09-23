import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/models/model_pack.dart';
import '../core/util/async.dart';
import 'animation.dart';
import 'app_controller.dart';
import 'format.dart';
import 'languages.dart';
import 'theme.dart';
import 'widgets/status_pill.dart';

/// Language packs: what is installed, what is missing, and why.
///
/// This screen exists because the app ships without model weights. They are
/// hundreds of megabytes and several carry licences that forbid redistribution,
/// so they are installed on the phone separately - which means the app has to
/// be honest and specific about what it can and cannot currently do, rather
/// than offering a language picker that fails on the first press.
class PacksScreen extends StatefulWidget {
  const PacksScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<PacksScreen> createState() => _PacksScreenState();
}

class _PacksScreenState extends State<PacksScreen> {
  bool _busy = false;
  Map<String, bool>? _verifyResult;

  Future<void> _rescan() async {
    setState(() {
      _busy = true;
      _verifyResult = null;
    });
    await widget.controller.refreshPacks();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _verify() async {
    setState(() => _busy = true);
    final Map<String, bool> result =
        await widget.controller.verifyPacks();
    if (!mounted) return;
    setState(() {
      _verifyResult = result;
      _busy = false;
    });
  }

  Future<void> _showLocation() async {
    final Directory root = await widget.controller.packsDirectory();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Where packs go'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Copy each pack into a folder named <language>-<asr|tts> in this '
              'directory, then rescan:',
              style: context.texts.bodyMedium,
            ),
            const SizedBox(height: 12),
            SelectableText(
              root.path,
              style: context.texts.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Each pack needs model.onnx, manifest.json and its vocabulary '
              'file. A pack without a manifest is reported rather than loaded, '
              'so a half-copied pack cannot quietly produce wrong speech.',
              style: context.texts.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ],
        ),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppController controller = widget.controller;
    final List<ModelPack> packs = controller.installedPacks;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Language packs'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Show the pack folder',
            icon: const Icon(Icons.folder_rounded),
            onPressed: _showLocation,
          ),
          IconButton(
            tooltip: 'Check every pack',
            icon: const Icon(Icons.verified_rounded),
            onPressed: _busy ? null : _verify,
          ),
          IconButton(
            tooltip: 'Rescan',
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
      body: ListView(
        children: <Widget>[
          _SummaryCard(controller: controller, verifyResult: _verifyResult),

          const SectionHeader(
            title: 'Coverage',
            subtitle: 'What each language can actually do on this phone',
            icon: Icons.grid_view_rounded,
          ),
          for (final LanguageSpec spec in Languages.all)
            _CoverageRow(spec: spec, controller: controller),

          if (packs.isNotEmpty) ...<Widget>[
            const SectionHeader(
              title: 'Installed',
              subtitle: 'Files on disk, with size and licence',
              icon: Icons.inventory_2_rounded,
            ),
            for (final ModelPack pack in packs)
              _PackTile(
                pack: pack,
                verified: _verifyResult?[pack.id],
                onDelete: () => _confirmDelete(pack),
              ),
          ],

          if (controller.packProblems.isNotEmpty) ...<Widget>[
            const SectionHeader(
              title: 'Problems',
              subtitle: 'These folders were found but could not be loaded',
              icon: Icons.warning_amber_rounded,
            ),
            for (final String problem in controller.packProblems)
              ListTile(
                leading: const Icon(Icons.error_outline_rounded,
                    color: ItantraTheme.alertRed),
                title: Text(problem),
              ),
          ],

          const SectionHeader(
            title: 'Where to get packs',
            subtitle: 'Licences matter; these are the compliant options',
            icon: Icons.gavel_rounded,
          ),
          const _SourceNote(
            name: 'AI4Bharat IndicConformer',
            detail:
                'Nine Indic languages, MIT licensed. Does not cover English, so '
                'English needs its own recognition model.',
          ),
          const _SourceNote(
            name: 'ARTPARK-IISc DhVaani',
            detail:
                'Apache-2.0. Covers all ten languages including Odia, which is '
                'otherwise the hardest to source openly.',
          ),
          const _SourceNote(
            name: 'Avoid facebook/mms-tts-ory for Odia',
            detail:
                'Open weights, but CC-BY-NC-4.0. Non-commercial, so it cannot '
                'ship in a deployable build.',
            warning: true,
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(ModelPack pack) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('Remove the ${pack.languageTag} ${pack.role.name} pack?'),
        content: Text(
          'This deletes ${pack.describeSize()} from this phone. It can be '
          'copied back at any time; nothing else is affected.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final Directory directory = Directory(pack.directory);
    try {
      await directory.delete(recursive: true);
    } on FileSystemException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not remove it: ${error.message}')),
      );
    }
    await _rescan();
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.controller, required this.verifyResult});

  final AppController controller;
  final Map<String, bool>? verifyResult;

  @override
  Widget build(BuildContext context) {
    final int failed = verifyResult?.values
            .where((bool ok) => !ok)
            .length ??
        0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: GlassPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text('Installed on this phone',
                      style: context.texts.titleSmall),
                ),
                Text(
                  bytes(controller.packBytes),
                  style: context.texts.titleSmall
                      ?.copyWith(color: context.colors.primary),
                ),
              ],
            ),
            const SizedBox(height: 12),
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
                ),
                StatusPill(
                  label: '${controller.ttsCount} voice',
                  tone:
                      controller.ttsCount > 0 ? PillTone.good : PillTone.caution,
                  icon: Icons.volume_up_rounded,
                ),
                StatusPill(
                  label: '${controller.readyLanguages.length} both ways',
                  tone: controller.readyLanguages.isNotEmpty
                      ? PillTone.good
                      : PillTone.caution,
                  icon: Icons.swap_horiz_rounded,
                ),
              ],
            ),
            if (verifyResult != null) ...<Widget>[
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Icon(
                    failed == 0
                        ? Icons.verified_rounded
                        : Icons.report_gmailerrorred_rounded,
                    size: 18,
                    color: failed == 0
                        ? ItantraTheme.success
                        : ItantraTheme.alertRed,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      failed == 0
                          ? 'Every pack matches its recorded checksum.'
                          : '$failed pack(s) failed their checksum. Remove and '
                              'copy them again.',
                      style: context.texts.bodySmall,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CoverageRow extends StatelessWidget {
  const _CoverageRow({required this.spec, required this.controller});

  final LanguageSpec spec;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final bool asr = controller
        .installedPacks
        .any((ModelPack pack) =>
            pack.languageTag == spec.tag && pack.role == PackRole.asr);
    final bool tts = controller
        .installedPacks
        .any((ModelPack pack) =>
            pack.languageTag == spec.tag && pack.role == PackRole.tts);

    return ListTile(
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
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            StatusPill(
              label: asr ? 'Recognises' : 'No recognition',
              tone: asr ? PillTone.good : PillTone.neutral,
              icon: Icons.mic_rounded,
              compact: true,
            ),
            StatusPill(
              label: tts ? 'Speaks' : 'No voice',
              tone: tts ? PillTone.good : PillTone.neutral,
              icon: Icons.volume_up_rounded,
              compact: true,
            ),
          ],
        ),
      ),
    );
  }
}

class _PackTile extends StatelessWidget {
  const _PackTile({
    required this.pack,
    required this.verified,
    required this.onDelete,
  });

  final ModelPack pack;
  final bool? verified;
  final Future<void> Function() onDelete;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(13),
          color: context.colors.primary.withValues(alpha: 0.12),
        ),
        child: Icon(
          pack.role == PackRole.asr
              ? Icons.mic_rounded
              : Icons.volume_up_rounded,
          color: context.colors.primary,
        ),
      ),
      title: Text('${pack.languageTag} · ${pack.role.name}'),
      subtitle: Text(
        '${pack.describeSize()} · ${pack.licence}'
        '${pack.isRedistributable ? '' : ' · non-redistributable'}',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (verified case final bool ok)
            Icon(
              ok ? Icons.check_circle_rounded : Icons.cancel_rounded,
              size: 18,
              color: ok ? ItantraTheme.success : ItantraTheme.alertRed,
            ),
          IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: () => unawaited(onDelete()),
          ),
        ],
      ),
    );
  }
}

class _SourceNote extends StatelessWidget {
  const _SourceNote({
    required this.name,
    required this.detail,
    this.warning = false,
  });

  final String name;
  final String detail;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            warning ? Icons.gavel_rounded : Icons.check_circle_outline_rounded,
            size: 18,
            color: warning ? ItantraTheme.alertRed : ItantraTheme.success,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(name, style: context.texts.titleSmall),
                const SizedBox(height: 2),
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
    );
  }
}

/// Shows the pack directory path, resolved from the same provider the manager
/// uses, so the two can never disagree.
Future<String> packDirectoryPath() async {
  final Directory base = await getApplicationSupportDirectory();
  return p.join(base.path, 'packs');
}
