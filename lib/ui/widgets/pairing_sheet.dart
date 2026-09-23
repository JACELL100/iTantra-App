
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/security/pairing_verifier.dart';
import '../../core/transport/transport_adapter.dart';
import '../theme.dart';

/// Pairing UI: show the connection code, then confirm the digits.
///
/// The six-digit short authentication string is the whole point of this
/// sheet. Two phones can agree on a key over an untrusted Wi-Fi or Bluetooth
/// link, but nothing stops a third device from sitting in the middle and
/// agreeing separately with each side. Having both users read the same six
/// digits aloud closes that hole with no infrastructure - and it is the only
/// approach that works when there is no internet, no CA and no directory.
class PairingSheet extends StatelessWidget {
  const PairingSheet({
    super.key,
    required this.payload,
    required this.shortAuthString,
    required this.onConfirmed,
    required this.onCancelled,
    this.peerLabel,
  });

  /// What the other side needs in order to reach us, encoded into the QR.
  final PairingPayload payload;

  /// Null until the key exchange has produced a code.
  final String? shortAuthString;

  final VoidCallback onConfirmed;
  final VoidCallback onCancelled;
  final String? peerLabel;

  @override
  Widget build(BuildContext context) {
    final String? code = shortAuthString;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            code == null ? 'Pair a device' : 'Check the code',
            style: Theme.of(context).textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          if (code == null) ...<Widget>[
            Center(
              child: Container(
                padding: const EdgeInsets.all(12),
                color: Colors.white,
                child: QrImageView(
                  data: payload.toUri().toString(),
                  size: 200,
                  // High error correction, no embedded logo: this may be
                  // scanned off a cracked screen in poor light.
                  errorCorrectionLevel: QrErrorCorrectLevel.H,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Scan this on the other phone, or connect over '
              '${_transportLabel(payload.transport)}.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ] else ...<Widget>[
            Text(
              peerLabel == null
                  ? 'Both phones must show these six digits.'
                  : 'Both you and $peerLabel must see these digits.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Center(
              child: Text(
                PairingVerifier.formatted(code),
                style: const TextStyle(
                  fontSize: 44,
                  letterSpacing: 6,
                  fontWeight: FontWeight.w700,
                  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                  color: ItantraTheme.deepBlue,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'If the digits differ, someone else is on the link. '
              'Do not continue.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: ItantraTheme.alertRed),
            ),
          ],
          const SizedBox(height: 24),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton(
                  onPressed: onCancelled,
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  // Confirmation is only possible once digits exist. A button
                  // tappable before then would let a user "approve" a session
                  // that nobody has verified.
                  onPressed: code == null ? null : onConfirmed,
                  child: Text(code == null ? 'Waiting' : 'They match'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _transportLabel(String transport) => switch (transport) {
        'wifi' => 'Wi-Fi',
        'bt' => 'Bluetooth',
        'ble' => 'a Bluetooth LE bridge',
        _ => transport,
      };
}

/// Lets a screen pick a link before pairing starts.
class TransportPicker extends StatelessWidget {
  const TransportPicker({
    super.key,
    required this.onSelected,
    required this.available,
  });

  final void Function(TransportKind kind) onSelected;
  final Set<TransportKind> available;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final TransportKind kind in TransportKind.values)
          ListTile(
            enabled: available.contains(kind),
            leading: Icon(switch (kind) {
              TransportKind.wifiTcp => Icons.wifi,
              TransportKind.bluetoothRfcomm => Icons.bluetooth,
              TransportKind.bleBridge => Icons.memory,
              TransportKind.loopback => Icons.loop,
            }),
            title: Text(_label(kind)),
            subtitle: Text(_hint(kind)),
            onTap: available.contains(kind) ? () => onSelected(kind) : null,
          ),
      ],
    );
  }

  static String _label(TransportKind kind) => switch (kind) {
        TransportKind.wifiTcp => 'Wi-Fi (direct or hotspot)',
        TransportKind.bluetoothRfcomm => 'Bluetooth',
        TransportKind.bleBridge => 'Radio bridge (BLE)',
        TransportKind.loopback => 'Demo (this phone only)',
      };

  /// Honest about the trade-off, because the user is choosing a link budget
  /// as much as a technology.
  static String _hint(TransportKind kind) => switch (kind) {
        TransportKind.wifiTcp => 'Fastest. Needs both phones on one network.',
        TransportKind.bluetoothRfcomm => 'Works with no network. Slower.',
        TransportKind.bleBridge =>
          'For an embedded radio. Slowest, text only.',
        TransportKind.loopback => 'Plays your own messages back to you.',
      };
}
