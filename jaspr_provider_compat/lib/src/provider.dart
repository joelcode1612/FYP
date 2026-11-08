part of '../jaspr_provider_compat.dart';

// Dart does not allow private named initializing formals (`{required this._create}`
// is a syntax error because named parameters cannot start with `_`), so the
// two constructors below must assign their private fields by hand.
// ignore_for_file: prefer_initializing_formals

/// Exposes a value to a subtree without watching it.
///
/// ```dart
/// Provider<ApiClient>(
///   create: (context) => ApiConfig.buildClient(),
///   child: App(),
/// )
/// ```
///
/// Use the `.value` form for an object this app already owns — a view model
/// built by the composition root, for instance — because `.value` never
/// disposes what it is handed. That property matters on the server: a
/// `create`-built object is garbage-collected after a render but its
/// `dispose` is never called, so anything that subscribes to a shared
/// singleton must come in through `.value`.
class Provider<T> extends StatefulComponent implements SingleChildProvider {
  /// Builds [T] once, on the first frame this provider is rendered, and
  /// disposes it (via [dispose]) when it leaves the tree.
  Provider({
    required Create<T> create,
    Dispose<T>? dispose,
    TransitionBuilder? builder,
    Component? child,
    super.key,
  }) : _create = create,
       _dispose = dispose,
       _value = null,
       _updateShouldNotify = null,
       _builder = builder,
       _child = child,
       _ownsValue = true;

  /// Exposes an existing [value] and leaves it undisposed.
  ///
  /// Dependents rebuild when the value identity changes, or when a custom
  /// [updateShouldNotify] says so.
  Provider.value({
    required T value,
    UpdateShouldNotify<T>? updateShouldNotify,
    TransitionBuilder? builder,
    Component? child,
    super.key,
  }) : _create = null,
       _dispose = null,
       _value = value,
       _updateShouldNotify = updateShouldNotify,
       _builder = builder,
       _child = child,
       _ownsValue = false;

  final Create<T>? _create;
  final Dispose<T>? _dispose;
  final T? _value;
  final UpdateShouldNotify<T>? _updateShouldNotify;
  final TransitionBuilder? _builder;
  final Component? _child;

  /// Whether this instance created (and therefore must dispose) the value.
  final bool _ownsValue;

  @override
  State<Provider<T>> createState() => _ProviderState<T>();

  @override
  Component wrappedWith(Component child) => _ownsValue
      ? Provider(
          create: _create!,
          dispose: _dispose,
          builder: _builder,
          child: child,
          key: key,
        )
      : Provider.value(
          value: _value as T,
          updateShouldNotify: _updateShouldNotify,
          builder: _builder,
          child: child,
          key: key,
        );

  /// Obtains the nearest [T] exposed by a provider above [context].
  ///
  /// With [listen] the reading component rebuilds when that provider changes;
  /// with `listen: false` it only borrows the value, which is what event
  /// callbacks and `create` bodies want. Prefer `context.watch<T>()` and
  /// `context.read<T>()`, which forward here.
  static T of<T>(BuildContext context, {bool listen = true}) {
    assert(
      T != dynamic,
      'Tried to read a provider with the type $T, which matches every '
      'provider. Give the read an explicit type, e.g. '
      'context.read<EntrepreneurViewModel>().',
    );

    final _InheritedProviderScope<T>? scope;
    if (listen) {
      scope = context.dependOnInheritedComponentOfExactType<
        _InheritedProviderScope<T>
      >();
    } else {
      final element = context
          .getElementForInheritedComponentOfExactType<
            _InheritedProviderScope<T>
          >();
      scope = element?.component as _InheritedProviderScope<T>?;
    }

    if (scope == null) {
      throw ProviderNotFoundException(T, context.component.runtimeType);
    }
    return scope.value;
  }
}

class _ProviderState<T> extends State<Provider<T>> {
  T? _created;
  bool _hasCreated = false;

  T get _value {
    if (!component._ownsValue) return component._value as T;
    if (!_hasCreated) {
      _created = component._create!(context);
      _hasCreated = true;
    }
    return _created as T;
  }

  @override
  void dispose() {
    // `context` is still valid here: Jaspr nulls the element after this call.
    if (_hasCreated) component._dispose?.call(context, _created as T);
    super.dispose();
  }

  @override
  Component build(BuildContext context) {
    final child = component._child ?? Component.text('');
    final builder = component._builder;
    return _InheritedProviderScope<T>(
      value: _value,
      revision: 0,
      updateShouldNotifyCallback: component._updateShouldNotify,
      child: builder == null ? child : builder(context, component._child),
    );
  }
}

/// Raised when no provider for [T] exists above the reading component.
class ProviderNotFoundException implements Exception {
  const ProviderNotFoundException(this.valueType, this.componentType);

  /// The type that was asked for.
  final Type valueType;

  /// The component that asked for it.
  final Type componentType;

  @override
  String toString() {
    if (kReleaseMode) {
      return 'Provider<$valueType> not found for $componentType';
    }
    return '''
Error: Could not find the correct Provider<$valueType> above this $componentType Component.

This happens because the component was rendered outside the provider that
creates $valueType. Common causes:

- The provider was added to the tree but the page was not rebuilt — restart
  the dev server.
- The provider lives inside a route and the reading component sits in
  another one.
- The provider was declared with a supertype (`Provider<Foo>`) and read with
  a subtype (`context.read<Bar>()`), or the other way round. Provider lookup
  matches the exact type argument.
''';
  }
}
