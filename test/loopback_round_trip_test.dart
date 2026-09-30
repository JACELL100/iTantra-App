import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:itantra/core/protocol/framing.dart';
import 'package:itantra/core/transport/loopback_transport.dart';
import 'package:itantra/core/transport/transport_adapter.dart';

void main() {
  group('LoopbackTransport', () {
    test('delivers a framed payload from one side to the other', () async {
      final (TransportAdapter a, TransportAdapter b) =
          LoopbackTransport.pair(profile: LinkProfile.ideal, seed: 7);

      await a.connect();
      await b.connect();

      final List<Uint8List> received = <Uint8List>[];
      final FrameAccumulator accumulator = FrameAccumulator(
        (int version, Uint8List body) => received.add(body),
      );
      final StreamSubscription<Uint8List> sub =
          b.inbound.listen(accumulator.offer);

      final Uint8List payload = Uint8List.fromList(<int>[10, 20, 30]);
      await a.send(Framing.encode(payload));

      // The ideal profile still models a small delay, so the assertion has to
      // wait rather than run synchronously.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(received, hasLength(1));
      expect(received.single, equals(payload));

      await sub.cancel();
      await a.close();
      await b.close();
    });

    test('a poor link still delivers, only later', () async {
      // This is the test that justifies the profile abstraction: the whole
      // pipeline has to be correct under Bluetooth-grade latency, not just on
      // a fast Wi-Fi link, and that is hard to verify with real radios.
      final (TransportAdapter a, TransportAdapter b) =
          LoopbackTransport.pair(profile: LinkProfile.poor, seed: 3);

      await a.connect();
      await b.connect();

      final Completer<Uint8List> first = Completer<Uint8List>();
      final FrameAccumulator accumulator = FrameAccumulator(
        (int version, Uint8List body) {
          if (!first.isCompleted) first.complete(body);
        },
      );
      final StreamSubscription<Uint8List> sub =
          b.inbound.listen(accumulator.offer);

      final Uint8List payload =
          Uint8List.fromList(List<int>.generate(200, (int i) => i % 255));
      await a.send(Framing.encode(payload));

      final Uint8List delivered = await first.future.timeout(
        const Duration(seconds: 10),
      );
      expect(delivered, equals(payload));

      await sub.cancel();
      await a.close();
      await b.close();
    });

    test('reports connected state on both ends', () async {
      final (TransportAdapter a, TransportAdapter b) =
          LoopbackTransport.pair(profile: LinkProfile.ideal, seed: 1);

      final Future<LinkState> stateA = a.state.first;
      final Future<LinkState> stateB = b.state.first;

      await a.connect();
      await b.connect();

      expect(await stateA, isA<LinkConnected>());
      expect(await stateB, isA<LinkConnected>());

      await a.close();
      await b.close();
    });
  });
}
