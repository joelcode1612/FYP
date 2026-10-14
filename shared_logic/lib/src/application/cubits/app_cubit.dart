import 'package:bloc/bloc.dart';

import '../../core/constants/app_constants.dart';
import '../../domain/entities/app_role.dart';
import '../states/app_state.dart';

/// App-wide UI state: active role, preview override, saved and compare sets.
///
/// Direct translation of the Flutter `AppState extends ChangeNotifier`. `Cubit`
/// is used rather than `Bloc` because the original API is imperative method
/// calls (`toggleSaved(id)`), which map one-to-one onto cubit methods. Events
/// would add a layer of indirection without adding behaviour.
///
/// `bloc` is pure Dart — no Flutter dependency — which is precisely why this
/// class can live in the shared package and be consumed by both apps.
class AppCubit extends Cubit<AppState> {
  AppCubit([AppState? initial]) : super(initial ?? const AppState());

  // Read-only projections of the current state.
  //
  // The Flutter UI reads `appState.role`, `appState.isSaved(id)` etc. directly
  // (it used to mutate a ChangeNotifier). These getters keep that read syntax
  // valid while every *write* still goes through the methods below and emits a
  // new immutable [AppState]. They must never be used to bypass `emit`.
  AppRole get role => state.role;

  PreviewMode get preview => state.preview;

  Set<String> get saved => state.saved;

  Set<String> get compared => state.compared;

  bool isSaved(String id) => state.isSaved(id);

  bool isCompared(String id) => state.isCompared(id);

  void setRole(AppRole value) => emit(state.copyWith(role: value));

  void setPreview(PreviewMode value) => emit(state.copyWith(preview: value));

  /// Adds or removes a property from the saved set.
  void toggleSaved(String id) {
    final next = {...state.saved};
    if (!next.remove(id)) next.add(id);
    emit(state.copyWith(saved: next));
  }

  /// Adds or removes a property from the compare set.
  ///
  /// Preserves the original rule: adding a fourth entry is a no-op rather than
  /// an error, and removing is always allowed.
  void toggleCompared(String id) {
    final next = {...state.compared};
    if (!next.remove(id)) {
      if (next.length >= AppState.maxCompare) return;
      next.add(id);
    }
    emit(state.copyWith(compared: next));
  }

  void clearCompared() => emit(state.copyWith(compared: const <String>{}));
}
