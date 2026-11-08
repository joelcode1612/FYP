part of '../jaspr_provider_compat.dart';

/// The comparison a [Selector] uses to decide whether a notification is worth
/// a rebuild: `previous != next` unless this returns something else.
typedef ShouldRebuild<S> = bool Function(S previous, S next);

/// Rebuilds only when a selected slice of a provider changes.
///
/// ```dart
/// Selector<ExploreViewModel, List<CommercialProperty>>(
///   selector: (context, vm) => vm.visibleListings,
///   builder: (context, listings, child) => ListingGrid(listings),
/// )
/// ```
///
/// The subtree rebuilds when [selector] returns a different value, or whatever
/// [rebuildWhen] decides — not when the provider notifies for some other
/// field. It is the component-shaped version of `context.select`, and it is
/// what keeps a long list from repainting because an unrelated counter moved.
///
/// Nothing is subscribed to the notifier directly: the dependency is recorded
/// on the provider scope together with the selector, and the scope only
/// promotes this component out of its dependency list when the selected value
/// actually differs. That is why a server render (where no notification ever
/// arrives) needs no special handling here.
class Selector<A, S> extends StatelessComponent {
  const Selector({
    required this.selector,
    required this.builder,
    this.rebuildWhen,
    this.child,
    super.key,
  });

  /// Picks the part of the provider value this subtree renders.
  final S Function(BuildContext context, A value) selector;

  final Component Function(BuildContext context, S selected, Component? child)
  builder;

  /// Overrides the `previous != next` comparison. Called on every
  /// notification, so it must be cheap.
  ///
  /// Upstream `provider` calls this `shouldRebuild`; that name is taken by
  /// Jaspr's own `Component.shouldRebuild`, which decides whether a component
  /// may skip its rebuild, so the hook is spelled differently here.
  final ShouldRebuild<S>? rebuildWhen;

  /// Passed to [builder] as its third argument, exactly as in `provider`.
  final Component? child;

  @override
  Component build(BuildContext context) {
    final selected = _selectScope<A, S>(
      context,
      (value) => selector(context, value),
      rebuildWhen == null
          ? null
          : (previous, next) => rebuildWhen!(previous as S, next as S),
    );
    return builder(context, selected, child);
  }
}

/// Registers [selector] as this context's dependency on the provider for [A]
/// and returns the value it selects right now.
S _selectScope<A, S>(
  BuildContext context,
  Object? Function(A value) selector,
  bool Function(Object? previous, Object? next)? compare,
) {
  final aspect = _SelectorAspect<A>(selector, compare);
  final scope = context
      .dependOnInheritedComponentOfExactType<_InheritedProviderScope<A>>(
        aspect: aspect,
      );
  if (scope == null) {
    throw ProviderNotFoundException(A, context.component.runtimeType);
  }
  return aspect.selector(scope.value) as S;
}
