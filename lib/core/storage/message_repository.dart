import 'package:sqflite/sqflite.dart';

import '../metrics/metrics.dart';
import 'database.dart';
import 'entities.dart';

/// All reads and writes of the transcript.
///
/// A repository rather than raw sqflite calls scattered through the session
/// and the UI: the SQL lives in one place, and the session controller stays
/// readable as a sequence of steps rather than a sequence of queries.
class MessageRepository {
  MessageRepository(this._database);

  final ItantraDatabase _database;

  Database get _db => _database.db;

  /// Upsert rather than insert, because a message id can legitimately be
  /// written twice: once when recognition finishes and again if a retry
  /// re-sends the same utterance.
  Future<void> insert(StoredMessage message) async {
    await _db.insert(
      'messages',
      message.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Stores a message that arrived from the peer and returns the stored row,
  /// so the caller can hand it straight to the UI without a second read.
  Future<StoredMessage> insertIncoming({
    required String id,
    required String languageTag,
    required String text,
    required bool isAlert,
    String? severity,
    String? peerId,
    double confidence = 1.0,
    String? originalText,
    String? originalLanguageTag,
    String? translatedText,
    String? targetLanguageTag,
  }) async {
    final StoredMessage message = StoredMessage(
      id: id,
      direction: MessageDirection.incoming,
      languageTag: languageTag,
      text: text,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      state: DeliveryState.delivered,
      confidence: confidence,
      isAlert: isAlert,
      severity: severity,
      peerId: peerId,
      originalText: originalText,
      originalLanguageTag: originalLanguageTag,
      translatedText: translatedText,
      targetLanguageTag: targetLanguageTag,
    );
    await insert(message);
    return message;
  }

  Future<void> updateState(String id, DeliveryState state) async {
    await _db.update(
      'messages',
      <String, Object?>{'state': state.name},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// Attaches an end-to-end latency to a message, for the transcript's
  /// per-message timing badge.
  Future<void> recordLatency(String id, double latencyMs) async {
    await _db.update(
      'messages',
      <String, Object?>{'latency_ms': latencyMs},
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// Durable latency samples.
  ///
  /// Kept in the database as well as in memory because the scored metrics
  /// have to survive the app being killed between a benchmark run and the
  /// moment someone reads the numbers off the diagnostics screen.
  Future<void> recordLatencySample(
    String metric,
    double valueMs, {
    String? messageId,
  }) async {
    await _db.insert('latency_samples', <String, Object?>{
      'metric': metric,
      'value_ms': valueMs,
      'recorded_at_ms': DateTime.now().millisecondsSinceEpoch,
      'message_id': messageId,
    });
    if (messageId != null && metric == 'delta_ms') {
      await recordLatency(messageId, valueMs);
    }
  }

  /// Newest first, which is the order the transcript renders in.
  Future<List<StoredMessage>> recent({int limit = 200}) async {
    final List<Map<String, Object?>> rows = await _db.query(
      'messages',
      orderBy: 'created_at_ms DESC',
      limit: limit,
    );
    return rows.map(StoredMessage.fromRow).toList(growable: false);
  }

  Future<StoredMessage?> byId(String id) async {
    final List<Map<String, Object?>> rows = await _db.query(
      'messages',
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    return rows.isEmpty ? null : StoredMessage.fromRow(rows.first);
  }

  Future<List<StoredMessage>> alerts({int limit = 50}) async {
    final List<Map<String, Object?>> rows = await _db.query(
      'messages',
      where: 'is_alert = 1',
      orderBy: 'created_at_ms DESC',
      limit: limit,
    );
    return rows.map(StoredMessage.fromRow).toList(growable: false);
  }

  /// Percentiles over the stored samples for one metric.
  ///
  /// Computed in Dart rather than SQL: SQLite has no percentile function
  /// without an extension, and these sample counts are in the hundreds.
  Future<LatencySummary> percentiles(String metric) async {
    final List<Map<String, Object?>> rows = await _db.query(
      'latency_samples',
      columns: <String>['value_ms'],
      where: 'metric = ?',
      whereArgs: <Object?>[metric],
      orderBy: 'value_ms ASC',
    );
    if (rows.isEmpty) return const LatencySummary(count: 0, p50: 0, p95: 0);

    final List<double> values = rows
        .map((Map<String, Object?> row) =>
            (row['value_ms'] as num).toDouble())
        .toList(growable: false);

    double at(double fraction) {
      final int index =
          ((values.length - 1) * fraction).round().clamp(0, values.length - 1);
      return values[index];
    }

    return LatencySummary(
      count: values.length,
      p50: at(0.50),
      p95: at(0.95),
    );
  }

  /// Metrics that actually have samples, so the diagnostics screen shows
  /// only rows it can fill.
  Future<List<String>> recordedMetrics() async {
    final List<Map<String, Object?>> rows = await _db.rawQuery(
        'SELECT DISTINCT metric FROM latency_samples ORDER BY metric');
    return rows
        .map((Map<String, Object?> row) => row['metric']! as String)
        .toList(growable: false);
  }

  Future<void> upsertPeer(StoredPeer peer) async {
    await _db.insert(
      'peers',
      peer.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<StoredPeer>> peers() async {
    final List<Map<String, Object?>> rows =
        await _db.query('peers', orderBy: 'last_seen_ms DESC');
    return rows.map(StoredPeer.fromRow).toList(growable: false);
  }

  /// The most recently seen peer, offered as a one-tap reconnect.
  Future<StoredPeer?> lastPeer() async {
    final List<Map<String, Object?>> rows = await _db.query(
      'peers',
      orderBy: 'last_seen_ms DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : StoredPeer.fromRow(rows.first);
  }

  /// Clears the transcript and the samples but keeps paired peers, which is
  /// what "clear history" means to a user who still wants their radio to
  /// reconnect.
  Future<void> clear() async {
    await _db.delete('messages');
    await _db.delete('latency_samples');
  }
}
