// Compliance gate for questionnaire routing.
//
// Replaces the retired `collection_availability_test.dart`, which exercised an
// orphaned hold page that was never wired into the route table. The gate itself
// is now the authority: a live build must never resolve the synthetic demo
// question bank as though it were an approved customer instrument.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fyp/core/di/app_providers.dart';
import 'package:fyp/core/config/mobile_config.dart';
import 'package:fyp/features/assessment/domain/entities/assessment.dart';
import 'package:fyp/features/assessment/domain/entities/assessment_draft.dart';
import 'package:fyp/features/assessment/data/datasources/demo_questionnaire_routing_service.dart';
import 'package:fyp/features/assessment/domain/services/questionnaire_routing_service.dart';
import 'package:fyp/features/assessment/data/datasources/questionnaire_routing_service.dart';

void main() {
  tearDown(() => MobileConfig.overrideUsesLiveApi = null);

  AssessmentDraft draft() => AssessmentDraft.start(demoAssessmentOffers.first);

  test('held service never exposes questions', () {
    expect(const HeldQuestionnaireRoutingService().resolve(draft()), isEmpty);
  });

  test('live build resolves the held routing service', () {
    MobileConfig.overrideUsesLiveApi = true;
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final service = container.read(questionnaireRoutingServiceProvider);
    expect(service, isA<HeldQuestionnaireRoutingService>());
    expect(service.resolve(draft()), isEmpty);
  });

  test('non-live build also withholds the demo bank', () {
    MobileConfig.overrideUsesLiveApi = false;
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final service = container.read(questionnaireRoutingServiceProvider);
    expect(service, isA<HeldQuestionnaireRoutingService>());
    expect(service.resolve(draft()), isEmpty);
  });

  test('historical fixtures require an explicit test override', () {
    final container = ProviderContainer(
      overrides: [
        questionnaireRoutingServiceProvider.overrideWithValue(
          const DemoQuestionnaireRoutingService(),
        ),
      ],
    );
    addTearDown(container.dispose);
    expect(
      container.read(questionnaireRoutingServiceProvider).resolve(draft()),
      isNotEmpty,
    );
  });

  test('the demo bank is never reachable from the live branch', () {
    MobileConfig.overrideUsesLiveApi = true;
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final service = container.read(questionnaireRoutingServiceProvider);
    expect(service, isNot(isA<DemoQuestionnaireRoutingService>()));
  });
}
