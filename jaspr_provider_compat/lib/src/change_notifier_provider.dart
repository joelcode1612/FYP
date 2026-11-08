part of '../jaspr_provider_compat.dart';

// Private named initializing formals are not legal Dart — see the note in
// `provider.dart` for why the constructors assign their fields by hand.
// ignore_for_file: prefer_initializing_formals

/// Exposes a [ChangeNotifier] and rebuilds its dependents whenever it
/// notifies.
///
/// ```dart
/// ChangeNotifierProvider<EntrepreneurViewModel>.value(
///   value: locator.entrepreneurViewModel,
///   child: App(),
/// )
/// ```
///
/// The notifier is *not* re-created when this component rebuilds — the same
/// instance is kept for the lifetime of the provider, which is what makes
/// `create:` safe to pass an inline closure.
///
/// ## Server renders do not subscribe
///
/// `addListener` is only called when `context.binding.isClient`, so a server
/// render draws the current state and attaches nothing. Without that guard
/// every request would leave another listener on a process-wide view model.
///
/// ## `create` vs `.value`
///
/// `.value` never disposes: the caller owns the object. `create` builds the
/// object once and disposes it when the provider leaves the tree — but only
/// in the browser, because Jaspr does not unmount the tree it renders on the
/// server. Objects that subscribe to shared singletons must therefore be
/// provided with `.value`.
class ChangeNotifierProvider<T extends ChangeNotifier?>
  extends StatefulComponent
  implements SingleChildProvider {
  ChangeNotifierProvider({
    required Create<T> create,
    TransitionBuilder? builder,
    Component? child,
    super.key,
  }) : _create = create,
       _supplied = null,
       _builder = builder,
       _child = child,
       _ownsValue = true;

  ChangeNotifierProvider.value({
    required T value,
    TransitionBuilder? builder,
    Component? child,
    super.key,
  }) : _create = null,
       _supplied = value,
       _builder = builder,
       _child = child,
       _ownsValue = false;

  final Create<T>? _create;
  final T? _supplied;
  final TransitionBuilder? _builder;
  final Component? _child;
  final bool _ownsValue;

  @override
  State<ChangeNotifierProvider<T>> createState() =>
      _ChangeNotifierProviderState<T>();

  @override
  Component wrappedWith(Component child) => _ownsValue
      ? ChangeNotifierProvider(
          create: _create!,
          builder: _builder,
          child: child,
          key: key,
        )
      : ChangeNotifierProvider.value(
          value: _supplied as T,
          builder: _builder,
          child: child,
          key: key,
        );
}

class _ChangeNotifierProviderState<T extends ChangeNotifier?>
  extends State<ChangeNotifierProvider<T>> {
  T? _created;

  /// Whether [Create] has run. Tracked separately from [_created] because a
  /// provider for a nullable type may legitimately create null.
  bool _hasCreated = false;

  /// The instance this state currently has a listener on. Jaspr gives no
  /// callback when the provided instance changes, so the identity is checked
  /// on each build.
  Listenable? _subscribed;

  /// Bumped on every notification; the scope compares it so that a notifier
  /// whose identity never changes still rebuilds its dependents.
  int _revision = 0;

  bool get _isClient => context.binding.isClient;

  void _handleChanged() {
    // Notifications can arrive after unmount if the notifier outlives the
    // tree (it usually does — it is app-wide). `mounted` is the guard.
    if (!mounted) return;
    setState(() => _revision++);
  }

  void _sync(T? next) {
    if (identical(_subscribed, next)) return;
    _subscribed?.removeListener(_handleChanged);
    _subscribed = null;
    if (next != null && _isClient) {
      next.addListener(_handleChanged);
      _subscribed = next;
    }
  }

  @override
  Component build(BuildContext context) {
    final T notifier;
    if (component._ownsValue) {
      if (!_hasCreated) {
        _created = component._create!(context);
        _hasCreated = true;
      }
      notifier = _created as T;
    } else {
      notifier = component._supplied as T;
    }
    _sync(notifier);

    final child = component._child ?? Component.text('');
    final builder = component._builder;
    return _InheritedProviderScope<T>(
      value: notifier,
      revision: _revision,
      child: builder == null ? child : builder(context, component._child),
    );
  }

  @override
  void dispose() {
    _subscribed?.removeListener(_handleChanged);
    _subscribed = null;
    if (component._ownsValue && _hasCreated) _created?.dispose();
    super.dispose();
  }
}
