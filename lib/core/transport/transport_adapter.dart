import 'dart:async';
import 'dart:typed_data';

/// Which physical link a transport speaks over.
enum TransportKind {
  /// TCP over a Wi-Fi Direct group, a hotspot, or a shared access point.
  wifiTcp,

  /// Classic Bluetooth RFCOMM - the most reliable option on cheap phones.
  bluetoothRfcomm,

  /// BLE GATT to an ESP32 that relays onward. Lowest bandwidth, longest reach.
  bleBridge,

  /// In-process pair used by tests and the on-device self-test.
  loopback,
}

class TransportDescriptor {
  const TransportDescriptor({
    required this.kind,
    required this.label,
    required this.nominalBitsPerSecond,
    required this.maxFrameBytes,
  });

  final TransportKind kind;
  final String label;

  /// Advertised throughput. Used to predict how long a message will take and
  /// to warn before a long utterance is sent over a slow link.
  final int nominalBitsPerSecond;

  final int maxFrameBytes;

  /// Rough time to push [byteCount] across, ignoring latency.
  int estimatedMillisFor(int byteCount) =>
      (byteCount * 8 * 1000) ~/ nominalBitsPerSecond;
}

/// Link lifecycle.
sealed class LinkState {
  const LinkState();
}

class LinkIdle extends LinkState {
  const LinkIdle();
}

class LinkConnecting extends LinkState {
  const LinkConnecting();
}

class LinkConnected extends LinkState {
  const LinkConnected(this.peerLabel);
  final String peerLabel;
}

/// Still usable but impaired - low MTU, high loss, weak signal. Worth showing
/// in the UI because a user can often fix it by moving.
class LinkDegraded extends LinkState {
  const LinkDegraded(this.reason);
  final String reason;
}

class LinkDisconnected extends LinkState {
  const LinkDisconnected(this.reason, {this.recoverable = true});
  final String reason;

  /// False for permission denials and version mismatches, where retrying in a
  /// loop just burns battery.
  final bool recoverable;
}

/// A link-state stream that also remembers the latest event.
///
/// Every transport needs both a push channel and a synchronous answer, and the
/// answer has to be available the instant `connect()` returns - a caller that
/// only had the stream would have to wait for an event that has already been
/// delivered, or miss it entirely by subscribing a moment too late.
///
/// Composition rather than a [StreamController] subclass so each transport can
/// keep publishing with a bare `add` and reading `isClosed` unchanged.
class LinkStateChannel {
  final StreamController<LinkState> _controller =
      StreamController<LinkState>.broadcast();

  LinkState _current = const LinkIdle();

  /// The state right now.
  LinkState get current => _current;

  Stream<LinkState> get stream => _controller.stream;

  bool get isClosed => _controller.isClosed;

  void add(LinkState next) {
    _current = next;
    if (!_controller.isClosed) _controller.add(next);
  }

  Future<void> close() => _controller.close();
}

class LinkQuality {
  const LinkQuality({
    this.roundTripMs,
    this.queuedFrames = 0,
    this.sentFrames = 0,
    this.receivedFrames = 0,
    this.droppedFrames = 0,
  });

  final int? roundTripMs;
  final int queuedFrames;
  final int sentFrames;
  final int receivedFrames;
  final int droppedFrames;
}

enum TransportErrorCode {
  notConnected,
  frameTooLarge,
  permissionDenied,
  peerUnreachable,
  ioError,
  closed,
}

class TransportException implements Exception {
  TransportException(this.code, this.message, [this.cause]);

  final TransportErrorCode code;
  final String message;
  final Object? cause;

  @override
  String toString() => 'TransportException(${code.name}): $message';
}

/// One uniform interface over four very different radios.
///
/// Everything above this line - pipeline, session, UI - is written against
/// this and nothing else, which is why the same code runs unchanged over
/// loopback in a unit test and over BLE on a bench.
abstract class TransportAdapter {
  TransportDescriptor get descriptor;

  /// The link state right now, without awaiting a stream event.
  LinkState get state;

  /// Link state transitions, for anything that has to react to them.
  Stream<LinkState> get states;

  /// Decoded frames, already de-framed by the transport.
  Stream<Uint8List> get inbound;

  Future<void> connect();

  /// Sends one payload. Implementations frame it themselves.
  Future<void> send(Uint8List payload);

  LinkQuality quality();

  Future<void> close();
}
