import '../../core/constants/app_constants.dart';
import '../../domain/entities/app_role.dart';
import '../states/app_state.dart';
import 'state_controller.dart';

/// App-wide UI state: active role, preview override, saved and compare sets.
///
/// This is the framework-free half of [AppCubit] — the same transitions, the
/// same rules, no `package:bloc` in sight — so the Jaspr app can drive it from
/// a `ChangeNotifier` while the Flutter app keeps consuming the cubit. The two
/// never diverge because the cubit forwards here rather than duplicating the
/// writes.
class AppController extends StateController<AppState> {
  AppController([AppState? initial]) : super(initial ?? const AppState());

  AppRole get role => state.role;

  PreviewMode get preview => state.preview;

  Set<String> get saved => state.saved;

  Set<String> get compared => state.compared;

  bool isSaved(String id) => state.isSaved(id);

  bool isCompared(String id) => state.isCompared(id);

  void setRole(AppRole value) => setState(state.copyWith(role: value));

  void setPreview(PreviewMode value) => setState(state.copyWith(preview: value));

  /// Adds or removes a property from the saved set.
  void toggleSaved(String id) {
    final next = {...state.saved};
    if (!next.remove(id)) next.add(id);
    setState(state.copyWith(saved: next));
  }

  /// Adds a property to the comparison set.
  ///
  /// Returns false when the three-property cap was reached and the set was
  /// left untouched, so a screen can explain the limit instead of silently
  /// ignoring the tap. Removing an already selected property always succeeds.
  bool addCompared(String id) {
    final next = {...state.compared};
    if (!next.add(id)) return true;
    if (next.length > AppState.maxCompare) return false;
    setState(state.copyWith(compared: next));
    return true;
  }

  /// Adds or removes a property from the compare set.
  ///
  /// The three-entry cap is enforced by the controller: adding a fourth entry
  /// is a no-op rather than an error, and removing is always allowed.
  void toggleCompared(String id) {
    final next = {...state.compared};
    if (!next.remove(id)) {
      if (next.length >= AppState.maxCompare) return;
      next.add(id);
    }
    setState(state.copyWith(compared: next));
  }

  void clearCompared() => setState(state.copyWith(compared: const <String>{}));

  /// Replaces the shortlist with the account's authoritative copy.
  ///
  /// Used after a server read (and after a confirmed save/unsave), so the
  /// displayed set can never drift from `public.favourite_property`.
  void setSaved(Set<String> value) =>
      setState(state.copyWith(saved: value, clearSavedError: true));

  /// Marks the shortlist as loading / idle without touching its contents, so
  /// a refresh keeps showing the current rows instead of blanking them.
  void setSavedLoading(bool value) =>
      setState(state.copyWith(savedLoading: value));

  void setSavedError(String? message) => setState(
    message == null
        ? state.copyWith(clearSavedError: true)
        : state.copyWith(savedError: message),
  );

  /// Replaces the whole state, used by the cookie-seeded install path.
  void restore(AppState value) => setState(value);
}
