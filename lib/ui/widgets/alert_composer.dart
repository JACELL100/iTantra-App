import 'package:flutter/material.dart';

import '../../core/protocol/message.dart';
import '../app_controller.dart';
import '../theme.dart';

/// A reviewed alert phrase.
///
/// Templates exist for two reasons that both matter in an emergency. The first
/// is speed: the single most urgent message must not require the recogniser to
/// work, or the user to type on a cracked screen in the rain. The second is
/// accuracy: a canned sentence whose pronunciation has been listened to is
/// safer than one recognised from a shout.
class AlertTemplate {
  const AlertTemplate({
    required this.id,
    required this.label,
    required this.text,
    required this.severity,
    required this.icon,
  });

  final String id;
  final String label;
  final String text;
  final AlertSeverity severity;
  final IconData icon;
}

/// The templates are English on purpose.
///
/// They are spoken by the receiving phone in the language of the message, and
/// every one of these is a phrase whose meaning survives a literal reading.
/// Free-form recognition in the sender's own language covers everything else.
const List<AlertTemplate> alertTemplates = <AlertTemplate>[
  AlertTemplate(
    id: 'help',
    label: 'Need help now',
    text: 'Emergency. I need help immediately.',
    severity: AlertSeverity.distress,
    icon: Icons.sos_rounded,
  ),
  AlertTemplate(
    id: 'location',
    label: 'Send my location',
    text: 'Emergency. I am sending my position. Please come to me.',
    severity: AlertSeverity.distress,
    icon: Icons.my_location_rounded,
  ),
  AlertTemplate(
    id: 'evacuate',
    label: 'Evacuate the area',
    text: 'Warning. Leave the area immediately. Do not enter.',
    severity: AlertSeverity.warning,
    icon: Icons.directions_run_rounded,
  ),
  AlertTemplate(
    id: 'medical',
    label: 'Medical help',
    text: 'Emergency. Someone is injured and needs medical help.',
    severity: AlertSeverity.distress,
    icon: Icons.medical_services_rounded,
  ),
  AlertTemplate(
    id: 'allclear',
    label: 'All clear',
    text: 'The situation is under control. It is safe now.',
    severity: AlertSeverity.warning,
    icon: Icons.check_circle_rounded,
  ),
];

/// Composes and sends an alert.
///
/// The confirmation here is not a dialog that asks "are you sure". It is a
/// sheet the user has to choose *in*, which is what makes it safe against a
/// pocket tap without making it slow in a real emergency - one deliberate
/// press, then a template, and it is gone.
Future<void> showAlertComposer(
  BuildContext context,
  AppController controller,
) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext context) => _AlertComposer(controller: controller),
  );
}

class _AlertComposer extends StatefulWidget {
  const _AlertComposer({required this.controller});

  final AppController controller;

  @override
  State<_AlertComposer> createState() => _AlertComposerState();
}

class _AlertComposerState extends State<_AlertComposer> {
  final TextEditingController _custom = TextEditingController();
  bool _sending = false;
  String? _sentLabel;

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  Future<void> _send({
    required String text,
    required AlertSeverity severity,
    required String label,
  }) async {
    setState(() => _sending = true);
    await widget.controller.raiseAlert(text, severity: severity);
    if (!mounted) return;
    setState(() {
      _sending = false;
      _sentLabel = label;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_sentLabel case final String label) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(height: 8),
              Icon(Icons.campaign_rounded,
                  size: 48, color: context.colors.primary),
              const SizedBox(height: 16),
              Text('Alert sent', style: context.texts.titleLarge),
              const SizedBox(height: 8),
              Text(
                '"$label" is on its way. It will be announced at full volume '
                'and repeated, and ordinary messages cannot interrupt it.',
                textAlign: TextAlign.center,
                style: context.texts.bodyMedium
                    ?.copyWith(color: context.colors.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      );
    }

    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.campaign_rounded,
                  color: ItantraTheme.alertRed, size: 26),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Send an alert', style: context.texts.titleLarge),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Alerts take audio focus, play at the loudest level this phone '
            'allows, and repeat. Nothing else the app does can interrupt one.',
            style: context.texts.bodySmall
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
          if (!widget.controller.alertsArmed)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: _Note(
                icon: Icons.volume_off_rounded,
                text: 'Loud alerts are not armed on this phone yet, so an alert '
                    'will interrupt other audio but will not change the volume. '
                    'Arm them in Settings.',
              ),
            ),
          const SizedBox(height: 16),
          for (final AlertTemplate template in alertTemplates)
            _TemplateTile(
              template: template,
              enabled: !_sending,
              onTap: () => _send(
                text: template.text,
                severity: template.severity,
                label: template.label,
              ),
            ),
          const Divider(height: 34),
          Text('Or say what is happening', style: context.texts.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _custom,
            maxLines: 3,
            minLines: 1,
            enabled: !_sending,
            decoration: const InputDecoration(
              hintText: 'Sent as an alert, not as an ordinary message',
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton(
                  onPressed: _sending
                      ? null
                      : () => _send(
                            text: _custom.text,
                            severity: AlertSeverity.warning,
                            label: 'Warning',
                          ),
                  child: const Text('Send as warning'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: ItantraTheme.alertRed,
                  ),
                  onPressed: _sending || _custom.text.trim().isEmpty
                      ? null
                      : () => _send(
                            text: _custom.text,
                            severity: AlertSeverity.distress,
                            label: 'Distress',
                          ),
                  child: const Text('Send as distress'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          const _Note(
            icon: Icons.phonelink_ring_rounded,
            text: 'Android always lets an incoming phone call take precedence '
                'over any app, including this one, and the phone\'s own mute '
                'switch still applies to the media stream. The guarantee this '
                'app can keep is that nothing inside the app can interrupt an '
                'alert.',
          ),
        ],
      ),
    );
  }
}

class _TemplateTile extends StatelessWidget {
  const _TemplateTile({
    required this.template,
    required this.enabled,
    required this.onTap,
  });

  final AlertTemplate template;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool distress = template.severity == AlertSeverity.distress;
    final Color tint =
        distress ? ItantraTheme.alertRed : ItantraTheme.amber;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: tint.withValues(alpha: context.isDark ? 0.14 : 0.07),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(13),
            child: Row(
              children: <Widget>[
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(13),
                    color: tint.withValues(alpha: 0.18),
                  ),
                  child: Icon(template.icon, color: tint, size: 21),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(template.label,
                          style: context.texts.titleSmall),
                      const SizedBox(height: 2),
                      Text(
                        template.text,
                        style: context.texts.bodySmall?.copyWith(
                          color: context.colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.send_rounded,
                  size: 18,
                  color: tint.withValues(alpha: 0.8),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: context.colors.surfaceContainerHigh,
        border: Border.all(color: context.colors.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 18, color: context.colors.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: context.texts.bodySmall)),
        ],
      ),
    );
  }
}
