import 'dart:async';
import 'dart:typed_data';

import '../protocol/capabilities.dart';
import '../protocol/message.dart';
import '../session/message_pipeline.dart';
import '../util/log.dart';
import 'session_crypto.dart';

/// Where a pairing attempt has got to.
enum HandshakePhase {
  /// Nothing started.
  idle,

  /// Our key has gone out; waiting for theirs.
  waitingForKey,

  /// Both keys are in, the session key is derived, and the six digits are on
  /// screen waiting for a human to compare them.
  awaitingConfirmation,

  /// The user confirmed the digits. Keys are live.
  established,

  /// The user said the digits did not match, or the peer's key was unusable.
  rejected,
}

/// A snapshot of the pairing attempt, for the UI.
class HandshakeState {
  const HandshakeState({
    required this.phase,
    this.shortAuthString,
    this.peerCapabilities,
    this.peerLabel,
    this.error,
    this.isInitiator = false,
  });

  final HandshakePhase phase;

  /// Six digits, null until both keys are known.
  final String? shortAuthString;

  final DeviceCapabilities? peerCapabilities;
  final String? peerLabel;
  final String? error;
  final bool isInitiator;

  bool get isBusy =>
      phase == HandshakePhase.waitingForKey ||
      phase == HandshakePhase.awaitingConfirmation;

  static const HandshakeState initial = HandshakeState(
    phase: HandshakePhase.idle,
  );
}

/// Runs the X25519 key exchange and the short-authentication-string check.
///
/// The protocol, in order:
///
/// 1. Both sides generate an ephemeral X25519 key pair. Ephemeral on purpose:
///    there is no long-term identity to steal off a lost handset, and no key
///    management for an operator to get wrong.
/// 2. The dialling side (`role = a`) sends [HandshakeMessage] first; the
///    listening side (`role = b`) replies with its own. Stateless and
///    deterministic, so a lost first frame is simply re-sent.
/// 3. Each side derives the same AES-256-GCM key via HKDF over the shared
///    secret, with direction-separated nonce prefixes so the two ends can
///    never produce the same nonce.
/// 4. A six-digit code is derived from both public keys, sorted so both ends
///    compute the same digits regardless of who dialled.
/// 5. A human compares them. Only then does [confirm] attach the keys to the
///    pipeline and start encrypting.
///
/// Step 5 is not a formality. Without it the exchange is unauthenticated and a
/// man in the middle running two separate handshakes produces two different
/// codes, which is the only thing that reveals it.
class SessionHandshake {
  SessionHandshake({
    required MessagePipeline pipeline,
    required DeviceCapabilities localCapabilities,
    required bool isInitiator,
    String? displayName,
  })  : _pipeline = pipeline,
        _local = localCapabilities,
        _isInitiator = isInitiator,
        _displayName = displayName;

  final MessagePipeline _pipeline;
  final DeviceCapabilities _local;

  /// True for the side that opened the transport.
  final bool _isInitiator;

  final String? _displayName;

  final StreamController<HandshakeState> _states =
      StreamController<HandshakeState>.broadcast();

  KeyPairHandle? _keyPair;
  Uint8List? _localPublicKey;
  Uint8List? _peerPublicKey;
  SessionCrypto? _crypto;

  HandshakeState _state = HandshakeState.initial;
  bool _disposed = false;

  Stream<HandshakeState> get states => _states.stream;

  HandshakeState get state => _state;

  /// The live crypto once confirmed. Null means the link is still plaintext.
  SessionCrypto? get crypto => _crypto;

  bool get isEstablished => _state.phase == HandshakePhase.established;

  /// Sends our key. Idempotent: calling it twice while waiting just re-sends,
  /// which is what recovers from a lost first frame.
  Future<void> begin() async {
    if (_disposed) return;

    _keyPair ??= await SessionCrypto.generateKeyPair();
    _localPublicKey ??=
        await SessionCrypto.publicKeyBytes(_keyPair!);

    _emit(_state = HandshakeState(
      phase: HandshakePhase.waitingForKey,
      isInitiator: _isInitiator,
      peerLabel: _state.peerLabel,
      peerCapabilities: _state.peerCapabilities,
      shortAuthString: _state.shortAuthString,
    ));

    await _pipeline.send(_hello());
  }

  HandshakeMessage _hello() => HandshakeMessage(
        messageId: _pipeline.newMessageId(),
        senderId: _pipeline.deviceId,
        publicKey: _localPublicKey ?? Uint8List(32),
        role: _isInitiator ? 'a' : 'b',
        asrLanguages: _local.asrLanguages.toList(growable: false),
        ttsLanguages: _local.ttsLanguages.toList(growable: false),
        appVersion: _local.appVersion,
        protocolVersion: _local.protocolVersion,
        displayName: _displayName,
      );

  /// Feeds a received handshake. Safe to call repeatedly; a duplicate key is
  /// ignored rather than re-deriving.
  Future<void> onPeerHello(HandshakeMessage hello) async {
    if (_disposed) return;

    // The two sides must be on the same protocol. Guessing here would mean
    // deriving a key from a handshake whose fields mean something different.
    if (hello.protocolVersion != _local.protocolVersion) {
      _fail(
        'the other phone speaks protocol v${hello.protocolVersion}; this build '
        'speaks v${_local.protocolVersion}',
      );
      return;
    }

    final Uint8List peerKey = Uint8List.fromList(hello.publicKey);
    final Uint8List? alreadyHave = _peerPublicKey;
    if (alreadyHave != null) {
      // A retransmitted hello. If it is the same key it is noise; if it is a
      // *different* key the peer restarted, and silently re-keying on the same
      // session would be exactly the substitution attack the SAS exists to
      // catch.
      if (!_bytesEqual(alreadyHave, peerKey)) {
        _fail('the other phone changed its key mid-handshake; do not trust '
            'this link');
      }
      return;
    }

    _peerPublicKey = peerKey;

    try {
      _keyPair ??= await SessionCrypto.generateKeyPair();
      _localPublicKey ??= await SessionCrypto.publicKeyBytes(_keyPair!);

      final SessionCrypto candidate = await SessionCrypto.establish(
        localKeyPair: _keyPair!,
        remotePublicKey: peerKey,
        isInitiator: _isInitiator,
      );
      final String sas = await SessionCrypto.shortAuthString(
        _localPublicKey!,
        peerKey,
      );

      if (_disposed) return;
      _crypto = candidate;

      _emit(_state = HandshakeState(
        phase: HandshakePhase.awaitingConfirmation,
        shortAuthString: sas,
        isInitiator: _isInitiator,
        peerLabel: hello.displayName ?? hello.senderId,
        peerCapabilities: DeviceCapabilities(
          asrLanguages: hello.asrLanguages.toSet(),
          ttsLanguages: hello.ttsLanguages.toSet(),
          appVersion: hello.appVersion,
          protocolVersion: hello.protocolVersion,
        ),
      ));

      // If the responder has now seen the initiator's key, it owes a reply.
      // The initiator already sent its own in begin().
      if (!_isInitiator) await _pipeline.send(_hello());
    } on Object catch (error, stack) {
      ItLog.e('handshake', 'key agreement failed', error, stack);
      _fail('could not agree a key with the other phone');
    }
  }

  /// The user compared the digits and they matched.
  ///
  /// Only here do frames start being encrypted. Everything before this point,
  /// including the two public keys, is deliberately in the clear - which is
  /// safe because public keys are public, and is necessary because there is no
  /// key to encrypt them with yet.
  void confirm() {
    final SessionCrypto? crypto = _crypto;
    if (crypto == null || _state.phase != HandshakePhase.awaitingConfirmation) {
      return;
    }
    _pipeline.attachCrypto(crypto);
    _emit(_state = HandshakeState(
      phase: HandshakePhase.established,
      shortAuthString: _state.shortAuthString,
      peerCapabilities: _state.peerCapabilities,
      peerLabel: _state.peerLabel,
      isInitiator: _isInitiator,
    ));
    ItLog.i('handshake', 'session keys established for peer ${_state.peerLabel}');
  }

  /// The user said the digits did not match, or the link must be abandoned.
  ///
  /// Rejected outright rather than retried: a mismatch means either a bug or an
  /// attacker, and neither is fixed by trying again on the same link.
  void reject({String? reason}) {
    _crypto = null;
    _pipeline.detachCrypto();
    _fail(reason ?? 'the codes did not match, so the link was not trusted');
  }

  void _fail(String message) {
    if (_disposed) return;
    _emit(_state = HandshakeState(
      phase: HandshakePhase.rejected,
      error: message,
      isInitiator: _isInitiator,
      peerLabel: _state.peerLabel,
    ));
  }

  void _emit(HandshakeState next) {
    if (_disposed || _states.isClosed) return;
    _states.add(next);
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _crypto = null;
    await _states.close();
  }
}
