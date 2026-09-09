import 'package:flutter/material.dart';

import '../core/session/session_controller.dart';
import '../core/storage/entities.dart';
import '../di/service_locator.dart';
import 'conversation_controller.dart';
import 'diagnostics_screen.dart';
import 'languages.dart';
import 'settings_screen.dart';
import 'theme.dart';
import 'widgets/message_bubble.dart';
import 'widgets/ptt_button.dart';

/// The one screen the app is really about.
///
/// Layout priority is deliberate: the talk button first, the transcript
/// second, everything else behind a menu. In a distress situation the user
/// needs one enormous target and no decisions.
class ConversationScreen extends StatefulWidget {
  const ConversationScreen({super.key});

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  late final ConversationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ConversationController(ServiceLocator.instance);
    _controller.load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('iTantra'),
            actions: <Widget>[
              _LanguageButton(controller: _controller),
              IconButton(
                icon: const Icon(Icons.speed),
                tooltip: 'Diagnostics',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const DiagnosticsScreen(),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.settings),
                tooltip: 'Settings',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const SettingsScreen(),
                  ),
                ),
              ),
            ],
          ),
          body: Column(
            children: <Widget>[
              if (_controller.banner != null)
                _Banner(controller: _controller),
              Expanded(
                child: _controller.messages.isEmpty
                    ? const _EmptyState()
                    : ListView.builder(
                        // Newest at the bottom visually, newest first in the
                        // list: reverse avoids a scroll-to-end animation on
                        // every message, which on a low-end phone is jank
                        // exactly when the user is reading.
                        reverse: true,
                        padding: const EdgeInsets.only(top: 8, bottom: 8),
                        itemCount: _controller.messages.length,
                        itemBuilder: (BuildContext context, int index) {
                          final StoredMessage message =
                              _controller.messages[index];
                          return MessageBubble(message: message);
                        },
                      ),
              ),
              _ControlBar(controller: _controller),
            ],
          ),
        );
      },
    );
  }
}

class _ControlBar extends StatelessWidget {
  const _ControlBar({required this.controller});

  final ConversationController controller;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 20, top: 8),
        child: Column(
          children: <Widget>[
            SegmentedButton<SessionMode>(
              segments: const <ButtonSegment<SessionMode>>[
                ButtonSegment<SessionMode>(
                  value: SessionMode.pushToTalk,
                  label: Text('Walkie-talkie'),
                  icon: Icon(Icons.radio_button_checked),
                ),
                ButtonSegment<SessionMode>(
                  value: SessionMode.handsFree,
                  label: Text('Hands-free'),
                  icon: Icon(Icons.hearing),
                ),
              ],
              selected: <SessionMode>{controller.mode},
              onSelectionChanged: controller.connected
                  ? (Set<SessionMode> selection) =>
                      controller.setMode(selection.first)
                  : null,
            ),
            const SizedBox(height: 16),
            PttButton(
              isTalking: controller.talking,
              level: controller.level,
              enabled: controller.canTalk,
              blockedReason: controller.connected
                  ? null
                  : controller.connecting
                      ? 'Connecting'
                      : 'Not connected',
              onPressStart: controller.pressTalk,
              onPressEnd: controller.releaseTalk,
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: controller.connected
                      ? () => _promptText(context, controller)
                      : null,
                  icon: const Icon(Icons.keyboard),
                  label: const Text('Type'),
                ),
                const SizedBox(width: 12),
                // Distress is a single tap with no confirmation dialog. A
                // confirmation would be safer against accidents and much
                // worse in an actual emergency; the transcript records who
                // sent what, which is the better answer to misuse.
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: ItantraTheme.alertRed,
                  ),
                  onPressed: controller.connected
                      ? () => _sendAlert(context, controller)
                      : null,
                  icon: const Icon(Icons.campaign),
                  label: const Text('Distress'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _sendAlert(
    BuildContext context,
    ConversationController controller,
  ) async {
    await controller.raiseAlert('Distress. Send help immediately.');
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Distress alert sent')),
    );
  }

  Future<void> _promptText(
    BuildContext context,
    ConversationController controller,
  ) async {
    final TextEditingController field = TextEditingController();
    final String? text = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Send text'),
        content: TextField(
          controller: field,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'The other phone will speak this aloud',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(field.text),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (text != null) await controller.sendTyped(text);
  }
}

class _LanguageButton extends StatelessWidget {
  const _LanguageButton({required this.controller});

  final ConversationController controller;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Language',
      initialValue: controller.languageTag,
      onSelected: controller.setLanguage,
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        for (final LanguageSpec spec in Languages.all)
          PopupMenuItem<String>(
            value: spec.tag,
            // Endonym first: someone who reads only Malayalam should not
            // have to recognise the word "Malayalam" in Latin script.
            child: Text('${spec.endonym}  ${spec.englishName}'),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Center(
          child: Text(
            controller.languageTag.split('-').first.toUpperCase(),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.controller});

  final ConversationController controller;

  @override
  Widget build(BuildContext context) {
    final bool missing = controller.bannerIsMissingModel;
    return Material(
      color: missing
          ? ItantraTheme.saffron.withValues(alpha: 0.15)
          : ItantraTheme.alertRed.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: <Widget>[
            Icon(missing ? Icons.download_for_offline : Icons.error_outline),
            const SizedBox(width: 10),
            Expanded(child: Text(controller.banner!)),
            if (missing)
              TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const SettingsScreen(),
                  ),
                ),
                child: const Text('Packs'),
              ),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: controller.dismissBanner,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(Icons.record_voice_over, size: 56),
            const SizedBox(height: 12),
            Text(
              'Hold the button and speak. '
              'Everything stays on this phone.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ],
        ),
      ),
    );
  }
}
