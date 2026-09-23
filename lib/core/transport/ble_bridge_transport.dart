import 'dart:async';
import 'dart:typed_data';

import '../protocol/framing.dart';
import '../util/log.dart';
import 'transport_adapter.dart';

/// Abstraction over the BLE central so this transport stays testable.
///
/// The real implementation wraps flutter_blue_plus; tests provide a fake. The
/// transport itself contains the part worth testing - chunking and
/// reassembly - and none of the platform surface.
abstract class BleLink {
  /// Negotiated ATT payload size. 20 bytes until an MTU exchange succeeds.
  int get chunkSize;

  Stream<Uint8List> get notifications;

  Future<void> writeChunk(Uint8List chunk);

  Future<void> disconnect();
}

/// Talks to the ESP32 bridge over BLE GATT.
///
/// This is the lowest-bandwidth path: after ATT overhead a 185-byte MTU gives
/// roughly 20 kbit/s of usable throughput. Sending audio over it is out of the
/// question, which is precisely the argument for this project's whole design -
/// a 300-byte sentence crosses it in about 120 ms, while a 3-second Opus clip
/// would take three seconds.
///
/// Two things make the BLE path different from TCP:
///   * Writes must be chunked to the MTU and serialised. Issuing a second
///     write before the first completes is the classic way to lose bytes on
///     Android's BLE stack, so a lock is not optional.
///   * Notifications arrive as arbitrary slices, so reassembly runs through
///     the same [FrameAccumulator] the stream transports use.
class BleBridgeTransport implements TransportAdapter {
  BleBridgeTransport({required BleLink link, this.peerLabel = 'BLE bridge'})
      : _link = link;

  /// Smaller than the stream transports on purpose: a 8 kB frame at 20 kbit/s
  /// would occupy the link for three seconds and delay an alert behind it.
  static const int maxFrameBytes = 2048;
  static const int minChunkSize = 20;

  final BleLink _link;
  final String peerLabel;

  final StreamController<LinkState> _state =
      StreamController<LinkState>.broadcast();
  final StreamController<Uint8List> _inbound =
      StreamController<Uint8List>.broadcast();

  late final FrameAccumulator _accumulator = FrameAccumulator(
    (version, payload) {}, // Primary callback (required)
    onFrameOnly: (Uint8List f) {
      _received++;
      if (!_inbound.isClosed) _inbound.add(f);
    },
  );

  StreamSubscription<Uint8List>? _sub;
  Future<void> _writeChain = Future<void>.value();
  int _sent = 0;
  int _received = 0;
  int _dropped = 0;
  bool _connected = false;
  bool _closed = false;

  @override
  TransportDescriptor get descriptor => const TransportDescriptor(
        kind: TransportKind.bleBridge,
        label: 'BLE bridge (ESP32)',
        nominalBitsPerSecond: 20000,
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
    _state.add(const LinkConnecting());
    _accumulator.reset();
    _sub = _link.notifications.listen(
      _accumulator.offer,
      onError: (Object e, StackTrace s) {
        _dropped++;
        ItLog.w('ble', 'notification error: $e');
      },
      cancelOnError: false,
    );
    _connected = true;
    _state.add(LinkConnected(peerLabel));

    if (_link.chunkSize <= minChunkSize) {
      // Usable, but every frame costs many more round trips. Worth telling
      // the user, because moving the phone closer often fixes it.
      _state.add(const LinkDegraded(
          'BLE MTU not negotiated; throughput will be low'));
    }
  }

  @override
  Future<void> send(Uint8List payload) async {
    if (!_connected) {
      throw TransportException(
          TransportErrorCode.notConnected, 'BLE link is not up');
    }
    if (payload.length > maxFrameBytes) {
      throw TransportException(
        TransportErrorCode.frameTooLarge,
        '${payload.length} bytes exceeds $maxFrameBytes on the BLE bridge',
      );
    }

    final Uint8List framed = Framing.encode(payload);
    final int chunkSize =
        _link.chunkSize < minChunkSize ? minChunkSize : _link.chunkSize;

    // Serialise writes by chaining onto the previous one.
    final Completer<void> done = Completer<void>();
    _writeChain = _writeChain.then((_) async {
      try {
        for (int offset = 0; offset < framed.length; offset += chunkSize) {
          final int end = (offset + chunkSize).clamp(0, framed.length);
          await _link.writeChunk(
              Uint8List.sublistView(framed, offset, end));
        }
        _sent++;
        done.complete();
      } catch (e, s) {
        _dropped++;
        ItLog.w('ble', 'write failed: $e');
        done.completeError(
            TransportException(TransportErrorCode.ioError, '$e', e), s);
      }
    });
    return done.future;
  }

  @override
  LinkQuality quality() => LinkQuality(
        sentFrames: _sent,
        receivedFrames: _received,
        droppedFrames: _dropped,
      );

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _connected = false;
    await _sub?.cancel();
    await _link.disconnect();
    if (!_state.isClosed) {
      _state.add(const LinkDisconnected('closed', recoverable: false));
      await _state.close();
    }
    if (!_inbound.isClosed) await _inbound.close();
  }
}
