import 'dart:convert';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../entities/assessment_draft.dart';

abstract class AssessmentLocalService {
  Future<List<AssessmentDraft>> loadDrafts();
  Future<void> saveDraft(AssessmentDraft draft);
  Future<void> close();
}

class SqliteAssessmentLocalService implements AssessmentLocalService {
  SqliteAssessmentLocalService({this.factory, this.databasePath});

  final DatabaseFactory? factory;
  final String? databasePath;
  Future<Database>? _opening;
  bool _closed = false;

  Future<Database> get _database async {
    if (_closed) throw StateError('Draft storage is closed.');
    final opening = _opening ??= _open();
    try {
      return await opening;
    } catch (_) {
      // A transient platform/open failure must not poison every later retry.
      if (identical(_opening, opening)) _opening = null;
      rethrow;
    }
  }

  Future<Database> _open() async {
    final selectedFactory = factory ?? databaseFactory;
    final file =
        databasePath ??
        p.join(
          await selectedFactory.getDatabasesPath(),
          'project1_demo_drafts.db',
        );
    return selectedFactory.openDatabase(
      file,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute("""
        CREATE TABLE assessment_drafts (
          id TEXT PRIMARY KEY,
          revision INTEGER NOT NULL,
          payload TEXT NOT NULL,
          saved_at TEXT NOT NULL
        )
      """);
        },
      ),
    );
  }

  @override
  Future<List<AssessmentDraft>> loadDrafts() async {
    final db = await _database;
    final rows = await db.query('assessment_drafts', orderBy: 'saved_at DESC');
    // Any damaged row fails visibly; do NOT silently delete or reset it.
    return rows
        .map((row) {
          final data =
              jsonDecode(row['payload'] as String) as Map<String, dynamic>;
          final draft = AssessmentDraft.fromJson(data);
          if (draft.id != row['id'] || draft.revision != row['revision']) {
            throw FormatException(
              'Revision mismatch for saved draft ${draft.id}.',
            );
          }
          return draft;
        })
        .toList(growable: false);
  }

  @override
  Future<void> saveDraft(AssessmentDraft draft) async {
    final db = await _database;
    await db.transaction((tx) async {
      final rows = await tx.query(
        'assessment_drafts',
        columns: ['revision'],
        where: 'id = ?',
        whereArgs: [draft.id],
        limit: 1,
      );
      if (rows.isEmpty) {
        if (draft.revision != 0) {
          throw StateError(
            'Draft was missing; refusing a stale or recovered write.',
          );
        }
        await tx.insert('assessment_drafts', {
          'id': draft.id,
          'revision': draft.revision,
          'payload': jsonEncode(draft.toJson()),
          'saved_at': draft.updatedAt.toIso8601String(),
        });
      } else {
        final oldRevision = rows.first['revision'] as int;
        if (draft.revision != oldRevision + 1) {
          throw StateError(
            'Concurrent draft change: expected ${oldRevision + 1}, got ${draft.revision}.',
          );
        }
        final count = await tx.update(
          'assessment_drafts',
          {
            'revision': draft.revision,
            'payload': jsonEncode(draft.toJson()),
            'saved_at': draft.updatedAt.toIso8601String(),
          },
          where: 'id = ? AND revision = ?',
          whereArgs: [draft.id, oldRevision],
        );
        if (count != 1) throw StateError('Draft was modified concurrently.');
      }
    });
  }

  @override
  Future<void> close() async {
    _closed = true;
    final opening = _opening;
    _opening = null;
    if (opening != null) await (await opening).close();
  }
}
