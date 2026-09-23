import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/cloud/cloud_speech_config.dart';
import '../core/models/engine_sources.dart';
import '../core/models/model_pack.dart';
import '../core/models/pack_installer.dart';
import 'animation.dart';
import 'app_controller.dart';
import 'format.dart';
import 'languages.dart';
import 'layout.dart';
import 'theme.dart';
import 'widgets/status_pill.dart';

/// Opens the models screen.
///
/// A function rather than a route built at each call site, because four screens
/// offer the same destination: the conversation screen when the talk button
/// cannot work, the home screen, settings, and the demonstration sheet.
Future<void> openModels(BuildContext context, AppController controller) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ModelsScreen(controller: controller),
      ),
    );

/// Everything about where speech is recognised and spoken.
///
/// One screen for four genuinely different answers to the same question, and
/// its job is to make the trade-offs legible rather than to hide them: a model
/// on the phone (private, offline, needs a download); the phone's own voice
/// (free, instant, plainer); a cloud endpoint (best accuracy, needs a
/// connection, sends audio out); or nothing, which is what the demonstration
/// mode is, labelled as such.
class ModelsScreen extends StatefulWidget {
  const ModelsScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<ModelsScreen> createState() => _ModelsScreenState();
}

class _ModelsScreenState extends State<ModelsScreen> {
  bool _verifying = false;
  Map<String, bool> _verified = <String, bool>{};

  AppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    // Voice data can be installed outside this app, so the platform is asked
    // again on every visit rather than trusting a startup answer.
    controller.probeDeviceVoice();
  }

  Future<void> _verifyPacks() async {
    setState(() => _verifying = true);
    final Map<String, bool> result = await controller.verifyPacks();
    if (!mounted) return;
    setState(() {
      _verified = result;
      _verifying = false;
    });
    _note(result.values.every((bool ok) => ok)
        ? 'Every pack matches its manifest'
        : 'Some packs did not match their manifest');
  }

  void _note(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final AppController controller = widget.controller;

    return PageScaffold(
      title: 'Models & voices',
      subtitle: 'Where speech is recognised and spoken',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _SetupSummary(controller: controller),
          const SectionHeader(
            title: 'Recognition',
            subtitle: 'Turns your speech into text',
            icon: Icons.mic_rounded,
          ),
          _SourceChooser<RecognitionSource>(
            options: RecognitionSource.values,
            selected: controller.recognitionSource,
            labelOf: (RecognitionSource s) => s.label,
            summaryOf: (RecognitionSource s) => s.summary,
            detailOf: (RecognitionSource s) =>
                _recognitionDetail(s, controller),
            iconOf: (RecognitionSource s) => switch (s) {
              RecognitionSource.packs => Icons.memory_rounded,
              RecognitionSource.cloud => Icons.cloud_outlined,
              RecognitionSource.simulated => Icons.science_outlined,
            },
            onSelected: controller.setRecognitionSource,
          ),
          const SectionHeader(
            title: 'Voice',
            subtitle: 'Turns text back into speech',
            icon: Icons.volume_up_rounded,
          ),
          _SourceChooser<VoiceSource>(
            options: VoiceSource.values,
            selected: controller.voiceSource,
            labelOf: (VoiceSource s) => s.label,
            summaryOf: (VoiceSource s) => s.summary,
            detailOf: (VoiceSource s) => _voiceDetail(s, controller),
            iconOf: (VoiceSource s) => switch (s) {
              VoiceSource.packs => Icons.record_voice_over_rounded,
              VoiceSource.device => Icons.phone_android_rounded,
              VoiceSource.cloud => Icons.cloud_outlined,
              VoiceSource.none => Icons.volume_off_rounded,
            },
            onSelected: controller.setVoiceSource,
          ),
          if (controller.recognitionSource == RecognitionSource.cloud ||
              controller.voiceSource == VoiceSource.cloud) ...<Widget>[
            const SectionHeader(
              title: 'Cloud endpoint',
              subtitle: 'Used by whichever directions are set to cloud',
              icon: Icons.cloud_outlined,
            ),
            _CloudSection(controller: controller),
          ],
          SectionHeader(
            title: 'Installed models',
            subtitle: controller.installedPacks.isEmpty
                ? 'None yet'
                : '${controller.installedPacks.length} · '
                    '${bytes(controller.packBytes)} on disk',
            icon: Icons.dns_rounded,
            trailing: controller.installedPacks.isEmpty
                ? null
                : TextButton.icon(
                    onPressed: _verifying ? null : _verifyPacks,
                    icon: _verifying
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.verified_rounded, size: 17),
                    label: const Text('Verify'),
                  ),
          ),
          _PacksSection(controller: controller, verified: _verified),
          const SectionHeader(
            title: 'Add a model',
            subtitle: 'A pack is model.onnx, a vocabulary and a manifest',
            icon: Icons.download_for_offline_rounded,
          ),
          _AddModelSection(controller: controller, onNote: _note),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  static String _recognitionDetail(
    RecognitionSource source,
    AppController c,
  ) =>
      switch (source) {
        RecognitionSource.packs => c.asrCount == 0
            ? 'No recognition pack installed'
            : '${c.asrCount} pack${c.asrCount == 1 ? '' : 's'} installed',
        RecognitionSource.cloud => !c.cloudConfig.hasKey
            ? 'Needs an API key'
            : !c.cloudConfig.canTranscribe
                ? 'Needs a model name'
                : 'Sends audio to ${c.cloudConfig.host}',
        RecognitionSource.simulated =>
          'Text is a fixed example, not your voice',
      };

  static String _voiceDetail(VoiceSource source, AppController c) =>
      switch (source) {
        VoiceSource.packs => c.ttsCount == 0
            ? 'No voice pack installed'
            : '${c.ttsCount} pack${c.ttsCount == 1 ? '' : 's'} installed',
        VoiceSource.device => !c.deviceVoiceAvailable
            ? 'This phone reports no speech engine'
            : c.deviceVoiceLanguages.isEmpty
                ? 'Checking what this phone has installed'
                : '${c.deviceVoiceLanguages.length} of the app\'s languages '
                    'have voice data',
        VoiceSource.cloud => !c.cloudConfig.canSynthesize
            ? 'Needs a key and a speech model'
            : 'Speaks through ${c.cloudConfig.host}',
        VoiceSource.none => 'Messages are received and shown, silently',
      };
}

/// The one-line answer to "what will happen if I hold the talk button now".
class _SetupSummary extends StatelessWidget {
  const _SetupSummary({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final List<(IconData, String, Color)> facts = <(IconData, String, Color)>[];

    final bool canHear = controller.hasRecognition;
    facts.add((
      canHear ? Icons.hearing_rounded : Icons.hearing_disabled_rounded,
      canHear
          ? 'Speech is recognised with ${controller.recognitionSource.shortLabel.toLowerCase()}'
          : 'Speech cannot be recognised yet',
      canHear ? context.colors.tertiary : ItantraTheme.amber,
    ));

    final bool canSpeak = controller.hasVoice;
    facts.add((
      canSpeak ? Icons.graphic_eq_rounded : Icons.volume_off_rounded,
      canSpeak
          ? 'Replies are spoken with ${controller.voiceSource.label.toLowerCase()}'
          : 'Replies will be silent',
      canSpeak ? context.colors.tertiary : context.colors.onSurfaceVariant,
    ));

    if (controller.recognitionLeavesDevice || controller.voiceLeavesDevice) {
      facts.add((
        Icons.cloud_upload_outlined,
        'Cloud speech is on, so audio or text leaves this phone',
        ItantraTheme.amber,
      ));
    }

    return SectionCard(
      title: 'Right now',
      icon: Icons.tune_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final (IconData icon, String text, Color tint) fact in facts)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(fact.$1, size: 17, color: fact.$3),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      fact.$2,
                      style: context.texts.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A radio group rendered as cards, so each option can carry its trade-off
/// instead of hiding it behind a label.
class _SourceChooser<T> extends StatelessWidget {
  const _SourceChooser({
    required this.options,
    required this.selected,
    required this.labelOf,
    required this.summaryOf,
    required this.detailOf,
    required this.iconOf,
    required this.onSelected,
  });

  final List<T> options;
  final T selected;
  final String Function(T) labelOf;
  final String Function(T) summaryOf;
  final String Function(T) detailOf;
  final IconData Function(T) iconOf;
  final Future<void> Function(T) onSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final T option in options)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _OptionTile(
              icon: iconOf(option),
              label: labelOf(option),
              summary: summaryOf(option),
              detail: detailOf(option),
              selected: option == selected,
              onTap: () => onSelected(option),
            ),
          ),
      ],
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.icon,
    required this.label,
    required this.summary,
    required this.detail,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String summary;
  final String detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = context.colors;
    final Color accent = selected ? colors.primary : colors.outline;

    return Semantics(
      button: true,
      selected: selected,
      label: '$label. $summary',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: AnimatedContainer(
          duration: ItantraTheme.quick,
          curve: ItantraTheme.settle,
          padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
          decoration: BoxDecoration(
            color: selected
                ? colors.primaryContainer.withValues(
                    alpha: context.isDark ? 0.35 : 0.55,
                  )
                : colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected
                  ? colors.primary.withValues(alpha: 0.85)
                  : colors.outlineVariant.withValues(alpha: 0.65),
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent.withValues(alpha: 0.14),
                ),
                child: Icon(icon, size: 19, color: accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(label, style: context.texts.titleSmall),
                        ),
                        AnimatedSwitcher(
                          duration: ItantraTheme.quick,
                          child: selected
                              ? Icon(
                                  Icons.check_circle_rounded,
                                  key: const ValueKey<String>('on'),
                                  size: 20,
                                  color: colors.primary,
                                )
                              : Icon(
                                  Icons.circle_outlined,
                                  key: const ValueKey<String>('off'),
                                  size: 20,
                                  color: colors.outline,
                                ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      summary,
                      style: context.texts.bodySmall
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      detail,
                      style: context.texts.labelSmall?.copyWith(
                        color: selected ? colors.primary : colors.outline,
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

/// The endpoint, key and model names, with one-tap presets.
class _CloudSection extends StatefulWidget {
  const _CloudSection({required this.controller});

  final AppController controller;

  @override
  State<_CloudSection> createState() => _CloudSectionState();
}

class _CloudSectionState extends State<_CloudSection> {
  late final TextEditingController _baseUrl =
      TextEditingController(text: widget.controller.cloudConfig.baseUrl);
  late final TextEditingController _apiKey =
      TextEditingController(text: widget.controller.cloudConfig.apiKey);
  late final TextEditingController _asrModel =
      TextEditingController(text: widget.controller.cloudConfig.asrModel);
  late final TextEditingController _ttsModel =
      TextEditingController(text: widget.controller.cloudConfig.ttsModel);
  late final TextEditingController _ttsVoice =
      TextEditingController(text: widget.controller.cloudConfig.ttsVoice);

  bool _revealed = false;

  @override
  void dispose() {
    _baseUrl.dispose();
    _apiKey.dispose();
    _asrModel.dispose();
    _ttsModel.dispose();
    _ttsVoice.dispose();
    super.dispose();
  }

  void _applyPreset(CloudPreset preset) {
    setState(() {
      _baseUrl.text = preset.baseUrl;
      _asrModel.text = preset.asrModel;
      _ttsModel.text = preset.ttsModel;
      _ttsVoice.text = preset.ttsVoice;
    });
  }

  Future<void> _save() async {
    await widget.controller.setCloudConfig(
      CloudSpeechConfig(
        baseUrl: _baseUrl.text.trim(),
        apiKey: _apiKey.text.trim(),
        asrModel: _asrModel.text.trim(),
        ttsModel: _ttsModel.text.trim(),
        ttsVoice: _ttsVoice.text.trim(),
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Cloud settings saved')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final CloudSpeechConfig current = widget.controller.cloudConfig;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final CloudPreset preset in CloudPreset.all)
              ActionChip(
                avatar: Icon(
                  preset.freeTier
                      ? Icons.savings_outlined
                      : Icons.workspace_premium_outlined,
                  size: 17,
                ),
                label: Text(preset.name),
                onPressed: () => _applyPreset(preset),
              ),
          ],
        ),
        if (current.hasBaseUrl)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: StatusPill(
              label: current.canTranscribe
                  ? 'Ready · ${current.host}'
                  : 'Incomplete · ${current.host}',
              tone: current.canTranscribe ? PillTone.good : PillTone.caution,
              icon: Icons.cloud_done_outlined,
            ),
          ),
        const SizedBox(height: 14),
        TextField(
          controller: _baseUrl,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Base URL',
            hintText: 'https://api.groq.com/openai/v1',
            helperText: 'Anything that speaks the OpenAI audio API',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _apiKey,
          obscureText: !_revealed,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'API key',
            helperText:
                'Stored in this app\'s private storage on this phone. It is not '
                'encrypted, so treat it as you would any other local file.',
            suffixIcon: IconButton(
              tooltip: _revealed ? 'Hide' : 'Show',
              icon: Icon(
                _revealed
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
              ),
              onPressed: () => setState(() => _revealed = !_revealed),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _asrModel,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Transcription model',
            hintText: 'whisper-large-v3-turbo',
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _ttsModel,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Speech model',
                  hintText: 'gpt-4o-mini-tts',
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _ttsVoice,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Voice',
                  hintText: 'alloy',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: _save,
          icon: const Icon(Icons.save_outlined),
          label: const Text('Save cloud settings'),
        ),
        const SizedBox(height: 10),
        Text(
          'Only the directions you set to Cloud use this. With both set to '
          'on-device sources, no key is needed and nothing leaves the phone.',
          style: context.texts.bodySmall
              ?.copyWith(color: context.colors.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _PacksSection extends StatelessWidget {
  const _PacksSection({required this.controller, required this.verified});

  final AppController controller;
  final Map<String, bool> verified;

  @override
  Widget build(BuildContext context) {
    final List<ModelPack> packs = controller.installedPacks;
    final List<String> problems = controller.packProblems;

    if (packs.isEmpty && problems.isEmpty) {
      return SectionCard(
        tone: context.colors.primary,
        child: Text(
          'No models on this phone yet. You can add one from a URL, import a '
          'file you already have, or use the device voice and a cloud endpoint '
          'instead - both of which work without any download.',
          style: context.texts.bodyMedium,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final ModelPack pack in packs)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _PackCard(
              pack: pack,
              verified: verified[pack.id],
              onDelete: () => _confirmDelete(context, pack),
            ),
          ),
        for (final String problem in problems)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SectionCard(
              tone: context.colors.error,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(Icons.report_gmailerrorred_rounded,
                      size: 18, color: context.colors.error),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(problem, style: context.texts.bodySmall),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _confirmDelete(BuildContext context, ModelPack pack) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Remove this model?'),
        content: Text(
          '${Languages.englishNameFor(pack.languageTag)} '
          '${pack.role == PackRole.asr ? 'recognition' : 'voice'} '
          '(${pack.describeSize()}) will be deleted from this phone. Messages '
          'already received are not affected.',
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
    if (confirmed == true) await controller.removePack(pack);
  }
}

class _PackCard extends StatelessWidget {
  const _PackCard({
    required this.pack,
    required this.verified,
    required this.onDelete,
  });

  final ModelPack pack;
  final bool? verified;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final bool isAsr = pack.role == PackRole.asr;

    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                isAsr ? Icons.mic_rounded : Icons.volume_up_rounded,
                size: 18,
                color: context.colors.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${Languages.englishNameFor(pack.languageTag)} · '
                  '${isAsr ? 'Recognition' : 'Voice'}',
                  style: context.texts.titleSmall,
                ),
              ),
              IconButton(
                tooltip: 'Remove',
                icon: const Icon(Icons.delete_outline_rounded, size: 20),
                onPressed: onDelete,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: <Widget>[
              StatusPill(
                label: pack.describeSize(),
                tone: PillTone.neutral,
                icon: Icons.sd_storage_rounded,
              ),
              StatusPill(
                label: pack.origin.label,
                tone: PillTone.neutral,
                icon: Icons.info_outline_rounded,
              ),
              if (verified != null)              StatusPill(
                label: verified! ? 'Verified' : 'Digest mismatch',
                  tone: verified! ? PillTone.good : PillTone.alert,
                  icon: verified!
                      ? Icons.verified_rounded
                      : Icons.gpp_bad_rounded,
                ),
            ],
          ),
          const SizedBox(height: 10),
          DetailRow(label: 'Language', value: pack.languageTag),
          DetailRow(label: 'Licence', value: pack.licence),
          DetailRow(
            label: 'Tensor input',
            value: pack.tensorNames.input,
            monospace: true,
          ),
          if (pack.sampleRateHz != null)
            DetailRow(label: 'Sample rate', value: '${pack.sampleRateHz} Hz'),
          if (pack.sourceUrl.isNotEmpty)
            DetailRow(label: 'Source', value: pack.sourceUrl),
          if (pack.notes != null && pack.notes!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                pack.notes!,
                style: context.texts.bodySmall
                    ?.copyWith(color: context.colors.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}

/// Adds a model, by URL or from a file already on the phone.
class _AddModelSection extends StatelessWidget {
  const _AddModelSection({required this.controller, required this.onNote});

  final AppController controller;
  final void Function(String) onNote;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        FilledButton.icon(
          onPressed: () => _fetchSheet(context),
          icon: const Icon(Icons.link_rounded),
          label: const Text('Download from a URL'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () => _importSheet(context),
          icon: const Icon(Icons.folder_open_rounded),
          label: const Text('Import files from this phone'),
        ),
        const SizedBox(height: 12),
        Text(
          'The app reads the graph when it installs, records the tensor names '
          'it finds, and tells you if anything does not match the contract. A '
          'model that cannot work is refused at install time rather than '
          'failing on your first sentence.',
          style: context.texts.bodySmall
              ?.copyWith(color: context.colors.onSurfaceVariant),
        ),
      ],
    );
  }

  Future<void> _fetchSheet(BuildContext context) async {
    final _InstallRequest? request = await showModalBottomSheet<_InstallRequest>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext context) => const _FetchSheet(),
    );
    if (request == null || !context.mounted) return;

    final Uri? modelUrl = Uri.tryParse(request.modelUrl);
    if (modelUrl == null || !modelUrl.hasScheme) {
      onNote('That is not a URL');
      return;
    }

    final Map<String, Uri> auxiliary = <String, Uri>{};
    for (final MapEntry<String, String> entry in request.auxiliary.entries) {
      final Uri? uri = Uri.tryParse(entry.value);
      if (uri != null && uri.hasScheme) auxiliary[entry.key] = uri;
    }

    await _runInstall(context, request, () => controller.installPack(
          modelUrl: modelUrl,
          languageTag: request.languageTag,
          role: request.role,
          auxiliary: auxiliary,
          licence: request.licence,
          sampleRateHz: request.sampleRateHz,
        ));
  }

  Future<void> _importSheet(BuildContext context) async {
    final FilePickerResult? picked = await FilePicker.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withReadStream: false,
    );
    final String? path = picked?.files.single.path;
    if (path == null || !context.mounted) return;

    final _InstallRequest? request = await showModalBottomSheet<_InstallRequest>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext context) => _FetchSheet(modelPath: path),
    );
    if (request == null || !context.mounted) return;

    await _runInstall(context, request, () => controller.importPack(
          modelPath: path,
          languageTag: request.languageTag,
          role: request.role,
          vocabularyPath: request.vocabularyPath,
          licence: request.licence,
          sampleRateHz: request.sampleRateHz,
        ));
  }

  /// Runs an install behind a progress dialog.
  ///
  /// The sheet is deliberately not dismissible: a download that is cancelled
  /// half way leaves nothing on disk (the installer cleans up after itself),
  /// but a user who backs out mid-transfer has no idea whether it worked.
  Future<void> _runInstall(
    BuildContext context,
    _InstallRequest request,
    Future<PackInstallResult> Function() run,
  ) async {
    final ValueNotifier<PackInstallProgress> progress =
        ValueNotifier<PackInstallProgress>(
      const PackInstallProgress(phase: InstallPhase.preparing),
    );

    _showProgressDialog(context, progress);

    try {
      final PackInstallResult result =
          await run().whenComplete(() => progress.value = const PackInstallProgress(
                phase: InstallPhase.done,
              ));
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop();

      final String label = Languages.englishNameFor(request.languageTag);
      onNote(result.hasWarnings
          ? 'Installed $label, with ${result.warnings.length} note'
              '${result.warnings.length == 1 ? '' : 's'}'
          : 'Installed $label');
      if (result.hasWarnings && context.mounted) {
        await _showWarnings(context, result.warnings);
      }
    } on PackInstallException catch (error) {
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
      onNote(error.message);
    } on Object catch (error) {
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
      onNote('Install failed: $error');
    } finally {
      progress.dispose();
    }
  }

  /// Shows the progress dialog without awaiting it, since the await belongs to
  /// the install itself.
  void _showProgressDialog(
    BuildContext context,
    ValueNotifier<PackInstallProgress> progress,
  ) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) =>
          _InstallProgressDialog(progress: progress),
    );
  }

  static Future<void> _showWarnings(
    BuildContext context,
    List<String> warnings,
  ) =>
      showDialog<void>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: const Text('Installed, with notes'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (final String warning in warnings)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text('• $warning'),
                ),
            ],
          ),
          actions: <Widget>[
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Understood'),
            ),
          ],
        ),
      );
}

/// What the install sheet collects.
class _InstallRequest {
  const _InstallRequest({
    required this.languageTag,
    required this.role,
    this.modelUrl = '',
    this.modelPath,
    this.vocabularyPath,
    this.auxiliary = const <String, String>{},
    this.licence,
    this.sampleRateHz,
  });

  final String languageTag;
  final PackRole role;
  final String modelUrl;

  /// Set for an import; null for a download.
  final String? modelPath;
  final String? vocabularyPath;
  final Map<String, String> auxiliary;
  final String? licence;
  final int? sampleRateHz;
}

class _FetchSheet extends StatefulWidget {
  const _FetchSheet({this.modelPath});

  /// Non-null when importing a file that has already been chosen.
  final String? modelPath;

  @override
  State<_FetchSheet> createState() => _FetchSheetState();
}

class _FetchSheetState extends State<_FetchSheet> {
  late final TextEditingController _url = TextEditingController();
  late final TextEditingController _vocabulary = TextEditingController();
  late final TextEditingController _licence =
      TextEditingController(text: 'unknown — check the model card');
  late final TextEditingController _sampleRate =
      TextEditingController(text: '22050');

  String _language = 'hi-IN';
  PackRole _role = PackRole.asr;

  bool get _isImport => widget.modelPath != null;

  @override
  void dispose() {
    _url.dispose();
    _vocabulary.dispose();
    _licence.dispose();
    _sampleRate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 24,
        top: 4,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              _isImport ? 'Import a model' : 'Download a model',
              style: context.texts.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              _isImport
                  ? widget.modelPath!
                  : 'The URL of a model.onnx, with any vocabulary file it needs.',
              style: context.texts.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            if (!_isImport) ...<Widget>[
              TextField(
                controller: _url,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Model URL',
                  hintText: 'https://…/model.onnx',
                ),
              ),
              const SizedBox(height: 12),
            ],
            Row(
              children: <Widget>[
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _language,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Language'),
                    items: <DropdownMenuItem<String>>[
                      for (final LanguageSpec spec in Languages.all)
                        DropdownMenuItem<String>(
                          value: spec.tag,
                          child: Text(
                            '${spec.endonym} · ${spec.tag}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (String? value) {
                      if (value != null) setState(() => _language = value);
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: DropdownButtonFormField<PackRole>(
                    value: _role,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Purpose'),
                    items: const <DropdownMenuItem<PackRole>>[
                      DropdownMenuItem<PackRole>(
                        value: PackRole.asr,
                        child: Text('Recognition'),
                      ),
                      DropdownMenuItem<PackRole>(
                        value: PackRole.tts,
                        child: Text('Voice'),
                      ),
                    ],
                    onChanged: (PackRole? value) {
                      if (value != null) setState(() => _role = value);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_isImport)
              TextField(
                controller: _vocabulary,
                decoration: InputDecoration(
                  labelText: 'Vocabulary file (optional)',
                  hintText: _role == PackRole.asr
                      ? 'tokens.txt or vocab.json'
                      : 'graphemes.tsv or vocab.json',
                  helperText: 'Leave empty if it sits beside the model',
                ),
              )
            else
              TextField(
                controller: _vocabulary,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'Vocabulary URL (optional)',
                  hintText: 'https://…/vocab.json',
                  helperText: _role == PackRole.asr
                      ? 'Token table for recognition'
                      : 'Grapheme table for the voice',
                ),
              ),
            if (_isImport)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: _PickFileField(
                  controller: _vocabulary,
                  label: 'Choose a vocabulary file',
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _licence,
                    decoration: const InputDecoration(labelText: 'Licence'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _sampleRate,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Hz',
                      helperText: 'Voice only',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _submit,
              icon: const Icon(Icons.check_rounded),
              label: Text(_isImport ? 'Import' : 'Download and install'),
            ),
            const SizedBox(height: 8),
            Text(
              _role == PackRole.asr
                  ? 'Recognition packs need a tokens.txt, or a vocab.json the '
                      'app can convert.'
                  : 'Voice packs need a graphemes.tsv, or a vocab.json the app '
                      'can convert.',
              style: context.texts.bodySmall
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  void _submit() {
    final int? rate = int.tryParse(_sampleRate.text.trim());
    Navigator.of(context).pop(
      _InstallRequest(
        languageTag: _language,
        role: _role,
        modelUrl: _url.text.trim(),
        modelPath: widget.modelPath,
        vocabularyPath: _isImport && _vocabulary.text.trim().isNotEmpty
            ? _vocabulary.text.trim()
            : null,
        // The auxiliary file is always written into the pack as vocab.json,
        // which is the name the installer looks for when it has to derive a
        // vocabulary from a JSON token table.
        auxiliary: !_isImport && _vocabulary.text.trim().isNotEmpty
            ? <String, String>{'vocab.json': _vocabulary.text.trim()}
            : const <String, String>{},
        licence: _licence.text.trim(),
        sampleRateHz: _role == PackRole.tts ? rate : null,
      ),
    );
  }
}

/// A read-only field with a button that opens the file picker.
class _PickFileField extends StatelessWidget {
  const _PickFileField({required this.controller, required this.label});

  final TextEditingController controller;
  final String label;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      readOnly: true,
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: IconButton(
          tooltip: 'Browse',
          icon: const Icon(Icons.folder_open_rounded),
          onPressed: () async {
            final FilePickerResult? picked = await FilePicker.pickFiles(
              type: FileType.any,
              allowMultiple: false,
            );
            final String? path = picked?.files.single.path;
            if (path != null) controller.text = path;
          },
        ),
      ),
    );
  }
}

class _InstallProgressDialog extends StatelessWidget {
  const _InstallProgressDialog({required this.progress});

  final ValueNotifier<PackInstallProgress> progress;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PackInstallProgress>(
      valueListenable: progress,
      builder: (BuildContext context, PackInstallProgress value, _) {
        final double? fraction = value.fraction;
        return AlertDialog(
          title: Text(value.phase.label),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (fraction == null)
                const LinearProgressIndicator()
              else
                LinearProgressIndicator(value: fraction),
              const SizedBox(height: 12),
              Text(
                value.phase == InstallPhase.downloading
                    ? '${bytes(value.receivedBytes)} of '
                        '${value.totalBytes > 0 ? bytes(value.totalBytes) : '?'}'
                    : value.detail ?? 'Working…',
                style: context.texts.bodySmall
                    ?.copyWith(color: context.colors.onSurfaceVariant),
              ),
            ],
          ),
        );
      },
    );
  }
}
