import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:test/test.dart';
import '../lib/features/entrepreneur_assessment/application/assessment_view_model.dart';
import '../lib/features/entrepreneur_assessment/domain/review_notes.dart';

void main() {
  test('M2-16 None is exclusive against survey evidence', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final vm = container.read(assessmentProvider.notifier);
    vm.toggleMulti('M2-16', 'None');
    vm.toggleMulti('M2-16', 'A prior survey I ran');
    expect(container.read(assessmentProvider).multi('M2-16'), ['A prior survey I ran']);
    vm.toggleMulti('M2-16', 'None');
    expect(container.read(assessmentProvider).multi('M2-16'), ['None']);
  });

  test('M2-09 select up to two and maintain primary membership', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final vm = container.read(assessmentProvider.notifier);
    vm.toggleMulti('M2-09', 'Price');
    vm.toggleMulti('M2-09', 'Quality/specialty');
    vm.toggleMulti('M2-09', 'Ambience');
    expect(container.read(assessmentProvider).multi('M2-09').length, 2);
    vm.toggleMulti('M2-07', 'Students');
    vm.setPrimaryCustomer('Students');
    vm.toggleMulti('M2-07', 'Students');
    expect(container.read(assessmentProvider).primaryCustomer, isEmpty);
  });

  test('held items do not accept answers', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(assessmentProvider.notifier).setSingle('M2-10', 'RM12–RM14.99');
    expect(container.read(assessmentProvider).single('M2-10'), isEmpty);
  });

  test('demo confirmation invalidated on answer edit', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final vm = container.read(assessmentProvider.notifier);
    vm.reviewDemo();
    vm.confirmDemo();
    expect(container.read(assessmentProvider).confirmedInDemo, isTrue);
    vm.setDescription('My café idea, entrepreneur-authored.');
    expect(container.read(assessmentProvider).reviewed, isFalse);
    expect(container.read(assessmentProvider).confirmedInDemo, isFalse);
  });

  test('forecasts remain explicitly unverified in notes', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(assessmentProvider.notifier).setSingle('M2-O-01', '30–59');
    final notes = makeDemoReviewNotes(container.read(assessmentProvider));
    final forecast = notes.singleWhere((x) => x.sourceIds.contains('M2-O-01'));
    expect(forecast.limitation, contains('not observed demand'));
  });
}
