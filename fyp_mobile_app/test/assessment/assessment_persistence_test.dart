import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:fyp/features/assessment/model/entities/assessment.dart';
import 'package:fyp/features/assessment/model/entities/assessment_draft.dart';
import 'package:fyp/features/assessment/model/repository/assessment_repository.dart';
import 'package:fyp/features/assessment/model/service/assessment_local_service.dart';
import 'package:fyp/features/assessment/model/service/questionnaire_routing_service.dart';
import 'package:fyp/features/assessment/viewmodel/assessment_view_model.dart';

void main() {
  late Directory directory;
  late String databasePath;
  late SqliteAssessmentLocalService service;
  late AssessmentViewModel vm;

  SqliteAssessmentLocalService storage() => SqliteAssessmentLocalService(
    factory: databaseFactoryFfi,
    databasePath: databasePath,
  );
  AssessmentViewModel viewModel(AssessmentLocalService local) =>
      AssessmentViewModel(
        repository: AssessmentRepository(localService: local),
        routingService: const DemoQuestionnaireRoutingService(),
      );

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sitewise-draft-test-');
    databasePath = p.join(directory.path, 'drafts.db');
    service = storage();
    vm = viewModel(service);
    await vm.load();
  });
  tearDown(() async {
    vm.dispose();
    await service.close();
    await directory.delete(recursive: true);
  });

  test(
    'SQLite survives close/reopen with language, cursor and separate drafts',
    () async {
      final id = demoAssessmentOffers.first.id;
      await vm.startOrResume(demoAssessmentOffers.first);
      await vm.setConsent(id, true);
      await Future.wait([
        vm.selectAnswer(id, 'Q04', 'DEMO_Q04_0'),
        vm.setLanguage(id, 'bm'),
        vm.moveCursor(id, 'Q05'),
      ]);
      await vm.pauseActive();
      await vm.startOrResume(demoAssessmentOffers.last);
      vm.dispose();
      await service.close();
      service = storage();
      vm = viewModel(service);
      await vm.load();
      final draft = vm.getDraft(id)!;
      expect(draft.answerCodes, {'Q04': 'DEMO_Q04_0'});
      expect(draft.language, 'bm');
      expect(draft.currentQuestionId, 'Q05');
      expect(draft.consentGiven, isTrue);
      expect(draft.status, DraftStatus.paused);
      expect(vm.getDraft(demoAssessmentOffers.last.id)!.answerCodes, isEmpty);
      await vm.resume(id);
      expect(vm.getDraft(id)!.status, DraftStatus.inProgress);
    },
  );

  test(
    'stale SQLite write is rejected without losing the newer draft',
    () async {
      final fresh = AssessmentDraft.start(demoAssessmentOffers.first);
      await service.saveDraft(fresh);
      final updated = fresh.withChanges(language: 'bm');
      await service.saveDraft(updated);
      await expectLater(
        service.saveDraft(fresh.withChanges(consentGiven: true)),
        throwsStateError,
      );
      expect((await service.loadDrafts()).single.toJson(), updated.toJson());
    },
  );

  test(
    'damaged SQLite row fails visibly and remains available for recovery',
    () async {
      final fresh = AssessmentDraft.start(demoAssessmentOffers.first);
      await service.saveDraft(fresh);
      final db = await databaseFactoryFfi.openDatabase(databasePath);
      await db.update(
        'assessment_drafts',
        {'payload': '{broken'},
        where: 'id = ?',
        whereArgs: [fresh.id],
      );
      await expectLater(service.loadDrafts(), throwsFormatException);
      expect(
        (await db.query('assessment_drafts')).single['payload'],
        '{broken',
      );
    },
  );

  test(
    'missing consent, invalid option and incomplete preview cannot complete',
    () async {
      final id = demoAssessmentOffers.first.id;
      await vm.startOrResume(demoAssessmentOffers.first);
      await expectLater(
        vm.selectAnswer(id, 'Q04', 'DEMO_Q04_0'),
        throwsStateError,
      );
      await vm.setConsent(id, true);
      await expectLater(
        vm.selectAnswer(id, 'Q04', 'INVALID'),
        throwsStateError,
      );
      await expectLater(vm.completePreview(id), throwsStateError);
      for (final q in vm.routeFor(vm.getDraft(id)!)) {
        await vm.selectAnswer(id, q.id, q.options.first.code);
      }
      await vm.completePreview(id);
      final revision = vm.getDraft(id)!.revision;
      await vm.completePreview(id);
      expect(vm.getDraft(id)!.revision, revision);
      expect(
        (await service.loadDrafts()).single.status,
        DraftStatus.previewCompleted,
      );
      await expectLater(vm.resume(id), throwsStateError);
    },
  );

  test(
    'failed save leaves displayed answer unchanged and a retry succeeds',
    () async {
      final failing = _FailingStorage(service);
      vm.dispose();
      vm = viewModel(failing);
      await vm.load();
      final id = demoAssessmentOffers.first.id;
      await vm.startOrResume(demoAssessmentOffers.first);
      await vm.setConsent(id, true);
      failing.fail = true;
      await expectLater(
        vm.selectAnswer(id, 'Q04', 'DEMO_Q04_0'),
        throwsStateError,
      );
      expect(vm.getDraft(id)!.answerCodes, isEmpty);
      await expectLater(vm.pauseActive(), throwsStateError);
      expect(vm.activeAssessmentId, id);
      failing.fail = false;
      await vm.selectAnswer(id, 'Q04', 'DEMO_Q04_0');
      await vm.pauseActive();
      expect(vm.getDraft(id)!.status, DraftStatus.paused);
    },
  );
}

class _FailingStorage implements AssessmentLocalService {
  _FailingStorage(this.inner);
  final AssessmentLocalService inner;
  bool fail = false;
  @override
  Future<List<AssessmentDraft>> loadDrafts() => inner.loadDrafts();
  @override
  Future<void> saveDraft(AssessmentDraft draft) {
    if (fail) throw StateError('Simulated disk failure');
    return inner.saveDraft(draft);
  }

  @override
  Future<void> close() => inner.close();
}
