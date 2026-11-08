import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project1_customer_mobile/data/questionnaire_repository.dart';
import 'package:project1_customer_mobile/model/question.dart';
import 'package:project1_customer_mobile/model/questionnaire_state.dart';
import 'package:project1_customer_mobile/viewmodel/questionnaire_viewmodel.dart';

void main() {
  late ProviderContainer container;
  late QuestionnaireViewModel vm;
  QuestionnaireState state() => container.read(questionnaireProvider);
  void begin([DemoConfig config = const DemoConfig()]) {
    vm.configure(config);
    vm.setConsent(true);
    vm.start();
  }

  void answer(String code) {
    expect(vm.select(code), isTrue);
    vm.next();
  }

  void throughQ04([String q04 = 'ZERO']) {
    begin();
    answer('LIVE');
    answer('DAYS_4_10');
    answer('HOME');
    answer(q04);
    expect(state().currentId, 'Q05');
  }

  void complete([String q04 = 'ZERO']) {
    throughQ04(q04);
    answer('PROB_YES');
    answer('COFFEE_ESPRESSO');
    answer('SOMEWHAT_ACCEPTABLE');
    if (state().currentId == 'Q08') answer('SOCIAL');
    answer('SOCIAL');
    expect(state().currentId, 'Q10');
    for (final f in QuestionnaireRepository.features) {
      vm.rate(f.id, 'VERY_IMPORTANT');
    }
    vm.next();
    vm.skipOptional();
    vm.skipOptional();
    vm.skipOptional();
    expect(state().page, SurveyPage.review);
  }

  setUp(() {
    container = ProviderContainer();
    vm = container.read(questionnaireProvider.notifier);
  });
  tearDown(() => container.dispose());

  test('source response-code sets are preserved for all 13 identities', () {
    final source =
        jsonDecode(
              File(
                'docs/source_catalogue_excerpt.json',
              ).readAsStringSync().replaceFirst('\uFEFF', ''),
            )
            as List;
    final bank = state().bank;
    expect(bank.length, 13);
    for (final item in source) {
      final q = bank.singleWhere((q) => q.id == item['id']);
      expect(
        q.options.map((o) => o.code).toSet(),
        (item['codes'] as List).toSet(),
        reason: q.id,
      );
      expect(q.stem.en.isNotEmpty && q.stem.bm.isNotEmpty, isTrue);
      expect(
        q.options.every((o) => o.label.en.isNotEmpty && o.label.bm.isNotEmpty),
        isTrue,
      );
    }
  });
  test('consent gates start and submission is blocked before review', () {
    vm.start();
    expect(state().page, SurveyPage.welcome);
    expect(vm.submit(), isFalse);
    begin();
    expect(state().page, SurveyPage.question);
    expect(state().displayed, {'Q01'});
  });
  test('no answer cannot advance required item', () {
    begin();
    vm.next();
    expect(state().currentId, 'Q01');
    expect(state().error, isNotNull);
  });
  test('invalid response codes and matrix intents are rejected', () {
    begin();
    expect(vm.select('UNKNOWN'), isFalse);
    vm.rate('DEMO_WIFI', 'VERY_IMPORTANT');
    expect(state().answers, isEmpty);
  });
  test('all 512 Q01 subsets resolve without conflicting exclusive choices', () {
    final q = state().bank.first;
    for (var bits = 0; bits < 512; bits++) {
      vm.reset();
      begin();
      for (var i = 0; i < q.options.length; i++) {
        if ((bits & (1 << i)) != 0) vm.select(q.options[i].code);
      }
      final codes = state().answers['Q01']?.codes ?? <String>{};
      expect(
        !codes.any(q.exclusive.contains) || codes.length == 1,
        isTrue,
        reason: 'subset $bits',
      );
    }
  });
  test('affiliation and terminal choices clear one another', () {
    begin();
    vm.select('LIVE');
    vm.select('WORK');
    vm.select('NEVER');
    expect(state().answers['Q01']!.codes, {'NEVER'});
    expect(state().route.length, 2);
    vm.select('STUDY');
    expect(state().answers['Q01']!.codes, {'STUDY'});
    expect(state().route.length, 12);
  });
  for (final terminal in ['RARELY', 'NEVER', 'NOT_SURE']) {
    test(
      '$terminal uses short mock route with Q02 and truthful two-item review',
      () {
        begin();
        answer(terminal);
        expect(state().currentId, 'Q02');
        answer('PREFER_NOT_TO_ANSWER');
        expect(state().page, SurveyPage.review);
        expect(state().route.length, 2);
        expect(state().shownCount, 2);
        expect(state().answeredCount, 2);
        expect(state().canSubmit, isTrue);
      },
    );
  }
  for (final band in ['ZERO', 'CANNOT_REMEMBER', 'PREFER_NOT_TO_ANSWER']) {
    test('Q04 $band excludes Q08 but keeps Q09 future occasions', () {
      throughQ04(band);
      expect(state().route.any((q) => q.id == 'Q08'), isFalse);
      expect(state().route.any((q) => q.id == 'Q09'), isTrue);
    });
  }
  for (final band in ['ONE', 'TWO_THREE', 'FOUR_SEVEN', 'EIGHT_PLUS']) {
    test('Q04 $band includes Q08', () {
      throughQ04(band);
      expect(state().route.any((q) => q.id == 'Q08'), isTrue);
    });
  }
  test(
    'concept absence blocks stimulus-dependent questions, not past behavior',
    () {
      begin(const DemoConfig(concept: false));
      answer('LIVE');
      expect(state().route.map((q) => q.id), ['Q01', 'Q02', 'Q04', 'Q12']);
    },
  );
  test('individual fixture switches suppress only their modules', () {
    begin(
      const DemoConfig(
        menu: false,
        offer: false,
        occasions: false,
        features: false,
        optionalQuestions: false,
      ),
    );
    answer('LIVE');
    expect(state().route.map((q) => q.id), ['Q01', 'Q02', 'Q03', 'Q04', 'Q05']);
  });
  test('Q02 0 days does not invent another eligibility threshold', () {
    begin();
    answer('LIVE');
    answer('NONE');
    expect(state().currentId, 'Q03');
  });
  test('Q06 max three and exclusive clearing', () {
    throughQ04();
    answer('PROB_YES');
    vm.select('COFFEE_ESPRESSO');
    vm.select('NON_COFFEE');
    vm.select('LIGHT_MEALS');
    expect(vm.select('DESSERTS'), isFalse);
    expect(state().answers['Q06']!.codes.length, 3);
    vm.select('NONE');
    expect(state().answers['Q06']!.codes, {'NONE'});
    vm.select('DESSERTS');
    expect(state().answers['Q06']!.codes, {'DESSERTS'});
  });
  test(
    'matrix partial is incomplete; each synthetic feature needs its own answer',
    () {
      throughQ04();
      answer('PROB_YES');
      answer('NONE');
      answer('CANNOT_JUDGE');
      answer('NONE');
      expect(state().currentId, 'Q10');
      vm.rate('DEMO_SEATING', 'PREFER_NOT_TO_ANSWER');
      vm.next();
      expect(state().currentId, 'Q10');
      expect(state().isAnswered(state().current), isFalse);
      vm.rate('DEMO_WIFI', 'NOT_APPLICABLE');
      vm.rate('DEMO_TAKEAWAY', 'VERY_IMPORTANT');
      vm.next();
      expect(state().currentId, 'Q11');
    },
  );
  test(
    'optional skips remain empty; default ZERO route has 12 shown, 9 answers, 3 skips',
    () {
      complete();
      expect(state().shownCount, 12);
      expect(state().answeredCount, 9);
      expect(state().optionalSkippedCount, 3);
      expect(state().progress, 1);
      expect(state().answers.containsKey('Q11'), isFalse);
      expect(state().canSubmit, isTrue);
      expect(vm.submit(), isTrue);
      expect(state().page, SurveyPage.submitted);
      expect(vm.select('LIVE'), isFalse);
      expect(vm.submit(), isFalse);
    },
  );
  test('positive purchase full route shows 13 without claiming 13 answers', () {
    complete('ONE');
    expect(state().shownCount, 13);
    expect(state().answeredCount, 10);
    expect(state().optionalSkippedCount, 3);
  });
  test('Q04 edit clears excluded Q08 and does not restore stale answer', () {
    complete('ONE');
    vm.edit('Q04');
    vm.select('ZERO');
    vm.returnToReview();
    expect(state().answers.containsKey('Q08'), isFalse);
    expect(state().shownCount, 12);
    expect(state().removedExposureCount, 1);
    vm.edit('Q04');
    vm.select('ONE');
    vm.returnToReview();
    expect(state().answers.containsKey('Q08'), isFalse);
    expect(state().canSubmit, isFalse);
    expect(state().missingRequired.map((q) => q.id), contains('Q08'));
  });
  test(
    'Q01 edit prunes all hidden downstream answers and retains screen answers',
    () {
      complete();
      vm.edit('Q01');
      vm.select('NEVER');
      vm.returnToReview();
      expect(state().answers.keys.toSet(), {'Q01', 'Q02'});
      expect(state().shownCount, 2);
      expect(state().canSubmit, isTrue);
      expect(state().removedExposureCount, 10);
    },
  );
  test(
    'route expansion after review is blocked until unvisited required items answered',
    () {
      begin();
      answer('NEVER');
      answer('NONE');
      vm.edit('Q01');
      vm.select('LIVE');
      vm.returnToReview();
      expect(state().shownCount, 2);
      expect(state().route.length, 12);
      expect(state().canSubmit, isFalse);
      expect(vm.submit(), isFalse);
    },
  );
  test('optional skipped answer can be edited and counts recomputed', () {
    complete();
    vm.edit('Q12');
    vm.select('WALK');
    vm.returnToReview();
    expect(state().optionalSkippedCount, 2);
    expect(state().answeredCount, 10);
  });
  test('language toggle preserves codes and session navigation', () {
    throughQ04();
    final before = state();
    vm.setLanguage(AppLanguage.bm);
    expect(state().currentId, before.currentId);
    expect(state().answers, before.answers);
    expect(state().language, AppLanguage.bm);
  });
  test(
    'back to welcome and resume preserves exposure and answers; setup freezes after start',
    () {
      throughQ04();
      final shown = state().displayed;
      while (state().page != SurveyPage.welcome) {
        vm.previous();
      }
      vm.configure(const DemoConfig(concept: false));
      expect(state().config.concept, isTrue);
      vm.start();
      expect(state().displayed, shown);
      expect(state().answers['Q04']!.codes, {'ZERO'});
    },
  );
  test('reset clears consent, response and exposure history', () {
    complete();
    vm.reset();
    expect(state().consent, isFalse);
    expect(state().answers, isEmpty);
    expect(state().displayed, isEmpty);
    expect(state().skipped, isEmpty);
    expect(state().page, SurveyPage.welcome);
  });
  test('state and answer collections cannot be externally mutated', () {
    begin();
    vm.select('LIVE');
    expect(() => state().answers.clear(), throwsUnsupportedError);
    expect(
      () => state().answers['Q01']!.codes.add('NEVER'),
      throwsUnsupportedError,
    );
    expect(() => state().displayed.clear(), throwsUnsupportedError);
  });
}
