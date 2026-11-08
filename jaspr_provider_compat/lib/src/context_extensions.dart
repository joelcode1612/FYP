part of '../jaspr_provider_compat.dart';

/// Reads a provider without rebuilding this component.
///
/// Use it in event handlers (`onTap`) and in `create` bodies. Calling it to
/// render a value is a bug in waiting: the value is fetched once per build,
/// and nothing re-runs the build when it changes.
extension ReadContext on BuildContext {
  T read<T>() => Provider.of<T>(this, listen: false);
}

/// Reads a provider and rebuilds this component when it changes.
extension WatchContext on BuildContext {
  T watch<T>() => Provider.of<T>(this);
}

/// Reads one slice of a provider and rebuilds only when that slice changes.
extension SelectContext on BuildContext {
  /// [selector] is re-registered on every build, so a closure literal here is
  /// fine (upstream `provider` requires it to keep its identity; this
  /// implementation does not).
  R select<T, R>(R Function(T value) selector) => _selectScope<T, R>(
    this,
    selector,
    null,
  );
}

/// A `context.read`-shaped function that can be handed to an object instead
/// of a [BuildContext], so that object need not know about Jaspr.
typedef Locator = T Function<T>();
