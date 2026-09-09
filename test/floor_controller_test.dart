import 'package:flutter_test/flutter_test.dart';
import 'package:itantra/core/session/floor_controller.dart';

void main() {
  group('FloorController', () {
    test('grants the floor when it is free', () {
      final FloorController floor = FloorController();
      expect(floor.requestLocal(), FloorDecision.granted);
      expect(floor.state, isA<FloorHeldLocally>());
    });

    test('denies a local request while the peer holds the floor', () {
      final FloorController floor = FloorController();
      floor.requestFromPeer();
      // Half-duplex on purpose: two people talking at once over a low
      // bitrate link produces two unintelligible messages, not a
      // conversation.
      expect(floor.requestLocal(), FloorDecision.denied);
    });

    test('an alert pre-empts the peer', () {
      final FloorController floor = FloorController();
      floor.requestFromPeer();
      // Distress outranks politeness. This is the whole reason the floor
      // decision distinguishes alerts.
      expect(floor.requestLocal(forAlert: true), FloorDecision.preempted);
      expect(floor.state, isA<FloorHeldLocally>());
    });

    test('releases back to free', () {
      final FloorController floor = FloorController();
      floor.requestLocal();
      floor.releaseLocal();
      expect(floor.state, isA<FloorFree>());
    });

    test('a stale lease expires without an explicit release', () {
      int now = 0;
      final FloorController floor =
          FloorController(leaseMs: 1000, clock: () => now);

      floor.requestFromPeer();
      expect(floor.requestLocal(), FloorDecision.denied);

      // A peer that walked out of range never sends a release. Without a
      // lease the local user would be locked out of the radio forever.
      now = 2000;
      expect(floor.requestLocal(), FloorDecision.granted);
    });
  });
}
