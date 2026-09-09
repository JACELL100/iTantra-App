import 'dart:collection';

/// Named stages of the end-to-end path.
///
/// The evaluation asks for three separate numbers (speak-to-text, text-to-
/// audio, and the delta between the two phones), so the code records the
/// individual stage boundaries instead of one blunt total. When a demo is
/// slow, these say which stage to blame.
enum Stage {
  a0SpeechEnd,
  a1Endpoint,
  a2AsrFinal,
  a3Queued,
  a4Sent,
  a5Receipt,
  b0Received,
  b1Stored,
  b2SynthesisStart,
  b3FirstPcm,
  b4FirstAudible,
  b5PlaybackDone,
}

/// Stage timestamps for one message.
class MessageTimeline {
  MessageTimeline(this.messageId);

  final String messageId;
  final Map<Stage, int> _stamps = <Stage, int>{};

  void mark(Stage stage, int monotonicMicros) {
    // First write wins: a retry must not overwrite the original timing.
    _stamps.putIfAbsent(stage, () => monotonicMicros);
  }

  int? micros(Stage stage) => _stamps[stage];

  double? spanMs(Stage from, Stage to) {
    final int? a = _stamps[from];
    final int? b = _stamps[to];
    if (a == null || b == null) return null;
    return (b - a) / 1000.0;
  }

  /// Sender-side latency: what the speaker waits before the message is out.
  double? get sendMs => spanMs(Stage.a0SpeechEnd, Stage.a4Sent);

  /// Receiver-side latency: bytes in to sound out.
  double? get receiveMs => spanMs(Stage.b0Received, Stage.b4FirstAudible);

  /// The headline number: sentence finished here, sentence starts there.
  double? get deltaMs => spanMs(Stage.a0SpeechEnd, Stage.b4FirstAudible);
}

/// A percentile snapshot for one metric key.
class LatencySummary {
  const LatencySummary({
    required this.count,
    required this.p50,
    required this.p95,
  });

  final int count;
  final double p50;
  final double p95;
}

/// Rolling latency and counter store.
///
/// In-memory and bounded. The diagnostics screen reads percentiles from here;
/// durable samples go to SQLite through the repository, so a crash does not
/// lose a benchmark run.
class MetricsCollector {
  MetricsCollector({this.maxTimelines = 200, this.maxSamplesPerKey = 500});

  final int maxTimelines;
  final int maxSamplesPerKey;

  final LinkedHashMap<String, MessageTimeline> _timelines =
      LinkedHashMap<String, MessageTimeline>();
  final Map<String, List<double>> _samples = <String, List<double>>{};
  final Map<String, int> _counters = <String, int>{};

  /// Monotonic clock. A process stopwatch does not jump when the system
  /// clock is corrected, which wall-clock time does.
  static final Stopwatch _clock = Stopwatch()..start();

  static int nowMicros() => _clock.elapsedMicroseconds;

  MessageTimeline timeline(String messageId) {
    final MessageTimeline existing =
        _timelines.putIfAbsent(messageId, () => MessageTimeline(messageId));
    if (_timelines.length > maxTimelines) {
      _timelines.remove(_timelines.keys.first);
    }
    return existing;
  }

  void mark(String messageId, Stage stage, [int? micros]) {
    timeline(messageId).mark(stage, micros ?? nowMicros());
  }

  void record(String key, double value) {
    final List<double> list = _samples.putIfAbsent(key, () => <double>[]);
    list.add(value);
    if (list.length > maxSamplesPerKey) list.removeAt(0);
  }

  void increment(String key, [int by = 1]) {
    _counters[key] = (_counters[key] ?? 0) + by;
  }

  int counter(String key) => _counters[key] ?? 0;

  Map<String, int> get counters => Map<String, int>.unmodifiable(_counters);

  List<String> get latencyKeys => _samples.keys.toList(growable: false);

  /// Percentiles for one metric. p95 rather than an average, because an
  /// average hides the one message in twenty that took three seconds, and
  /// that is the one a judge notices.
  LatencySummary? percentiles(String key) {
    final List<double>? list = _samples[key];
    if (list == null || list.isEmpty) return null;
    final List<double> sorted = List<double>.of(list)..sort();
    return LatencySummary(
      count: sorted.length,
      p50: _percentile(sorted, 0.50),
      p95: _percentile(sorted, 0.95),
    );
  }

  static double _percentile(List<double> sorted, double fraction) {
    if (sorted.length == 1) return sorted.first;
    final double position = fraction * (sorted.length - 1);
    final int low = position.floor();
    final int high = position.ceil();
    final double weight = position - low;
    return sorted[low] * (1 - weight) + sorted[high] * weight;
  }

  /// Closes out a message and files its spans as samples.
  void finalizeTimeline(String messageId) {
    final MessageTimeline? line = _timelines[messageId];
    if (line == null) return;
    final double? send = line.sendMs;
    final double? receive = line.receiveMs;
    final double? delta = line.deltaMs;
    if (send != null) record('send_ms', send);
    if (receive != null) record('receive_ms', receive);
    if (delta != null) record('delta_ms', delta);
  }

  Map<String, Object?> summary() {
    final Map<String, Object?> latency = <String, Object?>{};
    for (final String key in _samples.keys) {
      final LatencySummary? p = percentiles(key);
      if (p == null) continue;
      latency[key] = <String, Object?>{
        'count': p.count,
        'p50': p.p50,
        'p95': p.p95,
      };
    }
    return <String, Object?>{'counters': counters, 'latency': latency};
  }

  void clear() {
    _timelines.clear();
    _samples.clear();
    _counters.clear();
  }
}

/// Targets from the evaluation criteria, shown next to live numbers so a
/// reviewer does not have to remember them.
class BenchmarkTargets {
  const BenchmarkTargets._();

  static const double sendP95Ms = 900;
  static const double receiveP95Ms = 700;
  static const double deltaP95Ms = 1500;
  static const double asrRealTimeFactor = 0.6;
  static const double ttsRealTimeFactor = 0.5;
}
