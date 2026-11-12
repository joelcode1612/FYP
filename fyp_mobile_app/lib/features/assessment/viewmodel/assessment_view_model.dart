import 'dart:async';
import 'package:flutter/foundation.dart';
import '../model/entities/assessment.dart';
import '../model/entities/assessment_draft.dart';
import '../model/entities/questionnaire_question.dart';
import '../model/repository/assessment_repository.dart';
import '../model/service/questionnaire_routing_service.dart';

/// One state owner: ChangeNotifier. Riverpod provides/watches the ViewModel.
class AssessmentViewModel extends ChangeNotifier {
  final AssessmentRepository repository;
  final QuestionnaireRoutingService routingService;
  final List<AssessmentOffer> availableOffers;
  AssessmentViewModel({required this.repository, required this.routingService,
    this.availableOffers = const []});

  final Map<String, AssessmentDraft> _drafts = {};
  Future<void> _writes = Future<void>.value();
  bool _loaded = false;
  bool loading = false;
  String? error;
  String? activeAssessmentId;

  bool get loaded => _loaded;
  AssessmentDraft? getDraft(String id) => _drafts[id];

  Future<T> _serial<T>(Future<T> Function() operation) {
    final task = _writes.then((_) => operation());
    _writes = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  Future<void> load() => _serial(() async {
    if (_loaded) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final drafts = await repository.loadDrafts();
      _drafts
        ..clear()
        ..addEntries(drafts.map((d) => MapEntry(d.id, d)));
      _loaded = true;
    } catch (e) {
      error = 'Saved drafts could not be read: $e';
      rethrow; // no silent deletion or reset
    } finally {
      loading = false;
      notifyListeners();
    }
  });

  AssessmentDraft _required(String id) {
    final d = _drafts[id];
    if (d == null) throw StateError('Draft not loaded: $id');
    return d;
  }

  Future<void> _commit(AssessmentDraft updated) async {
    await repository.saveDraft(updated);
    _drafts[updated.id] = updated; // UI changes only AFTER persistence
    notifyListeners();
  }

  Future<AssessmentDraft> startOrResume(
    AssessmentOffer offer,
  ) => _serial(() async {
    if (!_loaded) throw StateError('Load saved drafts first.');
    final existing = _drafts[offer.id];
    if (existing == null) {
      final fresh = AssessmentDraft.start(offer);
      await _commit(fresh);
      activeAssessmentId = offer.id;
      return fresh;
    }
    if (!existing.matches(offer)) {
      throw StateError(
        'Saved version mismatch. Manual reconciliation is required; draft preserved.',
      );
    }
    if (existing.status == DraftStatus.previewCompleted) return existing;
    final resumed = existing.status == DraftStatus.paused
        ? existing.withChanges(status: DraftStatus.inProgress)
        : existing;
    if (!identical(resumed, existing)) await _commit(resumed);
    activeAssessmentId = offer.id;
    return resumed;
  });

  Future<void> resume(String id) => _serial(() async {
    final existing = _required(id);
    if (existing.status == DraftStatus.previewCompleted) {
      throw StateError('This preview has already been completed.');
    }
    final offer = availableOffers.where((o) => o.id == id).firstOrNull;
    if (offer == null || !existing.matches(offer)) {
      throw StateError('Version mismatch. The draft has been preserved.');
    }
    if (existing.status == DraftStatus.paused) {
      await _commit(existing.withChanges(status: DraftStatus.inProgress));
    }
    activeAssessmentId = id;
  });

  Future<void> setConsent(String id, bool value) => _serial(() async {
    final d = _required(id);
    if (d.status != DraftStatus.inProgress) {
      throw StateError('Draft is not active.');
    }
    await _commit(d.withChanges(consentGiven: value));
  });

  Future<void> setLanguage(String id, String value) => _serial(() async {
    if (value != 'en' && value != 'bm') throw ArgumentError.value(value);
    final d = _required(id);
    if (d.status != DraftStatus.inProgress) {
      throw StateError('Draft is not active.');
    }
    if (d.language == value) return;
    await _commit(d.withChanges(language: value));
  });

  List<QuestionnaireQuestion> routeFor(AssessmentDraft draft) =>
      routingService.resolve(draft);

  int recordedCount(AssessmentDraft draft) {
    final route = routeFor(draft);
    return route.where((q) => draft.answerCodes.containsKey(q.id)).length;
  }

  double progress(AssessmentDraft draft) {
    final route = routeFor(draft);
    if (route.isEmpty) return 0;
    return recordedCount(draft) / route.length;
  }

  QuestionnaireQuestion? currentQuestion(AssessmentDraft draft) {
    final route = routeFor(draft);
    if (route.isEmpty) return null;
    final cursor = draft.currentQuestionId;
    for (final q in route) {
      if (q.id == cursor) return q;
    }
    for (final q in route) {
      if (!draft.answerCodes.containsKey(q.id)) return q;
    }
    return route.last;
  }

  Future<void> selectAnswer(
    String id,
    String questionId,
    String code,
  ) => _serial(() async {
    final d = _required(id);
    if (d.status != DraftStatus.inProgress || !d.consentGiven) {
      throw StateError('Active preview and consent are required.');
    }
    final q = routeFor(d).where((item) => item.id == questionId).firstOrNull;
    if (q == null || !q.options.any((o) => o.code == code)) {
      throw StateError('Option not in the resolved demonstration question.');
    }
    if (d.answerCodes[questionId] == code) return;
    await _commit(
      d.withChanges(
        currentQuestionId: questionId,
        answerCodes: {...d.answerCodes, questionId: code},
      ),
    );
  });

  Future<void> moveCursor(String id, String questionId) => _serial(() async {
    final d = _required(id);
    if (d.status != DraftStatus.inProgress) {
      throw StateError('Resume the draft first.');
    }
    if (!routeFor(d).any((q) => q.id == questionId)) {
      throw StateError('Question is no longer on the route.');
    }
    if (d.currentQuestionId == questionId) return;
    await _commit(d.withChanges(currentQuestionId: questionId));
  });

  Future<void> pause(String id) => _serial(() async {
    final d = _required(id);
    if (d.status == DraftStatus.inProgress) {
      await _commit(d.withChanges(status: DraftStatus.paused));
    }
    if (activeAssessmentId == id) activeAssessmentId = null;
  });

  Future<void> pauseActive() async {
    final id = activeAssessmentId;
    if (id == null) return;
    await pause(id);
  }

  Future<void> completePreview(String id) => _serial(() async {
    final d = _required(id);
    if (d.status == DraftStatus.previewCompleted) return; // idempotent
    if (d.status != DraftStatus.inProgress || !d.consentGiven) {
      throw StateError('Resume the preview and confirm demo consent first.');
    }
    final route = routeFor(d);
    if (route.isEmpty || route.any((q) => !d.answerCodes.containsKey(q.id))) {
      throw StateError('Please finish all applicable preview questions.');
    }
    await _commit(d.withChanges(status: DraftStatus.previewCompleted));
    if (activeAssessmentId == id) activeAssessmentId = null;
  });
}
