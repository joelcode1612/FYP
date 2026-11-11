import 'package:flutter/material.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../core/theme/sitewise_theme.dart';
import '../../../presentation/shared/widgets/sitewise_error_state.dart';

/// Loads one piece of remote data **once**, with working retry and refresh.
///
/// Why this exists: several workspace screens built their `FutureBuilder` with
/// a fresh `future:` expression inside `build()`. That re-issued the request on
/// every rebuild (tab switches, keyboard insets, a parent `setState`), the
/// spinner restarted each time, there was no way to retry a failure, and a
/// failed read fell through to `snap.data ?? const []` — an API error rendered
/// as "no records", which is exactly the silent-empty state the brief forbids.
///
/// This widget owns the request instead:
///
///  * [load] runs on first build and on an explicit [refresh]/[retry];
///  * a sequence counter drops stale responses, so a slow first request can
///    never overwrite the result of a newer one;
///  * the previous value stays on screen while a refresh is in flight
///    (non-destructive), and a refresh failure is reported *above* the stale
///    data rather than replacing it;
///  * errors are shown with a Retry that re-runs the actual request.
///
/// Use [AsyncSectionState.refresh] via a `GlobalKey` from a `RefreshIndicator`.
class AsyncSection<T> extends StatefulWidget {
  const AsyncSection({
    super.key,
    required this.load,
    required this.builder,
    this.revision = 0,
    this.isEmpty,
    this.emptyBuilder,
    this.errorTitle = 'Could not load this section',
    this.loadingBuilder,
  });

  /// The request to run. Must be a real repository call — never a cached
  /// constant — otherwise Refresh would have nothing to refresh.
  final Future<T> Function() load;

  final Widget Function(BuildContext context, T value) builder;

  /// Changing this value reloads the section. Screens pass a revision that is
  /// bumped when a *different* screen changed the same data (for example
  /// returning from Add Property), which is the re-entry signal.
  final int revision;

  /// Optional empty predicate: when true, [emptyBuilder] is rendered instead of
  /// [builder]. Distinguishes "loaded, nothing there" from "still loading".
  final bool Function(T value)? isEmpty;
  final Widget Function(BuildContext context)? emptyBuilder;

  final String errorTitle;
  final WidgetBuilder? loadingBuilder;

  @override
  State<AsyncSection<T>> createState() => AsyncSectionState<T>();
}

class AsyncSectionState<T> extends State<AsyncSection<T>> {
  T? _value;
  Object? _error;
  bool _loading = false;
  int _sequence = 0;

  bool get _hasValue => _value != null;

  @override
  void initState() {
    super.initState();
    // A frame later keeps the first paint free: the request must not publish
    // state while the tree is building.
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  @override
  void didUpdateWidget(AsyncSection<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.revision != oldWidget.revision) _run();
  }

  /// Re-runs the request. Keeps the current value visible while it is in
  /// flight, so a pull-to-refresh does not blank the screen.
  Future<void> refresh() => _run();

  /// Re-runs after a failure and clears the previous error first.
  Future<void> retry() => _run();

  Future<void> _run() async {
    final sequence = ++_sequence;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final value = await widget.load();
      if (!mounted || sequence != _sequence) return; // stale response
      setState(() {
        _value = value;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted || sequence != _sequence) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  String _message(Object error) =>
      error is AppFailure ? error.userMessage : 'Please try again.';

  IconData _icon(Object error) => switch (error) {
    NetworkFailure() => Icons.wifi_off_rounded,
    UnauthorizedFailure() || SessionExpiredFailure() => Icons.lock_outline,
    NotFoundFailure() => Icons.search_off_rounded,
    ResponseFormatFailure() => Icons.report_gmailerrorred_rounded,
    _ => Icons.cloud_off_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null && !_hasValue) {
      return SitewiseErrorState(
        title: widget.errorTitle,
        message: _message(error),
        icon: _icon(error),
        onRetry: retry,
      );
    }
    if (!_hasValue) {
      return widget.loadingBuilder?.call(context) ??
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 28),
            child: Center(child: CircularProgressIndicator()),
          );
    }

    final value = _value as T;
    final empty = widget.isEmpty?.call(value) ?? false;
    final body = empty
        ? (widget.emptyBuilder?.call(context) ??
              const SizedBox.shrink())
        : widget.builder(context, value);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A refresh that failed keeps the last good data on screen and says so
        // — it never silently reverts to an empty or spinner state.
        if (error != null)
          _StaleWarning(
            message: _message(error),
            onRetry: retry,
            busy: _loading,
          ),
        if (_loading && error == null) const _RefreshingBar(),
        body,
      ],
    );
  }
}

class _RefreshingBar extends StatelessWidget {
  const _RefreshingBar();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(bottom: 8),
    child: LinearProgressIndicator(minHeight: 2),
  );
}

class _StaleWarning extends StatelessWidget {
  const _StaleWarning({
    required this.message,
    required this.onRetry,
    required this.busy,
  });

  final String message;
  final VoidCallback onRetry;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: SitewiseColors.danger.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.sync_problem_rounded,
              size: 16, color: SitewiseColors.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 11.5,
                height: 1.35,
                color: SitewiseColors.danger,
              ),
            ),
          ),
          TextButton(
            onPressed: busy ? null : onRetry,
            child: const Text('Retry', style: TextStyle(fontSize: 11.5)),
          ),
        ],
      ),
    );
  }
}
