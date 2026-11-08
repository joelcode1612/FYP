import 'package:bloc/bloc.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/components/bloc.dart';

/// Minimal cubit for exercising [CubitBuilder]'s subscription behaviour.
class _Counter extends Cubit<int> {
  _Counter() : super(0);
}

/// Component tests for the CubitBuilder `when` filter (the flutter_bloc
/// `buildWhen` analog). The stream is passed explicitly because `kIsWeb` is
/// false under the VM test runner and the builder would otherwise render one
/// static frame of the initial state.
void main() {
  testComponents('rebuilds on every emit without when', (tester) async {
    final cubit = _Counter();
    tester.pumpComponent(
      CubitBuilder<_Counter, int>(
        cubit: cubit,
        stream: cubit.stream,
        builder: (context, state) => Component.text('n=$state'),
      ),
    );
    expect(find.text('n=0'), findsOneComponent);

    cubit.emit(1);
    await tester.pump();
    expect(find.text('n=1'), findsOneComponent);
    expect(find.text('n=0'), findsNothing);
  });

  testComponents('when filters non-matching emits without rebuilding', (
    tester,
  ) async {
    final cubit = _Counter();
    tester.pumpComponent(
      CubitBuilder<_Counter, int>(
        cubit: cubit,
        stream: cubit.stream,
        when: (previous, next) => next.isEven,
        builder: (context, state) => Component.text('n=$state'),
      ),
    );
    expect(find.text('n=0'), findsOneComponent);

    cubit.emit(1);
    await tester.pump();
    expect(find.text('n=0'), findsOneComponent);
    expect(find.text('n=1'), findsNothing);

    cubit.emit(2);
    await tester.pump();
    expect(find.text('n=2'), findsOneComponent);
    expect(find.text('n=0'), findsNothing);
  });

  testComponents('when tracks the previous state across filtered emits', (
    tester,
  ) async {
    final cubit = _Counter();
    tester.pumpComponent(
      CubitBuilder<_Counter, int>(
        cubit: cubit,
        stream: cubit.stream,
        // Only build when the value grew by exactly 2 since the previous
        // *emitted* state — not since the last built frame.
        when: (previous, next) => next - previous == 2,
        builder: (context, state) => Component.text('n=$state'),
      ),
    );
    expect(find.text('n=0'), findsOneComponent);

    cubit.emit(1); // +1 → filtered, but previous must advance to 1
    await tester.pump();
    expect(find.text('n=0'), findsOneComponent);

    cubit.emit(3); // +2 from the filtered previous → rebuilds
    await tester.pump();
    expect(find.text('n=3'), findsOneComponent);
    expect(find.text('n=0'), findsNothing);
  });
}
