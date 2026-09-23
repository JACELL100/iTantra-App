import 'dart:typed_data';

/// A decoded RIFF/WAVE file.
class WavData {
  const WavData({required this.samples, required this.sampleRateHz});

  final Int16List samples;
  final int sampleRateHz;
}

/// The smallest WAV codec the app needs: 16-bit PCM both ways.
///
/// Written by hand rather than pulled in as a dependency for three reasons.
/// The formats involved are trivial and fully specified. Speech APIs are given
/// `response_format: wav` so nothing has to decode MP3, which would need a real
/// codec. And a byte-order mistake here is silent - it produces noise, not an
/// error - so it is worth having the code, and a test, somewhere readable.
class WavCodec {
  const WavCodec._();

  static const int _headerBytes = 44;

  /// Wraps PCM16 samples in a 44-byte canonical WAV header.
  ///
  /// Always little-endian, which is what every speech API expects and what
  /// every phone produces; no big-endian branch, because the alternative is
  /// unreachable and untestable code.
  static Uint8List encode(Int16List samples, int sampleRateHz) {
    final int dataBytes = samples.length * 2;
    final ByteData header = ByteData(_headerBytes);

    void ascii(int offset, String tag) {
      for (int i = 0; i < tag.length; i++) {
        header.setUint8(offset + i, tag.codeUnitAt(i));
      }
    }

    const int channels = 1;
    const int bitsPerSample = 16;
    final int byteRate = sampleRateHz * channels * bitsPerSample ~/ 8;

    ascii(0, 'RIFF');
    header.setUint32(4, 36 + dataBytes, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    header.setUint32(16, 16, Endian.little); // PCM chunk size
    header.setUint16(20, 1, Endian.little); // format: PCM
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRateHz, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, channels * bitsPerSample ~/ 8, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);
    ascii(36, 'data');
    header.setUint32(40, dataBytes, Endian.little);

    final Uint8List out = Uint8List(_headerBytes + dataBytes);
    out.setRange(0, _headerBytes, header.buffer.asUint8List());
    final ByteData body = ByteData.sublistView(out, _headerBytes);
    for (int i = 0; i < samples.length; i++) {
      body.setInt16(i * 2, samples[i], Endian.little);
    }
    return out;
  }

  /// Parses a RIFF/WAVE file, walking the chunk list rather than assuming the
  /// data starts at byte 44.
  ///
  /// Engines differ: some write a `LIST` or `fact` chunk before `data`, and
  /// assuming a fixed offset there yields a file that decodes into a click.
  /// Handles 16-bit PCM and 32-bit float, which are the two things a speech API
  /// returns, and refuses anything else by name.
  static WavData decode(Uint8List bytes) {
    if (bytes.length < _headerBytes) {
      throw const FormatException('not a WAV file: too short');
    }
    final ByteData view = ByteData.sublistView(bytes);

    String tag(int offset) => String.fromCharCodes(
          bytes.sublist(offset, offset + 4),
        );

    if (tag(0) != 'RIFF' || tag(8) != 'WAVE') {
      throw const FormatException('not a WAV file: missing RIFF/WAVE header');
    }

    int? sampleRateHz;
    int? channels;
    int? format;
    int? bitsPerSample;
    int offset = 12;

    while (offset + 8 <= bytes.length) {
      final String id = tag(offset);
      final int size = view.getUint32(offset + 4, Endian.little);
      final int body = offset + 8;
      if (size < 0 || body + size > bytes.length) {
        // A truncated final chunk is common in a streamed response. Use what
        // arrived rather than rejecting the whole file.
        break;
      }

      if (id == 'fmt ') {
        format = view.getUint16(body, Endian.little);
        channels = view.getUint16(body + 2, Endian.little);
        sampleRateHz = view.getUint32(body + 4, Endian.little);
        bitsPerSample = view.getUint16(body + 14, Endian.little);
        // WAVE_FORMAT_EXTENSIBLE: the real format lives in the sub-format GUID,
        // whose first two bytes repeat the format tag.
        if (format == 0xFFFE && size >= 40) {
          format = view.getUint16(body + 24, Endian.little);
        }
      } else if (id == 'data') {
        if (sampleRateHz == null) {
          throw const FormatException('WAV data chunk before the format chunk');
        }
        return WavData(
          samples: _readSamples(
            bytes,
            body,
            size,
            format: format ?? 1,
            bitsPerSample: bitsPerSample ?? 16,
            channels: channels ?? 1,
          ),
          sampleRateHz: sampleRateHz,
        );
      }

      // Chunks are word aligned.
      offset = body + size + (size.isOdd ? 1 : 0);
    }

    throw const FormatException('WAV file has no data chunk');
  }

  static Int16List _readSamples(
    Uint8List bytes,
    int start,
    int size, {
    required int format,
    required int bitsPerSample,
    required int channels,
  }) {
    final ByteData view = ByteData.sublistView(bytes, start, start + size);

    // Down-mixing: the app is mono throughout, and a stereo voice played as
    // mono would run at double speed.
    if (format == 3 && bitsPerSample == 32) {
      final int frames = size ~/ 4 ~/ channels;
      final Int16List out = Int16List(frames);
      for (int i = 0; i < frames; i++) {
        double sum = 0;
        for (int c = 0; c < channels; c++) {
          sum += view.getFloat32((i * channels + c) * 4, Endian.little);
        }
        final double sample = (sum / channels).clamp(-1.0, 1.0);
        out[i] = (sample * 32767).round();
      }
      return out;
    }

    if (format == 1 && bitsPerSample == 16) {
      final int frames = size ~/ 2 ~/ channels;
      final Int16List out = Int16List(frames);
      for (int i = 0; i < frames; i++) {
        if (channels == 1) {
          out[i] = view.getInt16(i * 2, Endian.little);
        } else {
          int sum = 0;
          for (int c = 0; c < channels; c++) {
            sum += view.getInt16((i * channels + c) * 2, Endian.little);
          }
          out[i] = sum ~/ channels;
        }
      }
      return out;
    }

    throw FormatException(
      'unsupported WAV format: $format with $bitsPerSample bits per sample. '
      'This app handles 16-bit PCM and 32-bit float.',
    );
  }
}
