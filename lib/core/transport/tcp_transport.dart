import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../protocol/framing.dart';
import '../util/log.dart';
import 'offline_guard.dart';
import 'transport_adapter.dart';

/// TCP over whatever local Wi-Fi the two phones share: Wi-Fi Direct, a
/// hotspot, or the ESP32 soft AP.
///
/// One side listens and one side dials. Which is which is decided during
/// pairing (the phone showing the QR listens), so there is no discovery
/// protocol and no multicast - both would need network permissions we do not
/// want and neither works reliably across Android versions.
///
/// TCP_NODELAY is essential here: our messages are a few hundred bytes and
/// Nagle would sit on them for up to 40 ms waiting for more data that never
/// comes. On a 700 ms latency budget that is real money.
class TcpTransport implements TransportAdapter {
  TcpTransport._({
    required this.role,
    required this.address,
    required this.port,
    OfflineGuard guard = const OfflineGuard(),
  }) : _guard = guard;

  /// Dials a peer that is already listening.
  factory TcpTransport.client({
    required String address,
    int port = defaultPort,
    OfflineGuard guard = const OfflineGuard(),
  }) =>
      TcpTransport._(
        role: TcpRole.client,
        address: address,
        port: port,
        guard: guard,
      );

  /// Listens for the peer to dial in.
  factory TcpTransport.server({
    int port = defaultPort,
    OfflineGuard guard = const OfflineGuard(),
  }) =>
      TcpTransport._(
        role: TcpRole.server,
        address: '0.0.0.0',
        port: port,
        guard: guard,
      );

  static const int defaultPort = 47311;
  static const int maxFrameBytes = 8192;

  final TcpRole role;
  final String address;
  final int port;
  final OfflineGuard _guard;

  final StreamController<LinkState> _state =
      StreamController<LinkState>.broadcast();
  final StreamController<Uint8List> _inbound =
      StreamController<Uint8List>.broadcast();

  ServerSocket? _server;
  Socket? _socket;
  StreamSubscription<Uint8List>? _socketSub;
  late final FrameAccumulator _accumulator = FrameAccumulator(
    (version, payload) {}, // Primary callback (required)
    onFrameOnly: _onFrame,
  );

  int _sent = 0;
  int _received = 0;
  int _dropped = 0;
  bool _closed = false;

  @override
  TransportDescriptor get descriptor => const TransportDescriptor(
        kind: TransportKind.wifiTcp,
        label: 'Wi-Fi (TCP)',
        // Deliberately conservative. Wi-Fi Direct at the edge of range is
        // nothing like the headline rate, and the UI's "this will take N
        // seconds" estimate should not lie optimistically.
        nominalBitsPerSecond: 500000,
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
    try {
      if (role == TcpRole.client) {
        // Refuses anything that is not a local literal address.
        _guard.requireLinkLocal(address);
        final Socket socket = await Socket.connect(
          address,
          port,
          timeout: const Duration(seconds: 8),
        );
        _attach(socket);
      } else {
        final ServerSocket server = await ServerSocket.bind(
          InternetAddress.anyIPv4,
          port,
          shared: false,
        );
        _server = server;
        server.listen((Socket socket) {
          if (_socket != null) {
            // One peer at a time. A second connection is more likely to be a
            // stale reconnect than a real second device.
            ItLog.w('tcp', 'rejecting extra connection');
            socket.destroy();
            return;
          }
          if (!_guard.isPermitted(socket.remoteAddress)) {
            ItLog.w('tcp', 'rejecting non-local peer');
            socket.destroy();
            return;
          }
          _attach(socket);
        }, onError: (Object e) {
          _state.add(LinkDisconnected('listener failed: $e'));
        });
      }
    } on OfflineViolation {
      rethrow;
    } on SocketException catch (e) {
      _state.add(LinkDisconnected(e.message));
      throw TransportException(
        TransportErrorCode.peerUnreachable,
        'could not reach $address:$port',
        e,
      );
    }
  }

  void _attach(Socket socket) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    _socket = socket;
    _accumulator.reset();
    _socketSub = socket.listen(
      (Uint8List data) => _accumulator.offer(data),
      onError: (Object e, StackTrace s) {
        ItLog.w('tcp', 'socket error: $e');
        _state.add(LinkDisconnected('$e'));
      },
      onDone: () {
        _socket = null;
        _state.add(const LinkDisconnected('peer closed the connection'));
      },
      cancelOnError: false,
    );
    _state.add(LinkConnected('${socket.remoteAddress.address}:${socket.remotePort}'));
  }

  void _onFrame(Uint8List payload) {
    _received++;
    if (!_inbound.isClosed) _inbound.add(payload);
  }

  @override
  Future<void> send(Uint8List payload) async {
    final Socket? socket = _socket;
    if (socket == null) {
      throw TransportException(
          TransportErrorCode.notConnected, 'no TCP peer attached');
    }
    if (payload.length > maxFrameBytes) {
      throw TransportException(
        TransportErrorCode.frameTooLarge,
        '${payload.length} bytes exceeds $maxFrameBytes',
      );
    }
    try {
      socket.add(Framing.encode(payload));
      // Awaiting flush surfaces a dead link now rather than several messages
      // later, which matters because the sender's UI claims "sent".
      await socket.flush();
      _sent++;
    } on SocketException catch (e) {
      _dropped++;
      throw TransportException(TransportErrorCode.ioError, e.message, e);
    }
  }

  @override
  LinkQuality quality() => LinkQuality(
        queuedFrames: 0,
        sentFrames: _sent,
        receivedFrames: _received,
        droppedFrames: _dropped,
      );

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _socketSub?.cancel();
    _socket?.destroy();
    _socket = null;
    await _server?.close();
    _server = null;
    if (!_state.isClosed) {
      _state.add(const LinkDisconnected('closed', recoverable: false));
      await _state.close();
    }
    if (!_inbound.isClosed) await _inbound.close();
  }
}

enum TcpRole { client, server }
