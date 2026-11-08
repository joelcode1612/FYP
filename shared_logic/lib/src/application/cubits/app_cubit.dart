import 'package:bloc/bloc.dart';

import '../../core/constants/app_constants.dart';
import '../../domain/entities/app_role.dart';
import '../controllers/app_controller.dart';
import '../states/app_state.dart';

/// Cubit facade over [AppController].
///
/// Every transition lives in the controller; this class only mirrors it into a
/// `Stream` for callers that still speak cubit (shared tests, mobile screens
/// that have not switched to `provider` yet). The web app binds
/// [AppController] directly through a `ChangeNotifier` and never constructs
/// this.
class AppCubit extends Cubit<AppState> {
  final AppController _controller;

  AppCubit([AppState? initial])
    : _controller = AppController(initial),
      super(initial ?? const AppState()) {
    _controller.addListener(_publish);
  }

  /// The controller's state object, exposed so `AppCubit.state` and
  /// `AppController.state` cannot drift apart.
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

  void _publish(AppState next) {
    if (!isClosed) super.emit(next);
  }

  @override
  Future<void> close() {
    _controller.removeListener(_publish);
    _controller.dispose();
    return super.close();
  }
}
