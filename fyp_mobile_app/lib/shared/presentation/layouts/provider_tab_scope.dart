import 'package:flutter/widgets.dart';

/// Command-only bridge from provider pages to their persistent tab host.
///
/// It deliberately exposes no rebuildable state: pages call [go] to select an
/// existing tab or push a drill-in, and the host owns all navigation state.
/// Keeping the API as commands means a tab page never has to watch the shell
/// (and rebuild with it) just to move between sections.
class ProviderTabScope extends InheritedWidget {
  const ProviderTabScope({
    super.key,
    required this.handles,
    required this.go,
    required super.child,
  });

  /// Whether [go] will resolve [route] inside the persistent shell rather than
  /// pushing another workspace route.
  final bool Function(String route) handles;

  final void Function(String route, {Object? arguments}) go;

  static ProviderTabScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ProviderTabScope>();

  bool handlesRoute(String route) => handles(route);

  @override
  bool updateShouldNotify(covariant ProviderTabScope oldWidget) => false;
}
