import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Opaque handle to a local ephemeral key pair.
typedef KeyPairHandle = SimpleKeyPair;

/// Raised when a frame fails authentication.
class CryptoException implements Exception {
  const CryptoException(this.message);

  final String message;

  @override
  String toString() => 'CryptoException: $message';
}

/// Link encryption.
///
/// The threat is modest but real: an ad-hoc hotspot in a public place is
/// joinable by anyone nearby, and the traffic is emergency text. So every
/// frame is encrypted with AES-GCM under a key derived from an X25519
/// exchange performed at pairing time.
///
/// Two decisions worth stating:
///  * Keys are ephemeral per link. There is no long-term identity to steal
///    off a lost handset, and no key management for an operator to get wrong.
///  * The nonce is a counter, never random. AES-GCM fails catastrophically on
///    nonce reuse, and a counter with a hard monotonicity check is far easier
///    to prove correct than 96 bits of chance.
class SessionCrypto {
  SessionCrypto._(this._secretKey, this._sendPrefix, this._receivePrefix);

  static final X25519 _exchange = X25519();
  static final AesGcm _cipher = AesGcm.with256bits();
  static final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  final SecretKey _secretKey;

  /// Four-byte direction tag placed at the front of every nonce. Both sides
  /// derive the same key, so without a direction tag the two would generate
  /// identical nonces and reuse them immediately.
  final int _sendPrefix;
  final int _receivePrefix;

  int _sendCounter = 0;
  int _highestReceivedCounter = -1;

  static Future<KeyPairHandle> generateKeyPair() =>
      _exchange.newKeyPair();

  static Future<Uint8List> publicKeyBytes(KeyPairHandle pair) async {
    final SimplePublicKey key = await pair.extractPublicKey();
    return Uint8List.fromList(key.bytes);
  }

  /// Completes the handshake. [isInitiator] decides which direction tag this
  /// side uses for sending, so the two ends never collide.
  static Future<SessionCrypto> establish({
    required KeyPairHandle localKeyPair,
    required Uint8List remotePublicKey,
    required bool isInitiator,
  }) async {
    final SecretKey shared = await _exchange.sharedSecretKey(
      keyPair: localKeyPair,
      remotePublicKey: SimplePublicKey(
        remotePublicKey,
        type: KeyPairType.x25519,
      ),
    );

    // HKDF with a fixed info string binds the key to this application and
    // protocol version, so a key derived here is useless elsewhere.
    final SecretKey sessionKey = await _hkdf.deriveKey(
      secretKey: shared,
      info: utf8.encode('itantra/v1/session'),
      nonce: utf8.encode('itantra-static-salt'),
    );

    return SessionCrypto._(
      sessionKey,
      isInitiator ? 0x01 : 0x02,
      isInitiator ? 0x02 : 0x01,
    );
  }

  /// A short numeric code derived from both public keys.
  ///
  /// Comparing it out loud is what stops a man in the middle: an attacker who
  /// substituted its own key produces a different code on each side. There is
  /// no certificate authority to reach offline, so a human is the trust
  /// anchor.
  static Future<String> shortAuthString(
    Uint8List publicKeyA,
    Uint8List publicKeyB,
  ) async {
    // Sorted so both devices hash the same byte string regardless of role.
    final List<Uint8List> ordered = <Uint8List>[publicKeyA, publicKeyB];
    ordered.sort(_compareBytes);

    final Hash digest = await Sha256().hash(<int>[
      ...ordered[0],
      ...ordered[1],
    ]);
    final int value = ((digest.bytes[0] << 16) |
            (digest.bytes[1] << 8) |
            digest.bytes[2]) %
        1000000;
    return value.toString().padLeft(6, '0');
  }

  static int _compareBytes(Uint8List a, Uint8List b) {
    for (int i = 0; i < a.length && i < b.length; i++) {
      final int diff = a[i] - b[i];
      if (diff != 0) return diff;
    }
    return a.length - b.length;
  }

  /// Encrypts one payload. Output layout: 8-byte counter, 16-byte tag, then
  /// ciphertext. The counter travels in the clear because the receiver needs
  /// it to rebuild the nonce, and it carries no secret.
  Future<Uint8List> seal(Uint8List plaintext) async {
    final int counter = _sendCounter++;
    final SecretBox box = await _cipher.encrypt(
      plaintext,
      secretKey: _secretKey,
      nonce: _nonce(_sendPrefix, counter),
    );

    final Uint8List out = Uint8List(8 + 16 + box.cipherText.length);
    final ByteData header = ByteData.sublistView(out, 0, 8);
    header.setUint64(0, counter, Endian.big);
    out.setRange(8, 24, box.mac.bytes);
    out.setRange(24, out.length, box.cipherText);
    return out;
  }

  /// Decrypts one payload, rejecting replays.
  Future<Uint8List> open(Uint8List sealed) async {
    if (sealed.length < 24) {
      throw const CryptoException('sealed payload too short');
    }
    final int counter =
        ByteData.sublistView(sealed, 0, 8).getUint64(0, Endian.big);

    // Strictly increasing. A replayed "help, flooding here" from an hour ago
    // would be indistinguishable from a live one otherwise.
    if (counter <= _highestReceivedCounter) {
      throw CryptoException('replayed or out-of-order counter $counter');
    }

    final SecretBox box = SecretBox(
      Uint8List.sublistView(sealed, 24),
      nonce: _nonce(_receivePrefix, counter),
      mac: Mac(Uint8List.sublistView(sealed, 8, 24)),
    );

    try {
      final List<int> plain = await _cipher.decrypt(
        box,
        secretKey: _secretKey,
      );
      _highestReceivedCounter = counter;
      return Uint8List.fromList(plain);
    } on SecretBoxAuthenticationError {
      throw const CryptoException('authentication failed');
    }
  }

  Uint8List _nonce(int prefix, int counter) {
    // 12 bytes: 4 of direction tag, 8 of counter.
    final Uint8List nonce = Uint8List(12);
    final ByteData view = ByteData.sublistView(nonce);
    view.setUint32(0, prefix, Endian.big);
    view.setUint64(4, counter, Endian.big);
    return nonce;
  }
}
