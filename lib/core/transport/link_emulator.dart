import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'transport_adapter.dart';

/// Wraps any transport and degrades it to a chosen bitrate, latency, jitter,
/// and loss.
///
/// This exists so the low-bitrate claim can be demonstrated on a bench without
/// having to physically walk a phone to the edge of Bluetooth range. Judges
/// can watch the same conversation work at 9.6 kbit/s with 5% loss, and the
/// seeded RNG means the run is reproducible.
///
/// It only shapes; it never rewrites payloads, so what crosses the wire is
/// exactly what the real transport would carry.
class LinkEmulator implements TransportAdapter {
  LinkEmulator({
    required TransportAdapter inner,
    required this.bitsPerSecond,
    this.oneWayLatencyMs = 0,
    this.jitterMs = 0,
    this.lossProbability = 0,
    int seed = 1234,
  })  : _inner = inner,
        _random = Random(seed);

  final TransportAdapter _inner;
  final int bitsPerSecond;
  final int oneWayLatencyMs;
  final int jitterMs;
  final double lossProbability;
  final Random _random;

  /// When the emulated channel becomes free again. Messages queue behind each
  /// other exactly as they would on a real half-duplex radio, which is what
  /// makes back-pressure visible instead of theoretical.
  DateTime _channelFreeAt = DateTime.now();
  int _queued = 0;
  int _dropped = 0;

  @override
  TransportDescriptor get descriptor => TransportDescriptor(
        kind: _inner.descriptor.kind,
        label: '${_inner.descriptor.label} @ ${bitsPerSecond ~/ 1000} kbit/s',
        nominalBitsPerSecond: bitsPerSecond,
        maxFrameBytes: _inner.descriptor.maxFrameBytes,
      );

  @override
  Stream<LinkState> get state => _inner.state;

  @override
  Stream<Uint8List> get inbound => _inner.inbound;

  @override
  Future<void> connect() => _inner.connect();

  @override
  Future<void> send(Uint8List payload) async {
    if (lossProbability > 0 && _random.nextDouble() < lossProbability) {
      _dropped++;
      // Return normally: a lost frame on a radio produces no error at the
      // sender either. The receipt timeout is what notices.
      return;
    }

    final int serialisationMs = (payload.length * 8 * 1000) ~/ bitsPerSecond;
    final int jitter =
        jitterMs == 0 ? 0 : _random.nextInt(jitterMs * 2 + 1) - jitterMs;

    final DateTime now = DateTime.now();
    final DateTime start =
        _channelFreeAt.isAfter(now) ? _channelFreeAt : now;
    _channelFreeAt = start.add(Duration(milliseconds: serialisationMs));

    final int waitMs = start.difference(now).inMilliseconds +
        serialisationMs +
        oneWayLatencyMs +
        jitter;

    _queued++;
    if (waitMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: waitMs));
    }
    _queued--;
    await _inner.send(payload);
  }

  @override
  LinkQuality quality() {
    final LinkQuality inner = _inner.quality();
    return LinkQuality(
      roundTripMs: oneWayLatencyMs * 2,
      queuedFrames: inner.queuedFrames + _queued,
      sentFrames: inner.sentFrames,
      receivedFrames: inner.receivedFrames,
      droppedFrames: inner.droppedFrames + _dropped,
    );
  }

  @override
  Future<void> close() => _inner.close();
}
