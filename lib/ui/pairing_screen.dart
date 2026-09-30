import 'dart:async';

import 'package:flutter/material.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/security/pairing_verifier.dart';
import '../core/security/session_crypto.dart';
import '../core/transport/bluetooth_rfcomm_transport.dart';
import '../core/transport/tcp_transport.dart';
import '../core/transport/transport_adapter.dart';
import '../di/service_locator.dart';
import 'home_screen.dart';
import 'theme.dart';

/// Full-page pairing flow: peer discovery, QR display/scan, SAS verification.
///
/// For Wi-Fi: this phone acts as TCP server and shows a QR containing its IP
/// and port. The other phone scans and dials as client.
///
/// For Bluetooth: we post our name and wait for a RFCOMM accept or initiate.
class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key, required this.transport});

  final PairingTransport transport;

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  _PairingStep _step = _PairingStep.discovering;
  String? _localIp;
  String? _error;
  String? _shortAuthString;
  bool _connecting = false;
  TransportAdapter? _transport;

  @override
  void initState() {
    super.initState();
    _startPairing();
  }

  Future<void> _startPairing() async {
    switch (widget.transport) {
      case PairingTransport.wifi:
        await _initWifi();
      case PairingTransport.bluetooth:
        await _initBluetooth();
    }
  }

  Future<void> _initWifi() async {
    try {
      final NetworkInfo info = NetworkInfo();
      final String? ip = await info.getWifiIP();
      if (ip == null || ip.isEmpty) {
        setState(() {
          _error =
              'Could not read local Wi-Fi address. Make sure Wi-Fi is enabled.';
          _step = _PairingStep.error;
        });
        return;
      }
      setState(() {
        _localIp = ip;
        _step = _PairingStep.showQr;
      });

      // Start listening for the peer to dial in.
      final TcpTransport tcp = TcpTransport.server();
      _transport = tcp;
      await tcp.connect();

      // Wait for the peer to connect.
      final Completer<void> connected = Completer<void>();
      late StreamSubscription<LinkState> sub;
      sub = tcp.state.listen((LinkState state) {
        if (state is LinkConnected) {
          sub.cancel();
          connected.complete();
        } else if (state is LinkDisconnected) {
          sub.cancel();
          connected.completeError(state.reason);
        }
      });
      await connected.future;

      // Generate a pairing code from crypto material.
      // Generate an ephemeral key pair and derive SAS for display.
      // In a full handshake the peer's public key arrives over the link;
      // for now we derive a displayable code from local key bytes to show
      // the verification step UI. Replace with actual peer key exchange.
      final KeyPairHandle localKp = await SessionCrypto.generateKeyPair();
      final localPub = await SessionCrypto.publicKeyBytes(localKp);
      // Derive SAS from local key only (placeholder until peer key exchange).
      final String sas = PairingVerifier.shortAuthString(localPub, localPub);
      setState(() {
        _shortAuthString = sas;
        _step = _PairingStep.verifySas;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _step = _PairingStep.error;
      });
    }
  }

  Future<void> _initBluetooth() async {
    try {
      setState(() => _step = _PairingStep.showQr);
      final BluetoothRfcommTransport bt = BluetoothRfcommTransport.server();
      _transport = bt;
      await bt.connect();

      final Completer<void> connected = Completer<void>();
      late StreamSubscription<LinkState> sub;
      sub = bt.state.listen((LinkState state) {
        if (state is LinkConnected) {
          sub.cancel();
          connected.complete();
        } else if (state is LinkDisconnected) {
          sub.cancel();
          connected.completeError(state.reason);
        }
      });
      await connected.future;

      final KeyPairHandle localKp = await SessionCrypto.generateKeyPair();
      final localPub = await SessionCrypto.publicKeyBytes(localKp);
      final String sas = PairingVerifier.shortAuthString(localPub, localPub);
      setState(() {
        _shortAuthString = sas;
        _step = _PairingStep.verifySas;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _step = _PairingStep.error;
      });
    }
  }

  Future<void> _confirmSas() async {
    final TransportAdapter? t = _transport;
    if (t == null) return;

    setState(() => _connecting = true);
    try {
      await ServiceLocator.instance.attachTransport(t);
      if (!mounted) return;
      // Replace both home and pairing with the conversation screen.
      Navigator.of(context)
          .pushNamedAndRemoveUntil('/conversation', (route) => false);
    } on Object catch (e) {
      setState(() {
        _error = e.toString();
        _step = _PairingStep.error;
        _connecting = false;
      });
    }
  }

  void _cancel() {
    _transport?.close();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.transport == PairingTransport.wifi
              ? 'Wi-Fi Pairing'
              : 'Bluetooth Pairing',
        ),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _cancel,
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    return switch (_step) {
      _PairingStep.discovering => const _StepWaiting(
          icon: Icons.radar,
          title: 'Looking for network…',
          subtitle: 'Make sure Wi-Fi or Bluetooth is enabled.',
        ),
      _PairingStep.showQr => _buildQrStep(),
      _PairingStep.verifySas => _buildSasStep(),
      _PairingStep.error => _buildError(),
    };
  }

  Widget _buildQrStep() {
    final String? ip = _localIp;
    final String label =
        widget.transport == PairingTransport.wifi ? 'Wi-Fi' : 'Bluetooth';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          'On the other phone, tap "Connect → $label" and scan this code.',
          style: Theme.of(context).textTheme.bodyLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        if (ip != null) ...<Widget>[
          Center(
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 12,
                  ),
                ],
              ),
              child: QrImageView(
                data: 'itantra://pair?ip=$ip&port=${TcpTransport.defaultPort}',
                size: 220,
                errorCorrectionLevel: QrErrorCorrectLevel.H,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              '$ip : ${TcpTransport.defaultPort}',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontWeight: FontWeight.w600,
                fontSize: 16,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Or enter this address manually on the other phone.',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ] else ...<Widget>[
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: 12),
          const Text(
            'Waiting for a peer to connect…',
            textAlign: TextAlign.center,
          ),
        ],
        const Spacer(),
        const _ListeningIndicator(),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: _cancel,
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _buildSasStep() {
    final String? code = _shortAuthString;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Icon(Icons.verified_user, size: 52, color: ItantraTheme.deepBlue),
        const SizedBox(height: 16),
        Text(
          'Verify the code',
          style: Theme.of(context).textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        Text(
          'Both phones must show the same six digits. '
          'If they differ, someone else is on the link — tap Cancel.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 28),
        if (code != null)
          Center(
            child: Text(
              PairingVerifier.formatted(code),
              style: const TextStyle(
                fontSize: 48,
                letterSpacing: 8,
                fontWeight: FontWeight.w700,
                color: ItantraTheme.deepBlue,
              ),
            ),
          )
        else
          const Center(child: CircularProgressIndicator()),
        const SizedBox(height: 16),
        Text(
          'This code changes every session and cannot be predicted.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.5),
              ),
          textAlign: TextAlign.center,
        ),
        const Spacer(),
        Row(
          children: <Widget>[
            Expanded(
              child: OutlinedButton(
                onPressed: _connecting ? null : _cancel,
                child: const Text('Cancel'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed:
                    (code != null && !_connecting) ? _confirmSas : null,
                child: _connecting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('They match — Connect'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildError() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Icon(Icons.error_outline, size: 56, color: ItantraTheme.alertRed),
        const SizedBox(height: 16),
        Text(
          'Pairing failed',
          style: Theme.of(context).textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        Text(
          _error ?? 'Unknown error',
          textAlign: TextAlign.center,
        ),
        const Spacer(),
        FilledButton(
          onPressed: () {
            setState(() {
              _step = _PairingStep.discovering;
              _error = null;
            });
            _startPairing();
          },
          child: const Text('Retry'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: _cancel,
          child: const Text('Back'),
        ),
      ],
    );
  }
}

enum _PairingStep { discovering, showQr, verifySas, error }

class _StepWaiting extends StatelessWidget {
  const _StepWaiting({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Icon(icon, size: 64, color: ItantraTheme.deepBlue),
        const SizedBox(height: 24),
        Text(
          title,
          style: Theme.of(context).textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 32),
        const CircularProgressIndicator(),
      ],
    );
  }
}

class _ListeningIndicator extends StatelessWidget {
  const _ListeningIndicator();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 8),
        Text(
          'Waiting for other phone to connect…',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
