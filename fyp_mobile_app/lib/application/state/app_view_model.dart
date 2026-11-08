import 'package:flutter/foundation.dart';
import 'package:shared_logic/shared_logic.dart';

/// App-wide UI state (role, preview, saved and compare sets) as a Flutter
/// view model.
///
/// A thin [ChangeNotifier] over the shared [AppController]: the transitions and
/// the three-entry compare cap stay in `shared_logic`, and this class only turns
/// each new state into a `notifyListeners` call. The Jaspr app drives the same
/// controller through its own `AppViewModel`; neither platform re-implements a
/// rule.
///
/// Provided once at the root with `ChangeNotifierProvider.value`, so the
/// provider never disposes the instance [ServiceLocator] owns. Screens read it
/// with `context.watch<AppViewModel>()`, `Consumer` or `Selector`.
class AppViewModel extends ChangeNotifier {
  final AppController _controller;

  AppViewModel([AppState? initial]) : _controller = AppController(initial) {
    _controller.addListener(_publish);
  }

  void _publish(AppState next) => notifyListeners();

  @override
  void dispose() {
    _controller.removeListener(_publish);
    _controller.dispose();
    super.dispose();
  }

  AppRole get role => _controller.role;

  PreviewMode get preview => _controller.preview;

  Set<String> get saved => _controller.saved;

  Set<String> get compared => _controller.compared;

  bool isSaved(String id) => _controller.isSaved(id);

  bool isCompared(String id) => _controller.isCompared(id);

  void setRole(AppRole value) => _controller.setRole(value);

  void setPreview(PreviewMode value) => _controller.setPreview(value);

  void toggleSaved(String id) => _controller.toggleSaved(id);

  void toggleCompared(String id) => _controller.toggleCompared(id);

  void clearCompared() => _controller.clearCompared();

  /// Replaces the whole state.
  void restore(AppState value) => _controller.restore(value);
}
