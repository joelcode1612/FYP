import 'package:riverpod/riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../domain/entities/app_role.dart';
import '../controllers/app_controller.dart';
import '../states/app_state.dart';
import 'providers.dart';

/// Notifier facade over [AppController].
///
/// Every transition lives in the controller; this class only mirrors it into
/// the provider so both apps watch the same truth. The controller's state
/// object and the provider state cannot drift apart — the controller is the
/// only writer and every write is republished here.
class AppNotifier extends Notifier<AppState> {
  late AppController _controller;

  @override
  AppState build() {
    _controller = AppController(ref.watch(appInitialStateProvider));
    _controller.addListener(_publish);
    ref.onDispose(() {
      _controller.removeListener(_publish);
      _controller.dispose();
    });
    return _controller.state;
  }

  /// The controller's state object, exposed so the provider state and
  /// `AppController.state` stay observable in one place.
  AppState get snapshot => _controller.state;

  AppRole get role => state.role;

  PreviewMode get preview => state.preview;

  Set<String> get saved => state.saved;

  Set<String> get compared => state.compared;

  bool isSaved(String id) => state.isSaved(id);

  bool isCompared(String id) => state.isCompared(id);

  void setRole(AppRole value) => _controller.setRole(value);

  void setPreview(PreviewMode value) => _controller.setPreview(value);

  /// Adds or removes a property from the saved set.
  void toggleSaved(String id) => _controller.toggleSaved(id);

  /// Adds or removes a property from the compare set. The three-entry cap is
  /// enforced by the controller.
  void toggleCompared(String id) => _controller.toggleCompared(id);

  void clearCompared() => _controller.clearCompared();

  /// Replaces the whole state (the web app reseeds from a stored cookie).
  void restore(AppState value) => _controller.restore(value);

  void _publish(AppState next) => state = next;
}

final appNotifierProvider = NotifierProvider<AppNotifier, AppState>(
  AppNotifier.new,
);
