import '../../core/constants/app_constants.dart';
import '../../domain/entities/app_role.dart';

/// Immutable snapshot of the app-wide UI state.
///
/// Replaces `AppState extends ChangeNotifier` (in the Flutter app's
/// `lib/application/state/app_state.dart`). The behaviour is unchanged — role,
/// preview override, a saved set and a compare set capped at three — but the
/// state is now a value object emitted by a [AppCubit], so it can be shared with
/// the Jaspr app and tested without a Flutter binding.
class AppState {
  /// Comparison is capped at three properties. Kept here rather than in the
  /// cubit so the limit is visible next to the data it constrains.
  static const int maxCompare = 3;

  final AppRole role;
  final PreviewMode preview;
  final Set<String> saved;
  final Set<String> compared;

  const AppState({
    this.role = AppRole.entrepreneur,
    this.preview = PreviewMode.auto,
    this.saved = const <String>{},
    this.compared = const <String>{},
  });

  bool isSaved(String id) => saved.contains(id);

  bool isCompared(String id) => compared.contains(id);

  AppState copyWith({
    AppRole? role,
    PreviewMode? preview,
    Set<String>? saved,
    Set<String>? compared,
  }) {
    return AppState(
      role: role ?? this.role,
      preview: preview ?? this.preview,
      saved: saved ?? this.saved,
      compared: compared ?? this.compared,
    );
  }
}
