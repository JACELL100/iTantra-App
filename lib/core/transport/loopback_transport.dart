import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'transport_adapter.dart';

/// A pair of transports wired to each other in-process.
///
/// This is what makes the system testable without two phones. It also models
/// the link rather than pretending it is perfect: latency, jitter, loss, and
/// a bitrate-derived serialisation delay. A test that passes over an ideal
/// loopback but falls apart at 9.6 kbit/s teaches nothing, and the whole
/// premise of this project is the slow link.
///
/// Loss is seeded so a failing run can be reproduced exactly.
class LinkProfile {
  const LinkProfile({
    this.oneWayLatencyMs = 5,
    this.jitterMs = 0,
    this.lossProbability = 0,
    this.bitsPerSecond = 1000000,
  });

  final int oneWayLatencyMs;
  final int jitterMs;
  final double lossProbability;
  final int bitsPerSecond;

  static const LinkProfile ideal = LinkProfile();

  /// A bad Bluetooth link at the edge of range.
  static const LinkProfile poor = LinkProfile(
    oneWayLatencyMs: 120,
    jitterMs: 60,
    lossProbability: 0.05,
    bitsPerSecond: 60000,
  );

  /// The ESP32 BLE bridge: the slowest path we support.
  static const LinkProfile bleBridge = LinkProfile(
    oneWayLatencyMs: 180,
    jitterMs: 40,
    lossProbability: 0.02,
    bitsPerSecond: 20000,
  );
}

class LoopbackTransport implements TransportAdapter {
  LoopbackTransport._(this._label, this._profile, this._random);

  /// Creates two transports that deliver to each other.
  static (LoopbackTransport, LoopbackTransport) pair({
    LinkProfile profile = LinkProfile.ideal,
    int seed = 42,
  }) {
    final Random random = Random(seed);
    final LoopbackTransport a = LoopbackTransport._('peer-B', profile, random);
    final LoopbackTransport b = LoopbackTransport._('peer-A', profile, random);
    a._peer = b;
    b._peer = a;
    return (a, b);
  }

  static const int maxFrameBytes = 8192;

  final String _label;
  final LinkProfile _profile;
  final Random _random;

  late final LoopbackTransport _peer;

  final StreamController<LinkState> _state =
      StreamController<LinkState>.broadcast();
  final StreamController<Uint8List> _inbound =
      StreamController<Uint8List>.broadcast();

  int _sent = 0;
  int _received = 0;
  int _dropped = 0;
  int _queued = 0;
  bool _connected = false;
  bool _closed = false;

  @override
  TransportDescriptor get descriptor => TransportDescriptor(
        kind: TransportKind.loopback,
        label: 'Loopback ($_label)',
        nominalBitsPerSecond: _profile.bitsPerSecond,
        maxFrameBytes: maxFrameBytes,
      );

  @override
  Stream<LinkState> get state => _state.stream;

  @override
  Stream<Uint8List> get inbound => _inbound.stream;

  @override
  Future<void> connect() async {
    if (_closed) {
      throw TransportException(TransportErrorCode.closed, 'already closed');
    }
    _connected = true;
    _state.add(LinkConnected(_label));
  }

  @override
  Future<void> send(Uint8List payload) async {
    if (!_connected) {
      throw TransportException(
          TransportErrorCode.notConnected, 'connect() first');
    }
    if (payload.length > maxFrameBytes) {
      throw TransportException(
        TransportErrorCode.frameTooLarge,
        '${payload.length} bytes exceeds $maxFrameBytes',
      );
    }

    _sent++;

    if (_profile.lossProbability > 0 &&
        _random.nextDouble() < _profile.lossProbability) {
      // Silently dropped, exactly as a radio would. The pipeline's receipt
      // timeout is what surfaces this to the user.
      _dropped++;
      return;
    }

    // Serialisation delay dominates on a slow link: 400 bytes at 9.6 kbit/s
    // is a third of a second before the first byte even lands.
    final int serialisationMs =
        (payload.length * 8 * 1000) ~/ _profile.bitsPerSecond;
    final int jitter = _profile.jitterMs == 0
        ? 0
        : _random.nextInt(_profile.jitterMs * 2 + 1) - _profile.jitterMs;
    final int delay =
        (_profile.oneWayLatencyMs + serialisationMs + jitter).clamp(0, 60000);

    _queued++;
    final Uint8List copy = Uint8List.fromList(payload);
    unawaited(Future<void>.delayed(Duration(milliseconds: delay), () {
      _queued--;
      _peer._deliver(copy);
    }));
  }

  void _deliver(Uint8List payload) {
    if (_closed || _inbound.isClosed) return;
    _received++;
    _inbound.add(payload);
  }

  @override
  LinkQuality quality() => LinkQuality(
        roundTripMs: _profile.oneWayLatencyMs * 2,
        queuedFrames: _queued,
        sentFrames: _sent,
        receivedFrames: _received,
        droppedFrames: _dropped,
      );

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _connected = false;
    _state.add(const LinkDisconnected('closed', recoverable: false));
    await _state.close();
    await _inbound.close();
  }
}
