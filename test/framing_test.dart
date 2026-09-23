import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:itantra/core/protocol/framing.dart';

void main() {
  group('Framing', () {
    test('round-trips a payload', () {
      final Uint8List payload = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);
      final Uint8List frame = Framing.encode(payload);

      final List<Uint8List> received = <Uint8List>[];
      final FrameAccumulator accumulator = FrameAccumulator(
        (int version, Uint8List body) => received.add(body),
      );
      accumulator.offer(frame);

      expect(received, hasLength(1));
      expect(received.single, equals(payload));
    });

    test('reassembles a frame split across arbitrary chunks', () {
      // This is the case that actually breaks naive transports: Bluetooth and
      // TCP both deliver bytes in whatever sizes they please, with no
      // relationship to message boundaries.
      final Uint8List payload =
          Uint8List.fromList(List<int>.generate(300, (int i) => i % 251));
      final Uint8List frame = Framing.encode(payload);

      final List<Uint8List> received = <Uint8List>[];
      final FrameAccumulator accumulator = FrameAccumulator(
        (int version, Uint8List body) => received.add(body),
      );

      for (int i = 0; i < frame.length; i += 7) {
        final int end = (i + 7) > frame.length ? frame.length : i + 7;
        accumulator.offer(frame.sublist(i, end));
      }

      expect(received, hasLength(1));
      expect(received.single, equals(payload));
    });

    test('delivers two frames arriving in one read', () {
      final Uint8List first = Framing.encode(Uint8List.fromList(<int>[9]));
      final Uint8List second = Framing.encode(Uint8List.fromList(<int>[8, 7]));

      final List<int> lengths = <int>[];
      final FrameAccumulator accumulator = FrameAccumulator(
        (int version, Uint8List body) => lengths.add(body.length),
      );
      accumulator.offer(<int>[...first, ...second]);

      expect(lengths, equals(<int>[1, 2]));
    });

    test('resynchronises after a corrupt magic byte', () {
      final Uint8List good = Framing.encode(Uint8List.fromList(<int>[42]));

      final List<Uint8List> received = <Uint8List>[];
      final List<String> errors = <String>[];
      final FrameAccumulator accumulator = FrameAccumulator(
        (int version, Uint8List body) => received.add(body),
        onError: (String message) => errors.add(message),
      );

      // Garbage first, then a valid frame. A radio link will do this, and
      // dropping the whole stream on one bad byte would mean a single burst
      // of interference kills the session.
      accumulator.offer(<int>[0x00, 0xFF, 0x13]);
      accumulator.offer(good);

      expect(received, hasLength(1));
      expect(received.single, equals(Uint8List.fromList(<int>[42])));
    });

    test('rejects a payload larger than the limit', () {
      expect(
        () => Framing.encode(Uint8List(Framing.maxPayloadBytes + 1)),
        throwsA(isA<FramingException>()),
      );
    });

    test('an empty accumulator buffers nothing', () {
      final FrameAccumulator accumulator = FrameAccumulator(
        (int version, Uint8List body) {},
      );
      expect(accumulator.bufferedBytes, 0);
    });
  });
}
