part of '../jaspr_provider_compat.dart';

// ---------------------------------------------------------------------------
// Signatures
// ---------------------------------------------------------------------------

/// Creates the value a [Provider] exposes. Receives the build context of the
/// provider itself, so it may use `context.read<T>()` for dependencies that
/// are already in scope. Listening (`context.watch`) from here is not valid —
/// creation happens while the tree is being built.
typedef Create<T> = T Function(BuildContext context);

/// Frees a value that [Provider] or [ChangeNotifierProvider] created. Called
/// when the provider leaves the tree; never called for a value that was
/// handed in with `.value`.
typedef Dispose<T> = void Function(BuildContext context, T value);

/// Decides whether dependents rebuild when the exposed value changes.
/// Defaults to `previous != next`.
typedef UpdateShouldNotify<T> = bool Function(T previous, T next);

/// Wraps the subtree a provider renders, giving access to a [BuildContext]
/// that is a descendant of the provider.
typedef TransitionBuilder =
    Component Function(BuildContext context, Component? child);

// ---------------------------------------------------------------------------
// The inherited component every provider renders
// ---------------------------------------------------------------------------

/// The single [InheritedComponent] type behind every provider in this package.
///
/// Lookup is by *exact* generic instantiation, so `Provider<AppController>`
/// and `Provider<OwnerController>` are two different scopes and a provider for
/// one can never satisfy a read of the other. That is also why the type
/// argument has to be written out when the value is a subtype of what the tree
/// declares.
///
/// Two things make it rebuild dependents:
///   * [value] changing identity (a `.value` provider fed a new instance), and
///   * [revision] changing — the counter a listenable-backed provider bumps
///     when its notifier fires, which is what lets a `ChangeNotifier` whose
///     identity never changes still drive rebuilds.
class _InheritedProviderScope<T> extends InheritedComponent {
  const _InheritedProviderScope({
    required this.value,
    required this.revision,
    required super.child,
    this.updateShouldNotifyCallback,
  });

  final T value;
  final int revision;
  final UpdateShouldNotify<T>? updateShouldNotifyCallback;

  @override
  InheritedElement createElement() => _InheritedProviderScopeElement<T>(this);

  @override
  bool updateShouldNotify(_InheritedProviderScope<T> old) {
    final custom = updateShouldNotifyCallback;
    if (custom != null) return custom(old.value, value);
    return old.value != value || old.revision != revision;
  }
}

/// Adds `context.select` support on top of [InheritedComponent] semantics.
///
/// Jaspr's [InheritedElement] already threads an `aspect` through
/// `dependOnInheritedElement`, which is exactly the hook `provider` uses for
/// `select`: the aspect carries the selector plus the value it last produced,
/// and a dependent is only marked dirty when that selected value changes.
class _InheritedProviderScopeElement<T> extends InheritedElement {
  _InheritedProviderScopeElement(_InheritedProviderScope<T> super.component);

  @override
  _InheritedProviderScope<T> get component =>
      super.component as _InheritedProviderScope<T>;

  @override
  void updateDependencies(Element dependent, Object? aspect) {
    if (aspect is _SelectorAspect<T>) {
      // Re-registering a selector refreshes the closure (a component's build
      // creates a new function object every frame) and re-records what it
      // currently selects, so the next notification has something to compare
      // against.
      final previous = getDependencies(dependent);
      final selected = aspect.selector(component.value);
      if (previous is _Selection<T>) {
        previous.aspect = aspect;
        previous.selected = selected;
        return;
      }
      setDependencies(dependent, _Selection<T>(aspect, selected));
      return;
    }
    setDependencies(dependent, aspect);
  }

  @override
  void notifyDependent(
    covariant _InheritedProviderScope<T> oldComponent,
    Element dependent,
  ) {
    final selection = getDependencies(dependent);
    if (selection is _Selection<T>) {
      final aspect = selection.aspect;
      final next = aspect.selector(component.value);
      final changed = aspect.compare?.call(selection.selected, next) ??
          (selection.selected != next);
      if (changed) {
        selection.selected = next;
        dependent.didChangeDependencies();
      }
      return;
    }
    super.notifyDependent(oldComponent, dependent);
  }
}

/// The aspect a `context.select` / [Selector] call registers: the selector
/// plus the comparison that decides whether a change is worth a rebuild.
class _SelectorAspect<T> {
  const _SelectorAspect(this.selector, [this.compare]);

  final Object? Function(T value) selector;
  final bool Function(Object? previous, Object? next)? compare;
}

/// What this element keeps per dependent: the latest aspect and the value it
/// produced, so a notification can be compared against what was rendered.
class _Selection<T> {
  _Selection(this.aspect, this.selected);

  _SelectorAspect<T> aspect;
  Object? selected;
}
