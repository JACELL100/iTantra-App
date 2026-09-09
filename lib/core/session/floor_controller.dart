import 'dart:async';

/// Who currently holds the right to transmit.
sealed class FloorState {
  const FloorState();
}

class FloorFree extends FloorState {
  const FloorFree();
}

class FloorHeldLocally extends FloorState {
  const FloorHeldLocally({required this.expiresAtMs, required this.forAlert});
  final int expiresAtMs;
  final bool forAlert;
}

class FloorHeldByPeer extends FloorState {
  const FloorHeldByPeer({required this.expiresAtMs, required this.forAlert});
  final int expiresAtMs;
  final bool forAlert;
}

enum FloorDecision { granted, denied, preempted }

/// Half-duplex floor arbitration.
///
/// A single Bluetooth or BLE link cannot carry two speakers at once, and
/// without arbitration both users talk over each other exactly like an
/// untrained pair on a real radio. Two design choices matter:
///
///   * Leases, not locks. If a peer walks out of range while holding the
///     floor, a lock would deadlock the channel forever. A 15-second lease
///     expires on its own, so the worst case is a short wait.
///   * Alerts pre-empt speech. Someone announcing a distress message must not
///     queue behind a chatty peer. An alert request displaces a non-alert
///     holder; alert-versus-alert is first come, first served.
///
/// The clock is injected so tests can advance time without sleeping, and so
/// this class stays free of any platform dependency.
class FloorController {
  FloorController({
    this.leaseMs = defaultLeaseMs,
    int Function()? clock,
  }) : _clock = clock ?? _defaultClock;

  static const int defaultLeaseMs = 15000;

  final int leaseMs;
  final int Function() _clock;

  final StreamController<FloorState> _states =
      StreamController<FloorState>.broadcast();

  FloorState _state = const FloorFree();

  static int _defaultClock() => DateTime.now().millisecondsSinceEpoch;

  Stream<FloorState> get states => _states.stream;

  /// Current state, with any expired lease already collapsed to free.
  FloorState get state {
    _expireIfNeeded();
    return _state;
  }

  int get leaseDurationMs => leaseMs;

  /// True when the local user could start talking right now.
  bool get canCaptureLocally {
    final FloorState s = state;
    return s is FloorFree || s is FloorHeldLocally;
  }

  /// Local push-to-talk press.
  FloorDecision requestLocal({bool forAlert = false}) {
    _expireIfNeeded();
    final FloorState current = _state;

    if (current is FloorHeldByPeer) {
      if (!(forAlert && !current.forAlert)) return FloorDecision.denied;
      _set(FloorHeldLocally(
        expiresAtMs: _clock() + leaseMs,
        forAlert: forAlert,
      ));
      return FloorDecision.preempted;
    }

    _set(FloorHeldLocally(
      expiresAtMs: _clock() + leaseMs,
      forAlert: forAlert || (current is FloorHeldLocally && current.forAlert),
    ));
    return FloorDecision.granted;
  }

  /// A floor request arrived from the peer.
  FloorDecision requestFromPeer({bool forAlert = false}) {
    _expireIfNeeded();
    final FloorState current = _state;

    if (current is FloorHeldLocally) {
      if (!(forAlert && !current.forAlert)) return FloorDecision.denied;
      _set(FloorHeldByPeer(
        expiresAtMs: _clock() + leaseMs,
        forAlert: forAlert,
      ));
      return FloorDecision.preempted;
    }

    _set(FloorHeldByPeer(
      expiresAtMs: _clock() + leaseMs,
      forAlert: forAlert || (current is FloorHeldByPeer && current.forAlert),
    ));
    return FloorDecision.granted;
  }

  void releaseLocal() {
    if (_state is FloorHeldLocally) _set(const FloorFree());
  }

  void releaseFromPeer() {
    if (_state is FloorHeldByPeer) _set(const FloorFree());
  }

  /// Extends the local lease. Called while a long utterance is still being
  /// spoken so the floor does not expire mid-sentence.
  void renewLocal() {
    final FloorState current = _state;
    if (current is FloorHeldLocally) {
      _set(FloorHeldLocally(
        expiresAtMs: _clock() + leaseMs,
        forAlert: current.forAlert,
      ));
    }
  }

  void _expireIfNeeded() {
    final FloorState current = _state;
    final int now = _clock();
    if (current is FloorHeldLocally && now >= current.expiresAtMs) {
      _set(const FloorFree());
    } else if (current is FloorHeldByPeer && now >= current.expiresAtMs) {
      _set(const FloorFree());
    }
  }

  void _set(FloorState next) {
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  Future<void> dispose() async => _states.close();
}
