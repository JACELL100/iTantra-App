import 'dart:typed_data';

/// Length-prefixed framing.
///
/// Bluetooth SPP and TCP are both byte streams with no message boundaries: a
/// 200-byte write can arrive as 40 + 160, or two writes can arrive glued
/// together. Every practical bug in a link like this comes from pretending
/// otherwise, so each payload is wrapped in a fixed 6-byte header:
///
///   0..1  magic 'I','T'   - resynchronisation point after corruption
///   2     version         - lets a newer build refuse an older peer clearly
///   3..5  length, 24-bit big endian - payload byte count
///
/// 24 bits caps a frame at 16 MB, far above the 8 KB policy limit, and keeps
/// the header at six bytes instead of eight.
class Framing {
  const Framing._();

  static const int magic0 = 0x49; // 'I'
  static const int magic1 = 0x54; // 'T'
  static const int headerSize = 6;
  static const int maxPayloadBytes = 8192;

  static Uint8List encode(Uint8List payload, {int version = 1}) {
    if (payload.length > maxPayloadBytes) {
      throw FramingException(
          'payload ${payload.length} exceeds $maxPayloadBytes bytes');
    }
    final Uint8List out = Uint8List(headerSize + payload.length);
    out[0] = magic0;
    out[1] = magic1;
    out[2] = version & 0xFF;
    out[3] = (payload.length >> 16) & 0xFF;
    out[4] = (payload.length >> 8) & 0xFF;
    out[5] = payload.length & 0xFF;
    out.setRange(headerSize, out.length, payload);
    return out;
  }
}

class FramingException implements Exception {
  const FramingException(this.message);

  final String message;

  @override
  String toString() => 'FramingException: $message';
}

/// Reassembles frames from arbitrary byte chunks.
///
/// Callback style rather than a Stream so a single received chunk containing
/// three frames delivers all three synchronously, in order, with no event
/// loop turn in between. On the receive path that ordering guarantee matters
/// more than composability.
class FrameAccumulator {
  FrameAccumulator(
    void Function(int version, Uint8List payload) onFrame, {
    this.onError,
    this.onFrameOnly,
    this.maxPayloadBytes = Framing.maxPayloadBytes,
  }) : _onFrame = onFrame;

  /// Callback receives (version, payload). Version is typically 1.
  /// For backward compatibility, also accepts callbacks that only take payload.
  final void Function(int version, Uint8List payload) _onFrame;

  /// Optional callback that only receives payload (no version).
  final void Function(Uint8List)? onFrameOnly;

  final void Function(String message)? onError;
  final int maxPayloadBytes;

  final BytesBuilder _buffer = BytesBuilder(copy: true);

  /// Feeds received bytes.
  void offer(List<int> chunk) {
    if (chunk.isEmpty) return;
    _buffer.add(chunk);
    _drain();
  }

  void _drain() {
    Uint8List bytes = _buffer.toBytes();
    int offset = 0;

    while (true) {
      // Hunt for the magic. Anything before it is garbage from a truncated
      // frame or a peer that spoke first; skipping to the next 'I','T' lets
      // the link recover instead of wedging forever.
      int start = offset;
      while (start + 1 < bytes.length &&
          !(bytes[start] == Framing.magic0 &&
              bytes[start + 1] == Framing.magic1)) {
        start++;
      }
      if (start > offset) {
        onError?.call('discarded ${start - offset} unsynchronised bytes');
        offset = start;
      }

      if (bytes.length - offset < Framing.headerSize) break;

      final int version = bytes[offset + 2];
      final int length = (bytes[offset + 3] << 16) |
          (bytes[offset + 4] << 8) |
          bytes[offset + 5];

      if (length > maxPayloadBytes) {
        // Not recoverable within this frame: skip the magic and resync.
        onError?.call('frame length $length exceeds limit');
        offset += 2;
        continue;
      }

      if (bytes.length - offset < Framing.headerSize + length) break;

      final Uint8List payload = Uint8List.sublistView(
        bytes,
        offset + Framing.headerSize,
        offset + Framing.headerSize + length,
      );
      // Call the primary callback with version
      _onFrame(version, Uint8List.fromList(payload));
      // Also call the optional payload-only callback if set
      onFrameOnly?.call(Uint8List.fromList(payload));
      offset += Framing.headerSize + length;
    }

    final Uint8List remainder = Uint8List.sublistView(bytes, offset);
    _buffer.clear();
    if (remainder.isNotEmpty) _buffer.add(remainder);
    bytes = Uint8List(0);
  }

  int get bufferedBytes => _buffer.length;

  void reset() => _buffer.clear();
}
