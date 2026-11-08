part of '../jaspr_provider_compat.dart';

/// A component that rebuilds when the provider for [T] changes, and hands the
/// value to [builder].
///
/// ```dart
/// Consumer<AuthViewModel>(
///   builder: (context, auth, child) => auth.isReady
///       ? Dashboard(auth: auth)
///       : const WaitingForSession(),
/// )
/// ```
///
/// `Consumer` exists so that only the subtree it renders depends on [T] —
/// wrapping a page in one keeps the rest of the tree from re-rendering. When a
/// component needs the value in several places, `context.watch<T>()` at the
/// top of its own build does the same job.
///
/// The second type argument of Flutter's `Consumer<T, ChildType>` is dropped:
/// Jaspr builders return `Component`, which is not generic.
class Consumer<T> extends StatelessComponent {
  const Consumer({required this.builder, this.child, super.key});

  final Component Function(BuildContext context, T value, Component? child)
  builder;

  /// Passed to [builder] as its third argument, exactly as in `provider`.
  final Component? child;

  @override
  Component build(BuildContext context) =>
      builder(context, Provider.of<T>(context), child);
}
