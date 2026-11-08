import 'package:bloc/bloc.dart';
import 'package:jaspr/jaspr.dart';

/// Jaspr counterpart to `flutter_bloc`'s `BlocBuilder`.
///
/// Subscribes to the cubit's [Stream] with the current state seeded as
/// [StreamBuilder.initialData]. On the server (static generation) the stream
/// is `null` — jaspr asserts streams are never attached during SSR — so the
/// server renders one frame of the *current* state and the browser attaches
/// the subscription after hydration, rebuilding on every later emit.
///
/// The optional [when] predicate is flutter_bloc's `buildWhen`: an emit only
/// rebuilds this subtree when it returns true. `copyWith` keeps the references
/// of untouched fields, so identity comparison (`p.queue != n.queue`) is the
/// intended way to scope a builder to one slice of the state. The initial
/// frame always builds, regardless of [when].
///
/// Callbacks must close over the cubit itself (the "read" style —
/// `vm.approve(id)`, `vm.retry()`) and never depend on values captured from
/// the builder's state; the builder only decides *when* and *what* to render.
class CubitBuilder<C extends Cubit<S>, S> extends StreamBuilder<S> {
  CubitBuilder({
    required C cubit,
    required Component Function(BuildContext context, S state) builder,
    bool Function(S previous, S next)? when,
    Stream<S>? stream,
    super.key,
  }) : super(
         // [when] applies to the injected stream too, so tests can exercise
         // the same filtering the browser subscription uses.
         stream: _filtered(stream ?? (kIsWeb ? cubit.stream : null), cubit, when),
         initialData: cubit.state,
         builder: (context, snapshot) => builder(context, snapshot.data as S),
       );

  /// Applies [when] per subscription: each listener folds over its own view of
  /// the broadcast stream, so several scoped builders can share one cubit.
  /// A null source (SSR) passes through untouched.
  static Stream<T>? _filtered<C extends Cubit<T>, T>(
    Stream<T>? source,
    C cubit,
    bool Function(T previous, T next)? when,
  ) {
    if (source == null || when == null) return source;
    var previous = cubit.state;
    return source.where((next) {
      final build = when(previous, next);
      previous = next;
      return build;
    });
  }
}
