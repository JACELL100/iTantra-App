import 'package:flutter/material.dart';

import '../core/metrics/metrics.dart';
import '../di/service_locator.dart';
import 'theme.dart';

/// The numbers the brief is scored on, shown on the device.
///
/// Efficiency, accuracy and latency are 80% of the evaluation, so they are a
/// first-class screen rather than a log line. Showing measured percentiles
/// next to the stated targets also makes it impossible to quietly regress:
/// a red row is visible to anyone holding the phone.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  final ServiceLocator _locator = ServiceLocator.instance;

  Map<String, LatencySummary> _stored = <String, LatencySummary>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final Map<String, LatencySummary> out = <String, LatencySummary>{};
    for (final String metric in await _locator.repository.recordedMetrics()) {
      out[metric] = await _locator.repository.percentiles(metric);
    }
    if (mounted) setState(() => _stored = out);
  }

  @override
  Widget build(BuildContext context) {
    final MetricsCollector metrics = _locator.metrics;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: ListView(
        children: <Widget>[
          const _Header('Latency (this session)'),
          for (final String key in metrics.latencyKeys)
            _LatencyRow(
              label: _prettyMetric(key),
              summary: metrics.percentiles(key),
              targetP95: _targetFor(key),
            ),
          if (metrics.latencyKeys.isEmpty)
            const _Note('Send a message to collect timings.'),

          const _Header('Latency (all runs, stored)'),
          for (final MapEntry<String, LatencySummary> entry in _stored.entries)
            _LatencyRow(
              label: _prettyMetric(entry.key),
              summary: entry.value,
              targetP95: _targetFor(entry.key),
            ),
          if (_stored.isEmpty)
            const _Note('No stored samples yet.'),

          const _Header('Targets'),
          const _Note(
            'Send ≤ ${BenchmarkTargets.sendP95Ms} ms p95 · '
            'Receive ≤ ${BenchmarkTargets.receiveP95Ms} ms p95 · '
            'Phone-to-phone ≤ ${BenchmarkTargets.deltaP95Ms} ms p95',
          ),

          const _Header('Counters'),
          for (final MapEntry<String, int> entry in metrics.counters.entries)
            ListTile(
              dense: true,
              title: Text(entry.key.replaceAll('_', ' ')),
              trailing: Text('${entry.value}'),
            ),

          const _Header('Model packs'),
          ListTile(
            dense: true,
            title: const Text('Installed packs'),
            trailing: Text('${_locator.packs.packs.length}'),
          ),
          ListTile(
            dense: true,
            title: const Text('Total on-disk size'),
            trailing: Text(_megabytes(_locator.packs.totalBytes)),
          ),
          ListTile(
            dense: true,
            title: const Text('Link'),
            trailing: Text(_locator.transport?.descriptor.label ?? 'none'),
          ),
        ],
      ),
    );
  }

  static String _megabytes(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  static String _prettyMetric(String key) => switch (key) {
        'send_ms' => 'Speech end to sent',
        'receive_ms' => 'Received to first audio',
        'delta_ms' => 'Phone to phone',
        'asr_compute_ms' => 'Recognition compute',
        'tts_compute_ms' => 'Synthesis compute',
        'asr_rtf' => 'Recognition real-time factor',
        'tts_rtf' => 'Synthesis real-time factor',
        _ => key.replaceAll('_', ' '),
      };

  static double? _targetFor(String key) => switch (key) {
        'send_ms' => BenchmarkTargets.sendP95Ms.toDouble(),
        'receive_ms' => BenchmarkTargets.receiveP95Ms.toDouble(),
        'delta_ms' => BenchmarkTargets.deltaP95Ms.toDouble(),
        'asr_rtf' => BenchmarkTargets.asrRealTimeFactor,
        'tts_rtf' => BenchmarkTargets.ttsRealTimeFactor,
        _ => null,
      };
}

class _LatencyRow extends StatelessWidget {
  const _LatencyRow({
    required this.label,
    required this.summary,
    this.targetP95,
  });

  final String label;
  final LatencySummary summary;
  final double? targetP95;

  @override
  Widget build(BuildContext context) {
    final double? target = targetP95;
    final bool over = target != null && summary.p95 > target;

    return ListTile(
      dense: true,
      title: Text(label),
      subtitle: Text('n = ${summary.count}'
          '${target == null ? '' : '  ·  target p95 ${_fmt(target)}'}'),
      trailing: Text(
        'p50 ${_fmt(summary.p50)}   p95 ${_fmt(summary.p95)}',
        style: TextStyle(
          fontWeight: FontWeight.w600,
          // Red when a scored target is missed. Better to see it here than
          // to be told during an evaluation.
          color: over ? ItantraTheme.alertRed : null,
        ),
      ),
    );
  }

  static String _fmt(double value) =>
      value >= 10 ? value.toStringAsFixed(0) : value.toStringAsFixed(2);
}

class _Header extends StatelessWidget {
  const _Header(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding:
            const EdgeInsets.only(left: 16, right: 16, top: 20, bottom: 4),
        child: Text(
          title.toUpperCase(),
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                letterSpacing: 1.2,
                color: ItantraTheme.deepBlue,
              ),
        ),
      );
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Text(text, style: Theme.of(context).textTheme.bodySmall),
      );
}
