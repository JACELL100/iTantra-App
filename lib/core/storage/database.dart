import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../util/log.dart';

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
    final String path = p.join(base, fileName);

    try {
      return ItantraDatabase._(await _openAt(path));
    } on DatabaseException catch (error) {
      // A database left half-written by a battery pull or a killed process
      // cannot be repaired from here, and leaving it in place would brick the
      // app on every subsequent launch - the single worst failure mode for
      // something meant to be relied on in an emergency. It is moved aside
      // rather than deleted, so a transcript can still be recovered by hand,
      // and the app starts with an empty one.
      ItLog.e('db', 'open failed; quarantining the file', error);
      await _quarantine(path);
      return ItantraDatabase._(await _openAt(path));
    }
  }

  static Future<Database> _openAt(String path) => openDatabase(
        path,
        version: schemaVersion,
        onConfigure: (Database db) async {
          // Both of these return a row, and sqflite's execute() refuses any
          // statement that does. Running them through execute threw inside
          // onConfigure, which aborted the whole open and left the app with no
          // transcript at all - the pragmas are a tuning choice, and must never
          // be able to stop the app from storing a message.
          await _pragma(db, 'PRAGMA journal_mode = WAL');
          await _pragma(db, 'PRAGMA foreign_keys = ON');
        },
        onCreate: (Database db, int version) async {
          await _createV1(db);
          await _upgradeToV2(db);
        },
        onUpgrade: (Database db, int from, int to) async {
          if (from < 2) await _upgradeToV2(db);
        },
        // A build with an older schema is a downgrade, which happens when
        // someone reinstalls a previous APK. Recreating is correct here because
        // the newer schema is a superset, and reading it with older code is
        // not something this app attempts.
        onDowngrade: onDatabaseDowngradeDelete,
      );

  static Future<void> _pragma(Database db, String statement) async {
    try {
      await db.rawQuery(statement);
    } on DatabaseException catch (error) {
      ItLog.w('db', '$statement was refused: ${error.toString()}');
    }
  }

  static Future<void> _quarantine(String path) async {
    try {
      final File file = File(path);
      if (!file.existsSync()) return;
      final String stamp = DateTime.now().millisecondsSinceEpoch.toString();
      file.renameSync('$path.corrupt-$stamp');
      // The write-ahead log and shared-memory files belong to the old database
      // and would confuse the newly created one.
      for (final String suffix in <String>['-wal', '-shm']) {
        final File side = File('$path$suffix');
        if (side.existsSync()) side.deleteSync();
      }
    } on FileSystemException catch (error) {
      ItLog.e('db', 'could not quarantine the old database', error);
    }
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
