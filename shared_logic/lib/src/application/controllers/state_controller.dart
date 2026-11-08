/// Framework-free observable state holder shared by both frontends.
///
/// `bloc` remains a dependency of this package only because the Cubit adapters
/// still exist for callers that want a `Stream`. A ViewModel that needs to
/// rebuild a user interface subscribes here instead, so neither platform has to
/// re-implement a state transition it did not write.
///
/// Listeners run synchronously, in registration order, with the state that was
/// just applied. That matches `Cubit.emit`, which the adapters forward to.
abstract class StateController<S> {
  StateController(S initial) : _state = initial;

  S _state;
  final List<void Function(S next)> _listeners = <void Function(S)>[];
  bool _disposed = false;

  S get state => _state;

  bool get isDisposed => _disposed;

  void addListener(void Function(S next) listener) {
    assert(!_disposed, 'Listener added to a disposed $runtimeType');
    _listeners.add(listener);
  }

  void removeListener(void Function(S next) listener) => _listeners.remove(
    listener,
  );

  /// Applies [next] and notifies every listener. Silently ignored after
  /// [dispose], because a platform adapter may still be inside a callback chain
  /// when the owning component is torn down.
  void setState(S next) {
    if (_disposed) return;
    _state = next;
    for (final listener in List<void Function(S)>.of(_listeners)) {
      listener(next);
    }
  }

  void dispose() {
    _disposed = true;
    _listeners.clear();
  }
}
