import 'package:flutter/widgets.dart';

/// Marks a top-level Entrepreneur tab body rendered inside the persistent host.
/// Detail pages remain independent Navigator routes with their own chrome.
class EntrepreneurTabScope extends InheritedWidget {
  const EntrepreneurTabScope({
    super.key,
    required super.child,
    required this.onTabSelected,
  });

  final ValueChanged<String> onTabSelected;

  static const Set<String> tabRoutes = <String>{
    '/entrepreneur',
    '/entrepreneur/explore',
    '/entrepreneur/assess',
    '/entrepreneur/spaces',
    '/entrepreneur/profile',
  };

  static bool isTabRoute(String route) => tabRoutes.contains(route);

  static EntrepreneurTabScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<EntrepreneurTabScope>();

  /// Use for in-page shortcuts to other primary tabs. If no tab host exists,
  /// fall back to the existing named-route system (for deep links/detail UI).
  /// Normal property detail and assessment destinations are always pushed.
  ///
  /// The fallback never *pushes* a tab route: the route table maps every tab
  /// route to a fresh [EntrepreneurTabHost], so a push would stack a second
  /// full workspace (double bottom bar + a spurious back arrow that pops the
  /// user out of nowhere). Instead the stack is unwound to the workspace root
  /// and that root is replaced with a host opened on the requested tab.
  static void open(BuildContext context, String route, {Object? arguments}) {
    final host = maybeOf(context);
    if (host != null && arguments == null && isTabRoute(route)) {
      host.onTabSelected(route);
      return;
    }
    if (arguments == null && isTabRoute(route)) {
      final nav = Navigator.of(context);
      nav.popUntil((r) => r.isFirst);
      nav.pushReplacementNamed(route);
      return;
    }
    Navigator.of(context).pushNamed(route, arguments: arguments);
  }

  @override
  bool updateShouldNotify(EntrepreneurTabScope oldWidget) =>
      onTabSelected != oldWidget.onTabSelected;
}
