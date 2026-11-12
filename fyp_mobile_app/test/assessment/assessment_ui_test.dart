import 'package:fyp/features/assessment/viewmodel/assessment_view_model.dart';
import 'fixtures/questionnaire_fixtures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:fyp/application/providers.dart';
import 'package:fyp/core/routing/app_routes.dart';
import 'package:fyp/core/routing/auth_route_guard.dart';
import 'package:fyp/core/theme/sitewise_theme.dart';
import 'package:fyp/features/assessment/model/entities/assessment_draft.dart';
import 'package:fyp/features/assessment/model/service/assessment_local_service.dart';
import 'package:fyp/features/assessment/view/components/question_option_tile.dart';
import '../support/fake_auth_repository.dart';
import 'fixtures/preview_routes.dart';

void main() {
  late _MemoryStorage storage;
  setUp(() {
    storage = _MemoryStorage();
    AuthPendingDestination.clear();
  });
  tearDown(AuthPendingDestination.clear);

  Widget app({
    bool signedIn = true,
    String? initial,
    Object? arguments,
    double scale = 1,
  }) => ProviderScope(
    overrides: [
      ...sitewiseOverrides(
        auth: AuthService(
          FakeAuthRepository()..user = signedIn ? testUser() : null,
        ),
      ),
      assessmentLocalServiceProvider.overrideWithValue(storage),
      assessmentViewModelProvider.overrideWith((ref) => AssessmentViewModel(
        repository: ref.watch(assessmentRepositoryProvider),
        routingService: const DemoQuestionnaireRoutingService(),
        availableOffers: demoAssessmentOffers,
      )),
    ],
    child: MaterialApp(
      theme: sitewiseTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      onGenerateRoute: previewRoute,
      initialRoute: initial ?? AppRoutes.assessmentHome,
      onGenerateInitialRoutes: (route) => [
        previewRoute(
          RouteSettings(name: route, arguments: arguments),
        )!,
      ],
    ),
  );

  void surface(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isEmpty) {
      await tester.scrollUntilVisible(finder, 200);
    }
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'preview is protected and signed-out access never opens storage',
    (tester) async {
      surface(tester, const Size(390, 844));
      await tester.pumpWidget(app(signedIn: false));
      await tester.pumpAndSettle();
      expect(find.text('Welcome Back'), findsOneWidget);
      expect(storage.reads, 0);
    },
  );

  testWidgets(
    'small phone completes consent, both questions and review through isolated fixture routes',
    (tester) async {
      surface(tester, const Size(320, 568));
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('Start Assessment').first);
      await tapVisible(tester, find.text('Continue with demo consent'));
      expect(find.text('Step 1 of 2'), findsOneWidget);
      await tapVisible(tester, find.text('0 occasions'));
      await tapVisible(tester, find.text('Next  ›'));
      expect(find.text('Step 2 of 2'), findsOneWidget);
      expect(find.textContaining('FICTIONAL CAFÉ CONCEPT'), findsOneWidget);
      await tapVisible(tester, find.byType(QuestionOptionTile).first);
      await tapVisible(tester, find.text('Review'));
      await tapVisible(tester, find.text('Finish UI Preview'));
      expect(find.text('Preview completed'), findsOneWidget);
      expect(
        storage.drafts[demoAssessmentOffers.first.id]!.status,
        DraftStatus.previewCompleted,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cold question link reloads a paused draft and BM selection', (
    tester,
  ) async {
    surface(tester, const Size(390, 844));
    final draft = AssessmentDraft.start(demoAssessmentOffers.first).withChanges(
      status: DraftStatus.paused,
      consentGiven: true,
      language: 'bm',
      currentQuestionId: 'Q04',
      answerCodes: {'Q04': 'DEMO_Q04_0'},
    );
    storage.drafts[draft.id] = draft;
    await tester.pumpWidget(
      app(initial: AppRoutes.assessmentQuestionnaire, arguments: draft.id),
    );
    await tester.pumpAndSettle();
    expect(find.text('Paused'), findsOneWidget);
    await tapVisible(tester, find.text('Resume Assessment'));
    expect(find.text('0 kali'), findsOneWidget);
    final tile = tester.widget<QuestionOptionTile>(
      find.byType(QuestionOptionTile).first,
    );
    expect(tile.selected, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large text and landscape retain scrollable question controls', (
    tester,
  ) async {
    surface(tester, const Size(568, 320));
    final draft = AssessmentDraft.start(
      demoAssessmentOffers.first,
    ).withChanges(consentGiven: true);
    storage.drafts[draft.id] = draft;
    await tester.pumpWidget(
      app(
        initial: AppRoutes.assessmentQuestionnaire,
        arguments: draft.id,
        scale: 1.5,
      ),
    );
    await tester.pumpAndSettle();
    await tapVisible(tester, find.text('0 occasions'));
    await tapVisible(tester, find.text('Next  ›'));
    expect(find.text('Step 2 of 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('read error offers retry without deleting a stored draft', (
    tester,
  ) async {
    surface(tester, const Size(390, 844));
    final draft = AssessmentDraft.start(demoAssessmentOffers.first);
    storage.drafts[draft.id] = draft;
    storage.failRead = true;
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.textContaining('preserved'), findsOneWidget);
    storage.failRead = false;
    await tapVisible(tester, find.text('Retry'));
    expect(find.text('Resume Assessment'), findsOneWidget);
    expect(storage.drafts[draft.id], same(draft));
  });
}

class _MemoryStorage implements AssessmentLocalService {
  final drafts = <String, AssessmentDraft>{};
  int reads = 0;
  bool failRead = false;
  @override
  Future<List<AssessmentDraft>> loadDrafts() async {
    reads++;
    if (failRead) throw StateError('Simulated read failure');
    return drafts.values.toList();
  }

  @override
  Future<void> saveDraft(AssessmentDraft draft) async {
    drafts[draft.id] = draft;
  }

  @override
  Future<void> close() async {}
}
