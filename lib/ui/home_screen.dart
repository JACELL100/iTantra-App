import 'package:flutter/material.dart';

import '../di/service_locator.dart';
import 'pairing_screen.dart';
import 'theme.dart';

/// Home screen / session setup.
///
/// The user chooses how to connect: loopback demo (one phone, self-test),
/// Wi-Fi TCP, or Bluetooth. Language pack readiness is shown here so the user
/// knows before pairing whether the selected language will actually work.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _connecting = false;
  String? _error;

  Future<void> _startDemo() async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      await ServiceLocator.instance.attachLoopback();
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed('/conversation');
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _startWifi() async {
    // Navigate to pairing screen which handles TCP peer discovery.
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const PairingScreen(transport: PairingTransport.wifi),
      ),
    );
  }

  Future<void> _startBluetooth() async {
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            const PairingScreen(transport: PairingTransport.bluetooth),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ServiceLocator loc = ServiceLocator.instance;
    final bool hasAsr = loc.asr != null;
    final bool hasTts = loc.tts != null;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const SizedBox(height: 16),
              // App name + tagline
              Row(
                children: <Widget>[
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: <Color>[
                          ItantraTheme.saffron,
                          ItantraTheme.deepBlue,
                        ],
                      ),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(Icons.radio, color: Colors.white, size: 30),
                  ),
                  const SizedBox(width: 14),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'iTantra',
                        style:
                            Theme.of(context).textTheme.headlineMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: ItantraTheme.deepBlue,
                                ),
                      ),
                      Text(
                        'Offline speech transceiver',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 32),

              // Pack status
              _PackStatus(hasAsr: hasAsr, hasTts: hasTts, lang: loc.languageTag),
              const SizedBox(height: 32),

              // Connection options
              Text(
                'Connect',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 12),

              _ConnectTile(
                icon: Icons.wifi,
                title: 'Wi-Fi (same network)',
                subtitle: 'Fast · TCP on local hotspot or router',
                color: const Color(0xFF1976D2),
                enabled: !_connecting,
                onTap: _startWifi,
              ),
              const SizedBox(height: 10),
              _ConnectTile(
                icon: Icons.bluetooth,
                title: 'Bluetooth Classic',
                subtitle: ServiceLocator.instance.capabilities.supportsRfcommClassic
                    ? 'RFCOMM serial link'
                    : 'Not available on this device',
                color: const Color(0xFF5C6BC0),
                enabled: !_connecting &&
                    ServiceLocator.instance.capabilities.supportsRfcommClassic,
                onTap: _startBluetooth,
              ),
              const SizedBox(height: 10),
              _ConnectTile(
                icon: Icons.loop,
                title: 'Loopback demo',
                subtitle: 'Self-test on one phone',
                color: const Color(0xFF43A047),
                enabled: !_connecting,
                onTap: _startDemo,
                loading: _connecting,
              ),

              if (_error != null) ...<Widget>[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],

              const Spacer(),

              // Privacy notice
              Text(
                'All speech recognition and synthesis run on-device. '
                'No audio leaves this phone.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.6),
                    ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PackStatus extends StatelessWidget {
  const _PackStatus({
    required this.hasAsr,
    required this.hasTts,
    required this.lang,
  });

  final bool hasAsr;
  final bool hasTts;
  final String lang;

  @override
  Widget build(BuildContext context) {
    final bool allGood = hasAsr && hasTts;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: allGood
            ? Colors.green.withValues(alpha: 0.1)
            : ItantraTheme.saffron.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: allGood
              ? Colors.green.withValues(alpha: 0.3)
              : ItantraTheme.saffron.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            allGood ? Icons.check_circle_outline : Icons.warning_amber_rounded,
            color: allGood ? Colors.green : ItantraTheme.saffron,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  allGood
                      ? 'Ready — $lang packs loaded'
                      : 'Language packs needed for $lang',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (!hasAsr || !hasTts)
                  Text(
                    '${!hasAsr ? "ASR" : ""}'
                    '${!hasAsr && !hasTts ? " and " : ""}'
                    '${!hasTts ? "TTS" : ""} pack missing. '
                    'Go to Settings → Installed packs.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          if (!allGood)
            TextButton(
              onPressed: () => Navigator.of(context).pushNamed('/settings'),
              child: const Text('Fix'),
            ),
        ],
      ),
    );
  }
}

class _ConnectTile extends StatelessWidget {
  const _ConnectTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.enabled,
    required this.onTap,
    this.loading = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final bool enabled;
  final VoidCallback onTap;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Material(
      borderRadius: BorderRadius.circular(12),
      color: enabled
          ? color.withValues(alpha: 0.08)
          : Theme.of(context).disabledColor.withValues(alpha: 0.05),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: <Widget>[
              Icon(icon, color: enabled ? color : Colors.grey, size: 28),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: enabled ? null : Colors.grey,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: enabled ? null : Colors.grey,
                          ),
                    ),
                  ],
                ),
              ),
              if (loading)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  Icons.arrow_forward_ios,
                  size: 16,
                  color: enabled ? color : Colors.grey,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Which transport to pair over.
enum PairingTransport { wifi, bluetooth }
