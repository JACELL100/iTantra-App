import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// SQLite schema and migrations.
///
/// A local database rather than a file of JSON, because the transcript must
/// survive a crash mid-message and because latency samples are queried by
/// percentile during a demo. Write-ahead logging is enabled so a write from
/// the receive path never blocks a read from the UI - a stalled list while a
/// distress message arrives would be unforgivable.
class ItantraDatabase {
  ItantraDatabase._(this.db);

  final Database db;

  static const String fileName = 'itantra.db';
  static const int schemaVersion = 2;

  static Future<ItantraDatabase> open({String? directory}) async {
    final String base = directory ?? await getDatabasesPath();
    final Database database = await openDatabase(
      p.join(base, fileName),
      version: schemaVersion,
      onConfigure: (Database db) async {
        await db.execute('PRAGMA journal_mode = WAL');
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (Database db, int version) async {
        await _createV1(db);
        await _upgradeToV2(db);
      },
      onUpgrade: (Database db, int from, int to) async {
        if (from < 2) await _upgradeToV2(db);
      },
    );
    return ItantraDatabase._(database);
  }

  static Future<void> _createV1(Database db) async {
    await db.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        direction TEXT NOT NULL,
        language_tag TEXT NOT NULL,
        text TEXT NOT NULL,
        created_at_ms INTEGER NOT NULL,
        state TEXT NOT NULL,
        confidence REAL NOT NULL DEFAULT 1.0,
        is_alert INTEGER NOT NULL DEFAULT 0,
        severity TEXT,
        peer_id TEXT,
        latency_ms REAL
      )
    ''');

    // The transcript is always read newest-first, and alerts are filtered
    // out separately for the alert log.
    await db.execute(
        'CREATE INDEX idx_messages_created ON messages (created_at_ms DESC)');
    await db.execute(
        'CREATE INDEX idx_messages_alert ON messages (is_alert, created_at_ms DESC)');

    await db.execute('''
      CREATE TABLE peers (
        id TEXT PRIMARY KEY,
        label TEXT NOT NULL,
        transport TEXT NOT NULL,
        address TEXT NOT NULL,
        last_seen_ms INTEGER NOT NULL,
        tts_languages TEXT
      )
    ''');
  }

  /// v2 adds durable latency samples so a benchmark run survives a restart.
  static Future<void> _upgradeToV2(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS latency_samples (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        metric TEXT NOT NULL,
        value_ms REAL NOT NULL,
        recorded_at_ms INTEGER NOT NULL,
        message_id TEXT
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_latency_metric ON latency_samples (metric)');
  }

  Future<void> close() => db.close();
}
