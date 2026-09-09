import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Man-in-the-middle protection for the pairing step.
///
/// Raw X25519 gives confidentiality against a passive listener but nothing
/// against an attacker who sits between the two phones and runs two separate
/// handshakes. The standard fix without a PKI is a short authentication
/// string: both sides derive a code from the two public keys and a human
/// compares them out loud. An attacker in the middle holds different keys with
/// each side, so the codes cannot match.
///
/// Six digits is the usual compromise. It is short enough to read aloud over
/// ambient noise and gives a 1-in-a-million chance per attempt, with only one
/// attempt available because a mismatch tears the session down.
class PairingVerifier {
  const PairingVerifier._();

  static const int digits = 6;

  /// Derives the code. Ordering the keys canonically means both sides compute
  /// the same string without having to agree on who is the initiator.
  static String shortAuthString(
    Uint8List localPublicKey,
    Uint8List remotePublicKey,
  ) {
    final List<Uint8List> ordered = <Uint8List>[
      localPublicKey,
      remotePublicKey,
    ]..sort(_compareBytes);

    final Digest digest = sha256.convert(<int>[
      ...utf8.encode('itantra/sas/v1'),
      ...ordered[0],
      ...ordered[1],
    ]);

    // Take 4 bytes and reduce modulo 10^6. The modulo bias over 2^32 is about
    // one part in 4000, which is irrelevant next to the 1-in-10^6 guess.
    final ByteData view = ByteData.sublistView(
        Uint8List.fromList(digest.bytes.sublist(0, 4)));
    final int value = view.getUint32(0, Endian.big) % 1000000;
    return value.toString().padLeft(digits, '0');
  }

  /// Formats as "123 456" so it is easier to read aloud accurately.
  static String formatted(String code) =>
      '${code.substring(0, 3)} ${code.substring(3)}';

  static int _compareBytes(Uint8List a, Uint8List b) {
    final int n = a.length < b.length ? a.length : b.length;
    for (int i = 0; i < n; i++) {
      final int d = a[i] - b[i];
      if (d != 0) return d;
    }
    return a.length - b.length;
  }

  /// Constant-time comparison of two codes.
  ///
  /// Timing analysis on a six-digit code a human typed is not a realistic
  /// attack, but comparing secrets in constant time costs nothing and stops
  /// this from being cargo-culted into somewhere it does matter.
  static bool matches(String a, String b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}

/// The payload encoded into the pairing QR code.
///
/// URI form: itantra://pair?t=<transport>&a=<address>&p=<port>&s=<pubkey b64u>
///
/// Scanning a QR is not just convenience: it carries the public key over an
/// out-of-band channel (the camera), which turns the short authentication
/// string check into a formality rather than the only defence.
class PairingPayload {
  const PairingPayload({
    required this.transport,
    required this.address,
    required this.port,
    required this.publicKey,
  });

  final String transport; // 'wifi' | 'bt' | 'ble'
  final String address;
  final int port;
  final Uint8List publicKey;

  Uri toUri() => Uri(
        scheme: 'itantra',
        host: 'pair',
        queryParameters: <String, String>{
          't': transport,
          'a': address,
          'p': port.toString(),
          's': base64Url.encode(publicKey),
        },
      );

  static PairingPayload parse(String raw) {
    final Uri uri = Uri.parse(raw.trim());
    if (uri.scheme != 'itantra' || uri.host != 'pair') {
      throw const FormatException('not an iTantra pairing code');
    }
    final Map<String, String> q = uri.queryParameters;
    final String? key = q['s'];
    if (key == null) throw const FormatException('pairing code has no key');
    final Uint8List publicKey = base64Url.decode(key);
    if (publicKey.length != 32) {
      throw const FormatException('pairing key is the wrong length');
    }
    return PairingPayload(
      transport: q['t'] ?? 'wifi',
      address: q['a'] ?? '',
      port: int.tryParse(q['p'] ?? '') ?? 47311,
      publicKey: publicKey,
    );
  }
}
