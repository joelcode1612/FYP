import 'package:riverpod/riverpod.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:test/test.dart';

/// Behavioural tests for the M2 assessment ViewModel.
///
/// These pin the rules that were carried over from the Jaspr prototype's
/// `_M2PageState` (`_resetToSamples`, `_answered`, `_answeredCount`,
/// `_missingRequired`) so the port cannot silently drift from the web
/// behaviour. They also pin the two things the web page left implicit:
/// actions are excluded from progress, and a failed submit sets `showErrors`
/// without marking the assessment submitted.
void main() {
  late ProviderContainer container;
  late M2AssessmentNotifier vm;

  setUp(() {
    container = ProviderContainer();
    vm = container.read(m2AssessmentProvider.notifier);
  });

  tearDown(() => container.dispose());

  group('fixtures', () {
    test('21 answer fields plus 2 governance actions', () {
      expect(kM2AnswerItems.length, 21);
      expect(kM2Actions.length, 2);
      expect(vm.fieldCount, 21, reason: 'actions must not count as fields');
    });

    test('item ids are unique', () {
      final ids = kM2AnswerItems.map((i) => i.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('every required item carries a sample answer', () {
      for (final item in kM2AnswerItems.where((i) => i.required)) {
        expect(
          item.sample.trim(),
          isNotEmpty,
          reason: '${item.id} is required but has no sample',
        );
      }
    });

    test('sections are non-empty and start with section A', () {
      final sections = M2AssessmentState.sectionsOf(kM2AnswerItems);
      expect(sections, isNotEmpty);
      expect(sections.first, startsWith('A'));
    });
  });

  group('seeding', () {
    test('seeded state answers every field from its sample', () {
      final state = container.read(m2AssessmentProvider);
      expect(vm.answeredCount, vm.fieldCount);
      expect(state.answers, isNotEmpty);
      expect(state.multi, isNotEmpty, reason: 'multi items must be seeded too');
    });

    test('multi items are seeded as parsed sets, not raw strings', () {
      final state = container.read(m2AssessmentProvider);
      final multiIds = kM2AnswerItems
          .where((i) => i.type == M2ItemType.multi)
          .map((i) => i.id);
      for (final id in multiIds) {
        expect(state.multi[id], isNotNull);
      }
    });

    test('seeded state is complete and submits', () {
      expect(vm.isComplete, isTrue);
      expect(vm.submit(), isTrue);
      expect(container.read(m2AssessmentProvider).submitted, isTrue);
      expect(container.read(m2AssessmentProvider).showErrors, isFalse);
    });
  });

  group('answers', () {
    test('setAnswer updates the answer and keeps the error banner', () {
      vm.clearAll();
      vm.submit(); // force showErrors
      expect(container.read(m2AssessmentProvider).showErrors, isTrue);
      final missingBefore = vm.missingRequired.length;

      vm.setAnswer('M2-01', 'Partner');
      expect(container.read(m2AssessmentProvider).answers['M2-01'], 'Partner');
      // The banner stays visible and shrinks — it is not dismissed on the first
      // keystroke, which would hide the fields still outstanding.
      expect(container.read(m2AssessmentProvider).showErrors, isTrue);
      expect(vm.missingRequired.length, lessThan(missingBefore));
    });

    test('a successful submit clears showErrors', () {
      vm.clearAll();
      vm.submit();
      expect(container.read(m2AssessmentProvider).showErrors, isTrue);

      vm.resetToSamples();
      expect(vm.submit(), isTrue);
      expect(container.read(m2AssessmentProvider).showErrors, isFalse);
    });

    test('toggleMulti adds then removes an option', () {
      final id = kM2AnswerItems
          .firstWhere((i) => i.type == M2ItemType.multi)
          .id;
      final option = kM2AnswerItems
          .firstWhere((i) => i.id == id)
          .options
          .first;

      vm.clearAll();
      expect(container.read(m2AssessmentProvider).multi[id], isEmpty);

      vm.toggleMulti(id, option);
      expect(container.read(m2AssessmentProvider).multi[id], contains(option));

      vm.toggleMulti(id, option);
      expect(container.read(m2AssessmentProvider).multi[id], isEmpty);
    });

    test('state maps are not shared between snapshots', () {
      final before = container.read(m2AssessmentProvider);
      vm.setAnswer('M2-01', 'Manager');
      final after = container.read(m2AssessmentProvider);
      expect(identical(before.answers, after.answers), isFalse);
      expect(before.answers['M2-01'], isNot('Manager'));
    });
  });

  group('reset and clear', () {
    test('clearAll empties every answer', () {
      vm.clearAll();
      expect(vm.answeredCount, 0);
      expect(vm.isComplete, isFalse);
    });

    test('clearAll keeps field count unchanged', () {
      vm.clearAll();
      expect(vm.fieldCount, 21);
    });

    test('resetToSamples restores the seeded state', () {
      vm.clearAll();
      expect(vm.answeredCount, 0);
      vm.resetToSamples();
      expect(vm.answeredCount, vm.fieldCount);
      expect(container.read(m2AssessmentProvider).submitted, isFalse);
    });
  });

  group('validation', () {
    test('submit on an empty assessment fails and flags errors', () {
      vm.clearAll();
      expect(vm.submit(), isFalse);
      expect(container.read(m2AssessmentProvider).showErrors, isTrue);
      expect(container.read(m2AssessmentProvider).submitted, isFalse);
    });

    test('missingRequired lists only empty required fields', () {
      vm.clearAll();
      final missing = vm.missingRequired;
      expect(missing, isNotEmpty);
      expect(missing.every((i) => i.required), isTrue);
      expect(missing.every((i) => !container.read(m2AssessmentProvider).isAnswered(i)), isTrue);
    });

    test('whitespace is not an answer', () {
      vm.clearAll();
      final firstRequired =
          kM2AnswerItems.firstWhere((i) => i.required && i.type != M2ItemType.multi);
      vm.setAnswer(firstRequired.id, '   ');
      expect(container.read(m2AssessmentProvider).isAnswered(firstRequired), isFalse);
    });
  });

  group('progress', () {
    test('runs from 0.0 to 1.0', () {
      vm.clearAll();
      expect(vm.progress, 0.0);
      vm.resetToSamples();
      expect(vm.progress, 1.0);
    });

    test('is bounded even for a partial answer set', () {
      vm.clearAll();
      final first = kM2AnswerItems.firstWhere(
        (i) => i.type == M2ItemType.choice || i.type == M2ItemType.text,
      );
      vm.setAnswer(first.id, 'x');
      expect(vm.progress, greaterThan(0.0));
      expect(vm.progress, lessThan(1.0));
    });
  });
}
