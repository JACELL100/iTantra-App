import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/security/pairing_verifier.dart';
import '../../core/session/session_launcher.dart';
import '../../core/transport/offline_guard.dart';
import '../../core/transport/tcp_transport.dart';
import '../../core/transport/transport_adapter.dart';
import '../animation.dart';
import '../app_controller.dart';
import '../theme.dart';

/// Sets up a link, in whichever order the user thinks about it.
///
/// Three steps, and the first two are the same question asked twice: what
/// medium, and which end of it am I. That is the whole mental model of a
/// walkie-talkie pair, and anything more elaborate would just be the app
/// explaining its own plumbing.
Future<void> showConnectSheet(
  BuildContext context,
  AppController controller,
) async {
  final ConnectionSpec? spec = await showModalBottomSheet<ConnectionSpec>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext context) => _ConnectSheet(controller: controller),
  );
  if (spec == null) return;
  await controller.connect(spec);
}

class _ConnectSheet extends StatefulWidget {
  const _ConnectSheet({required this.controller});

  final AppController controller;

  @override
  State<_ConnectSheet> createState() => _ConnectSheetState();
}

class _ConnectSheetState extends State<_ConnectSheet> {
  TransportKind? _kind;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: AnimatedSize(
        duration: ItantraTheme.medium,
        curve: ItantraTheme.emphasizeCurve,
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: _kind == null ? _chooser(context) : _roleChooser(context),
        ),
      ),
    );
  }

  Widget _chooser(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text('How should the phones talk?', style: context.texts.titleLarge),
        const SizedBox(height: 6),
        Text(
          'Both phones must choose the same one. No internet connection is used '
          'or needed by any of these.',
          style: context.texts.bodySmall
              ?.copyWith(color: context.colors.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        for (final TransportKind kind in <TransportKind>[
          TransportKind.wifiTcp,
          TransportKind.bluetoothRfcomm,
          TransportKind.bleBridge,
        ])
          _OptionTile(
            icon: _icon(kind),
            title: _label(kind),
            subtitle: _hint(kind, widget.controller),
            enabled: _available(kind),
            onTap: () => setState(() => _kind = kind),
          ),
        const Divider(height: 32),
        Text(
          'Bluetooth Classic is the most reliable on cheap phones: it needs no '
          'shared network and reaches around ten metres. Wi-Fi is faster. The '
          'radio bridge is slowest and is for a hardware relay.',
          style: context.texts.bodySmall
              ?.copyWith(color: context.colors.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _roleChooser(BuildContext context) {
    final TransportKind kind = _kind!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            IconButton(
              tooltip: 'Back',
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: () => setState(() => _kind = null),
            ),
            Expanded(
              child: Text(_label(kind), style: context.texts.titleLarge),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'One phone offers the link and the other joins it. In a mixed pair, '
          'an Android phone must be the one offering: an iPhone cannot create '
          'a local network.',
          style: context.texts.bodySmall
              ?.copyWith(color: context.colors.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        _OptionTile(
          icon: Icons.wifi_tethering_rounded,
          title: 'This phone offers the link',
          subtitle: kind == TransportKind.wifiTcp
              ? 'Listens on port ${TcpTransport.defaultPort}. Share the '
                  'address shown next with the other phone.'
              : 'Waits for the other phone to connect to it.',
          enabled: true,
          onTap: () => Navigator.of(context).pop(
            ConnectionSpec(
              kind: kind,
              isHost: true,
              speed: widget.controller.speedProfile,
            ),
          ),
        ),
        _OptionTile(
          icon: Icons.login_rounded,
          title: 'This phone joins the link',
          subtitle: kind == TransportKind.wifiTcp
              ? 'You will need the other phone\'s local address.'
              : 'You will need the other phone\'s Bluetooth address.',
          enabled: true,
          onTap: () => _askAddress(kind),
        ),
      ],
    );
  }

  Future<void> _askAddress(TransportKind kind) async {
    final TextEditingController field = TextEditingController();
    String? error;

    final String? address = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setDialogState) {
          void submit() {
            final String value = field.text.trim();
            if (value.isEmpty) {
              setDialogState(() => error = 'Enter the address shown on the '
                  'other phone.');
              return;
            }
            if (kind == TransportKind.wifiTcp &&
                !OfflineGuard.isPermittedString(value)) {
              // Caught here rather than at connect time so the user gets a
              // clear explanation instead of a failed connection. It is also
              // the point where a mistyped public address is refused.
              setDialogState(() => error =
                  'That is not a local address. Only 192.168.x.x, 10.x.x.x or '
                  'a phone-to-phone address will work.');
              return;
            }
            Navigator.of(context).pop(value);
          }

          return AlertDialog(
            title: Text(kind == TransportKind.wifiTcp
                ? 'Other phone\'s address'
                : 'Other phone\'s Bluetooth address'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  controller: field,
                  autofocus: true,
                  keyboardType: kind == TransportKind.wifiTcp
                      ? TextInputType.number
                      : TextInputType.text,
                  inputFormatters: kind == TransportKind.wifiTcp
                      ? <TextInputFormatter>[
                          FilteringTextInputFormatter.allow(
                            RegExp(r'[0-9.]'),
                          ),
                        ]
                      : null,
                  onSubmitted: (_) => submit(),
                  decoration: InputDecoration(
                    hintText: kind == TransportKind.wifiTcp
                        ? '192.168.49.1'
                        : 'AA:BB:CC:DD:EE:FF',
                    errorText: error,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  kind == TransportKind.wifiTcp
                      ? 'Shown on the offering phone once it is waiting.'
                      : 'Found in the phone\'s Bluetooth settings.',
                  style: context.texts.bodySmall
                      ?.copyWith(color: context.colors.onSurfaceVariant),
                ),
              ],
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(onPressed: submit, child: const Text('Connect')),
            ],
          );
        },
      ),
    );

    if (address == null || !mounted) return;
    Navigator.of(context).pop(
      ConnectionSpec(
        kind: kind,
        isHost: false,
        address: address,
        speed: widget.controller.speedProfile,
      ),
    );
  }

  bool _available(TransportKind kind) => switch (kind) {
        TransportKind.wifiTcp => widget.controller.capabilities.supportsWifiTcp,
        TransportKind.bluetoothRfcomm =>
          widget.controller.capabilities.supportsRfcommClassic,
        TransportKind.bleBridge =>
          widget.controller.capabilities.supportsBleBridge,
        TransportKind.loopback => true,
      };

  static IconData _icon(TransportKind kind) => switch (kind) {
        TransportKind.wifiTcp => Icons.wifi_rounded,
        TransportKind.bluetoothRfcomm => Icons.bluetooth_rounded,
        TransportKind.bleBridge => Icons.memory_rounded,
        TransportKind.loopback => Icons.loop_rounded,
      };

  static String _label(TransportKind kind) => switch (kind) {
        TransportKind.wifiTcp => 'Wi-Fi',
        TransportKind.bluetoothRfcomm => 'Bluetooth',
        TransportKind.bleBridge => 'Radio bridge (BLE)',
        TransportKind.loopback => 'This phone only',
      };

  static String _hint(TransportKind kind, AppController controller) =>
      switch (kind) {
        TransportKind.wifiTcp =>
          'Both phones on one Wi-Fi network, a hotspot, or Wi-Fi Direct. '
              'Fastest of the three.',
        TransportKind.bluetoothRfcomm =>
          'No network needed. Around 100 kbit/s, which is ample for text.',
        TransportKind.bleBridge =>
          'For an external radio relay. Slowest, but the longest reach.',
        TransportKind.loopback => 'Plays your own messages back to you.',
      };
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: Material(
          color: context.colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            onTap: enabled ? onTap : null,
            borderRadius: BorderRadius.circular(18),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      color: context.colors.primary.withValues(alpha: 0.12),
                    ),
                    child: Icon(icon, color: context.colors.primary),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(title, style: context.texts.titleSmall),
                        const SizedBox(height: 3),
                        Text(
                          enabled
                              ? subtitle
                              : 'Not available on this device',
                          style: context.texts.bodySmall?.copyWith(
                            color: context.colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (enabled)
                    Icon(
                      Icons.chevron_right_rounded,
                      color: context.colors.outline,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows the six-digit code and waits for a human decision.
///
/// This is the whole trust model, and it is deliberately not skippable. Two
/// phones can agree on a key over an untrusted link, but nothing stops a third
/// device from agreeing separately with each side; the two codes would then
/// differ, which is the only signal that reveals it. There is no certificate
/// authority offline, so a person reading digits aloud is the anchor.
Future<bool> showPairingSheet(
  BuildContext context, {
  required String shortAuthString,
  required String linkLabel,
  String? peerLabel,
}) async {
  final bool? verified = await showModalBottomSheet<bool>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    showDragHandle: false,
    isScrollControlled: true,
    builder: (BuildContext context) => _PairingSheet(
      shortAuthString: shortAuthString,
      linkLabel: linkLabel,
      peerLabel: peerLabel,
    ),
  );
  if (verified == true) return true;
  return false;
}

class _PairingSheet extends StatefulWidget {
  const _PairingSheet({
    required this.shortAuthString,
    required this.linkLabel,
    this.peerLabel,
  });

  final String shortAuthString;
  final String linkLabel;
  final String? peerLabel;

  @override
  State<_PairingSheet> createState() => _PairingSheetState();
}

class _PairingSheetState extends State<_PairingSheet> {
  bool _readAloud = false;

  @override
  Widget build(BuildContext context) {
    final String formatted =
        PairingVerifier.formatted(widget.shortAuthString);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            FadeSlideIn(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Icon(Icons.verified_user_rounded,
                      color: context.colors.primary, size: 26),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text('Check these six digits',
                        style: context.texts.titleLarge),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            FadeSlideIn(
              index: 1,
              child: Text(
                widget.peerLabel == null
                    ? 'Both phones must show the same code. Read it out loud '
                        'on a call or compare the screens side by side.'
                    : 'Both this phone and ${widget.peerLabel} must show the '
                        'same code. Read it out loud on a call, or compare the '
                        'screens side by side.',
                textAlign: TextAlign.center,
                style: context.texts.bodyMedium
                    ?.copyWith(color: context.colors.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 22),
            FadeSlideIn(
              index: 2,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 22),
                decoration: BoxDecoration(
                  color: context.colors.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: context.colors.primary.withValues(alpha: 0.3),
                  ),
                ),
                child: Column(
                  children: <Widget>[
                    FittedBox(
                      child: Text(
                        formatted,
                        style: TextStyle(
                          fontSize: 46,
                          letterSpacing: 8,
                          fontWeight: FontWeight.w800,
                          fontFeatures: const <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                          color: context.colors.primary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      widget.linkLabel,
                      style: context.texts.bodySmall
                          ?.copyWith(color: context.colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            FadeSlideIn(
              index: 3,
              child: CheckboxListTile(
                value: _readAloud,
                onChanged: (bool? value) =>
                    setState(() => _readAloud = value ?? false),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(
                  'The other phone shows the same six digits',
                  style: context.texts.bodyMedium,
                ),
              ),
            ),
            const SizedBox(height: 8),
            FadeSlideIn(
              index: 4,
              child: Container(
                padding: const EdgeInsets.all(13),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: ItantraTheme.alertRed
                      .withValues(alpha: context.isDark ? 0.14 : 0.09),
                  border: Border.all(
                    color: ItantraTheme.alertRed.withValues(alpha: 0.38),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Icon(Icons.shield_outlined,
                        size: 18, color: ItantraTheme.alertRed),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'If the digits are different, someone else is on the '
                        'network. Do not continue — cancel, and try again '
                        'somewhere less public.',
                        style: context.texts.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            FadeSlideIn(
              index: 5,
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('They are different'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      // Disabled until the box is ticked, so confirming is a
                      // positive act rather than a reflex tap on a button that
                      // merely appeared.
                      onPressed: _readAloud
                          ? () => Navigator.of(context).pop(true)
                          : null,
                      child: const Text('They match'),
                    ),
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
