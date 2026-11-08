import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

/// App-wide UI state (role, preview, saved and compare sets) as a Jaspr
/// view model.
///
/// A thin [ChangeNotifier] over the shared [AppController]: the transitions
/// and the three-entry compare cap stay in `shared_logic`, and this class only
/// turns each new state into a `notifyListeners` call. The Flutter app drives
/// the same controller through `AppState`/`AppCubit`; neither platform
/// re-implements a rule.
///
/// Provided through the app-wide provider scope (`ChangeNotifierProvider
/// .value`, so the provider never disposes the instance the composition root
/// owns) and read with `context.watch<AppViewModel>()`, `Consumer` or
/// `Selector`.
class AppViewModel extends ChangeNotifier {
  final AppController _controller;

  AppViewModel([AppState? initial]) : _controller = AppController(initial) {
    _controller.addListener(_publish);
  }

  void _publish(AppState next) => notifyListeners();

  @override
  void dispose() {
    _controller.removeListener(_publish);
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

  /// Replaces the whole state — the cookie-seeded install path.
  void restore(AppState value) => _controller.restore(value);
}
