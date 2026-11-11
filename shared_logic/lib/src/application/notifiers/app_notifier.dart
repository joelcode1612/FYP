import 'package:riverpod/riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/errors/app_failure.dart';
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

  /// Reads the account's shortlist from `public.favourite_property`.
  ///
  /// Previously nothing ever called the saved-properties repository on mobile:
  /// the tab showed an in-memory set that started empty on every launch, so a
  /// saved property vanished after a restart even though the server had it.
  /// A failure is reported on the state — never turned into an empty list.
  Future<void> loadSaved() async {
    final repo = ref.read(savedPropertiesRepositoryProvider);
    if (repo == null) {
      // Demo build: the local set is the only truth, and saying otherwise
      // would invent a server that does not exist.
      return;
    }
    if (state.savedLoading) return;
    _controller.setSavedLoading(true);
    _controller.setSavedError(null);
    try {
      final refs = await repo.savedRefs();
      if (!ref.mounted) return;
      _controller.setSaved(refs);
    } on Object catch (error) {
      if (!ref.mounted) return;
      _controller.setSavedError(
        error is AppFailure
            ? error.userMessage
            : 'Your saved properties could not be loaded.',
      );
    } finally {
      if (ref.mounted) _controller.setSavedLoading(false);
    }
  }

  /// Saves/unsaves against the server FIRST, then moves the shortlist.
  ///
  /// Returns the failure message, or null on success. The optimistic local
  /// toggle is deliberately not used here: the tab must never show a saved
  /// state the backend did not accept.
  Future<String?> persistSaved(String propertyRef, {required bool wantSaved}) async {
    final repo = ref.read(savedPropertiesRepositoryProvider);
    if (repo == null) {
      // Demo build: no server, so the local toggle IS the operation.
      _controller.toggleSaved(propertyRef);
      return null;
    }
    try {
      if (wantSaved) {
        await repo.save(propertyRef);
      } else {
        await repo.unsave(propertyRef);
      }
      final next = {...state.saved};
      if (wantSaved) {
        next.add(propertyRef);
      } else {
        next.remove(propertyRef);
      }
      if (ref.mounted) _controller.setSaved(next);
      return null;
    } on Object catch (error) {
      return error is AppFailure
          ? error.userMessage
          : 'The saved list could not be updated. Please try again.';
    }
  }

  /// Replaces the whole state (the web app reseeds from a stored cookie).
  void restore(AppState value) => _controller.restore(value);

  void _publish(AppState next) => state = next;
}

final appNotifierProvider = NotifierProvider<AppNotifier, AppState>(
  AppNotifier.new,
);
