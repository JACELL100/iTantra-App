import 'dart:async';

import 'package:flutter/services.dart';

import '../protocol/framing.dart';
import '../util/log.dart';
import 'transport_adapter.dart';

/// Classic Bluetooth RFCOMM through a platform channel.
///
/// Why native rather than a pub package: the maintained Flutter Bluetooth
/// packages target BLE. RFCOMM needs BluetoothServerSocket /
/// createRfcommSocketToServiceRecord, which only exist in the Android SDK. The
/// native side (RfcommChannel.kt) owns the socket and streams bytes over an
/// EventChannel.
///
/// RFCOMM is the workhorse for this project. It reaches ~100-200 kbit/s in
/// practice, needs no shared network, works on every phone back to our minSdk,
/// and unlike Wi-Fi Direct it does not fight with the user's mobile data.
class BluetoothRfcommTransport implements TransportAdapter {
  BluetoothRfcommTransport({
    required this.isServer,
    this.peerAddress,
    this.peerName = 'Bluetooth peer',
  }) : assert(isServer || peerAddress != null,
            'a client needs the peer MAC address');

  static const MethodChannel _control =
      MethodChannel('org.itantra/rfcomm');
  static const EventChannel _events =
      EventChannel('org.itantra/rfcomm/events');

  /// Must match the UUID in RfcommChannel.kt and in the ESP32 firmware.
  static const String serviceUuid = '6f1d9b30-4c8a-4a4e-9a0f-1b7c5d2e8a11';

  static const int maxFrameBytes = 8192;

  final bool isServer;
  final String? peerAddress;
  final String peerName;

  final LinkStateChannel _state = LinkStateChannel();
  final StreamController<Uint8List> _inbound =
      StreamController<Uint8List>.broadcast();

  late final FrameAccumulator _accumulator = FrameAccumulator(
    onFrame: (int version, Uint8List frame) {
      _received++;
      if (!_inbound.isClosed) _inbound.add(frame);
    },
  );

  StreamSubscription<dynamic>? _sub;
  int _sent = 0;
  int _received = 0;
  int _dropped = 0;
  bool _connected = false;
  bool _closed = false;

  @override
  TransportDescriptor get descriptor => const TransportDescriptor(
        kind: TransportKind.bluetoothRfcomm,
        label: 'Bluetooth (RFCOMM)',
        nominalBitsPerSecond: 120000,
        maxFrameBytes: maxFrameBytes,
      );

  @override
  LinkState get state => _state.current;

  @override
  Stream<LinkState> get states => _state.stream;

  @override
  Stream<Uint8List> get inbound => _inbound.stream;

  @override
  Future<void> connect() async {
    if (_closed) {
      throw TransportException(TransportErrorCode.closed, 'already closed');
    }
    _state.add(const LinkConnecting());

    _sub = _events.receiveBroadcastStream().listen(_onEvent, onError:
        (Object e, StackTrace s) {
      ItLog.w('rfcomm', 'event stream error: $e');
      _state.add(LinkDisconnected('$e'));
    });

    try {
      await _control.invokeMethod<void>(
        isServer ? 'listen' : 'connect',
        <String, Object?>{
          'uuid': serviceUuid,
          'address': peerAddress,
          'name': 'iTantra',
        },
      );
    } on PlatformException catch (e) {
      final TransportErrorCode code = switch (e.code) {
        'permission_denied' => TransportErrorCode.permissionDenied,
        'unreachable' => TransportErrorCode.peerUnreachable,
        _ => TransportErrorCode.ioError,
      };
      _state.add(LinkDisconnected(
        e.message ?? e.code,
        recoverable: code != TransportErrorCode.permissionDenied,
      ));
      throw TransportException(code, e.message ?? e.code, e);
    }
  }

  void _onEvent(dynamic event) {
    if (event is! Map) return;
    switch (event['event']) {
      case 'connected':
        _connected = true;
        _accumulator.reset();
        _state.add(LinkConnected((event['peer'] as String?) ?? peerName));
      case 'data':
        final Uint8List? bytes = event['bytes'] as Uint8List?;
        if (bytes != null) _accumulator.offer(bytes);
      case 'disconnected':
        _connected = false;
        _state.add(LinkDisconnected(
            (event['reason'] as String?) ?? 'link dropped'));
      case 'error':
        _dropped++;
        ItLog.w('rfcomm', 'native error: ${event['reason']}');
    }
  }

  @override
  Future<void> send(Uint8List payload) async {
    if (!_connected) {
      throw TransportException(
          TransportErrorCode.notConnected, 'RFCOMM link is not up');
    }
    if (payload.length > maxFrameBytes) {
      throw TransportException(
        TransportErrorCode.frameTooLarge,
        '${payload.length} bytes exceeds $maxFrameBytes',
      );
    }
    try {
      await _control.invokeMethod<void>('write', <String, Object>{
        'bytes': Framing.encode(payload),
      });
      _sent++;
    } on PlatformException catch (e) {
      _dropped++;
      throw TransportException(TransportErrorCode.ioError, e.code, e);
    }
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
    try {
      await _control.invokeMethod<void>('close');
    } on PlatformException catch (_) {
      // Already gone; nothing useful to do.
    }
    if (!_state.isClosed) {
      _state.add(const LinkDisconnected('closed', recoverable: false));
      await _state.close();
    }
    if (!_inbound.isClosed) await _inbound.close();
  }
}
