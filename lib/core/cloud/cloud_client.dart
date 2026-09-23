import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../util/log.dart';
import 'cloud_speech_config.dart';

/// A cloud request that failed, with enough detail to tell the user what to do.
class CloudSpeechException implements Exception {
  const CloudSpeechException(
    this.message, {
    this.isAuthFailure = false,
    this.isRateLimited = false,
    this.isUnreachable = false,
  });

  final String message;

  /// The key is wrong, missing or revoked. Retrying cannot help; the user has
  /// to fix the configuration.
  final bool isAuthFailure;

  /// The provider is throttling. Worth retrying, unlike the other two.
  final bool isRateLimited;

  /// No route to the provider at all. Distinct from a 5xx: this one means the
  /// phone is offline or the base URL is wrong.
  final bool isUnreachable;

  @override
  String toString() => message;
}

/// A thin HTTP client for the two speech endpoints.
///
/// Reads the configuration through a callback rather than holding a snapshot,
/// so a key entered in settings takes effect on the next utterance without
/// rebuilding the engine graph.
class CloudClient {
  CloudClient({required CloudSpeechConfig Function() config}) : _config = config;

  final CloudSpeechConfig Function() _config;

  CloudSpeechConfig get config => _config();

  /// POSTs a JSON body and returns the decoded response.
  Future<Map<String, Object?>> postJson(
    Uri uri,
    Map<String, Object?> body,
  ) async {
    final Uint8List bytes = await _request(uri, (HttpClientRequest request) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    });

    final String text = utf8.decode(bytes, allowMalformed: true);
    if (text.isEmpty) return const <String, Object?>{};
    try {
      final Object? parsed = jsonDecode(text);
      return parsed is Map<String, Object?>
          ? parsed
          : <String, Object?>{'data': parsed};
    } on FormatException {
      throw CloudSpeechException(
        'the provider returned a response this app could not read: '
        '${_truncate(text)}',
      );
    }
  }

  /// POSTs a JSON body and returns the raw response body. Used for synthesis,
  /// where the response is audio rather than JSON.
  Future<Uint8List> postJsonForBytes(
    Uri uri,
    Map<String, Object?> body,
  ) =>
      _request(uri, (HttpClientRequest request) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      });

  /// POSTs a multipart form with one file part.
  ///
  /// Hand-built rather than via a package: the app's dependency list is held to
  /// permissively licensed, network-free libraries, and a multipart body is
  /// forty lines of fully specified format.
  Future<Map<String, Object?>> postAudio(
    Uri uri, {
    required Uint8List audio,
    required String filename,
    Map<String, String> fields = const <String, String>{},
  }) async {
    final String boundary =
        '----iTantra${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
    final Uint8List responseBytes =
        await _request(uri, (HttpClientRequest request) {
      request.headers.contentType =
          ContentType('multipart', 'form-data', parameters: <String, String>{
        'boundary': boundary,
      });
      request.add(_multipartBody(
        boundary: boundary,
        audio: audio,
        filename: filename,
        fields: fields,
      ));
    });

    final String text = utf8.decode(responseBytes, allowMalformed: true);
    try {
      final Object? parsed = jsonDecode(text);
      if (parsed is Map<String, Object?>) return parsed;
      throw CloudSpeechException(
        'the provider returned ${parsed.runtimeType} where an object was '
        'expected: ${_truncate(text)}',
      );
    } on FormatException {
      throw CloudSpeechException(
        'the provider returned a response this app could not read: '
        '${_truncate(text)}',
      );
    }
  }

  /// Opens the request, applies auth, reads the whole body, and turns every
  /// failure mode into something a person can act on.
  ///
  /// The body is drained before the client is closed. Returning the open
  /// response and closing the client in a `finally` - which is the obvious
  /// shape - kills the connection the caller is still reading from, so the
  /// transcript comes back empty and the failure looks like a provider bug.
  Future<Uint8List> _request(
    Uri uri,
    void Function(HttpClientRequest request) write,
  ) async {
    final CloudSpeechConfig speech = config;
    if (!speech.hasBaseUrl) {
      throw const CloudSpeechException(
        'no cloud endpoint is configured. Add one in Settings, under Cloud '
        'speech.',
      );
    }
    if (!speech.hasKey) {
      throw const CloudSpeechException(
        'no API key is configured for the cloud endpoint.',
        isAuthFailure: true,
      );
    }

    final HttpClient client = HttpClient()
      ..connectionTimeout = Duration(seconds: speech.timeoutSeconds)
      ..userAgent = 'iTantra/1.0';

    try {
      final HttpClientRequest request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${speech.apiKey}');
      request.headers.set(HttpHeaders.acceptHeader, '*/*');
      write(request);
      final HttpClientResponse response = await request.close().timeout(
            Duration(seconds: speech.timeoutSeconds),
          );

      final Uint8List bytes = await _readBytes(response);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return bytes;
      }

      final String body = utf8.decode(bytes, allowMalformed: true);
      ItLog.w('cloud',
          '${uri.path} answered ${response.statusCode}: ${_truncate(body)}');
      throw _classify(response.statusCode, body, uri);
    } on SocketException catch (error) {
      throw CloudSpeechException(
        'could not reach ${uri.host}: ${error.osError?.message ?? error.message}',
        isUnreachable: true,
      );
    } on HandshakeException catch (error) {
      throw CloudSpeechException(
        'the secure connection to ${uri.host} failed: ${error.message}',
        isUnreachable: true,
      );
    } on TimeoutException {
      throw CloudSpeechException(
        '${uri.host} did not answer within ${speech.timeoutSeconds} seconds.',
        isUnreachable: true,
      );
    } finally {
      client.close(force: true);
    }
  }

  CloudSpeechException _classify(int status, String body, Uri uri) {
    final String detail = _extractMessage(body);
    return switch (status) {
      401 || 403 => CloudSpeechException(
          '${uri.host} rejected the API key${detail.isEmpty ? '' : ': $detail'}',
          isAuthFailure: true,
        ),
      402 => CloudSpeechException(
          '${uri.host} reports the account has no credit left'
          '${detail.isEmpty ? '' : ': $detail'}',
          isAuthFailure: true,
        ),
      404 => CloudSpeechException(
          '${uri.host} has no endpoint at ${uri.path}. Check the base URL - it '
          'usually ends in /v1.',
        ),
      413 => const CloudSpeechException(
          'the recording was too large for the provider to accept.',
        ),
      429 => CloudSpeechException(
          '${uri.host} is rate limiting this key'
          '${detail.isEmpty ? '' : ': $detail'}',
          isRateLimited: true,
        ),
      _ => CloudSpeechException(
          '${uri.host} answered $status${detail.isEmpty ? '' : ': $detail'}',
        ),
    };
  }

  /// Pulls the human-readable part out of a provider error body, which the
  /// OpenAI shape puts under `error.message`.
  static String _extractMessage(String body) {
    if (body.isEmpty) return '';
    try {
      final Object? parsed = jsonDecode(body);
      if (parsed is Map) {
        final Object? error = parsed['error'];
        if (error is Map && error['message'] is String) {
          return _truncate(error['message'] as String, 240);
        }
        if (error is String) return _truncate(error, 240);
        if (parsed['message'] is String) {
          return _truncate(parsed['message'] as String, 240);
        }
      }
    } on FormatException {
      // Not JSON; fall through to the raw text.
    }
    return _truncate(body, 240);
  }

  static Uint8List _multipartBody({
    required String boundary,
    required Uint8List audio,
    required String filename,
    required Map<String, String> fields,
  }) {
    final BytesBuilder builder = BytesBuilder(copy: false);

    void writeString(String value) => builder.add(utf8.encode(value));

    for (final MapEntry<String, String> entry in fields.entries) {
      writeString('--$boundary\r\n');
      writeString(
        'Content-Disposition: form-data; name="${entry.key}"\r\n\r\n',
      );
      writeString('${entry.value}\r\n');
    }

    writeString('--$boundary\r\n');
    writeString(
      'Content-Disposition: form-data; name="file"; filename="$filename"\r\n',
    );
    writeString('Content-Type: audio/wav\r\n\r\n');
    builder.add(audio);
    writeString('\r\n--$boundary--\r\n');

    return builder.takeBytes();
  }

  static Future<Uint8List> _readBytes(HttpClientResponse response) async {
    final BytesBuilder builder = BytesBuilder(copy: false);
    try {
      await for (final List<int> chunk in response) {
        builder.add(chunk);
      }
    } on Object catch (error) {
      throw CloudSpeechException('the response could not be read: $error');
    }
    return builder.takeBytes();
  }

  static String _truncate(String value, [int limit = 400]) =>
      value.length <= limit ? value : '${value.substring(0, limit)}…';
}
