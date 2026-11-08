/// Shared failure types. Repositories throw these; ViewModels translate
/// them into error states. No exceptions leak raw SDK errors to UI.
abstract class AppFailure implements Exception {
  final String message;
  const AppFailure(this.message);

  /// Short, user-facing text for this failure class. Deliberately generic:
  /// it never includes SDK, HTTP or stack details.
  String get userMessage => 'Something went wrong. Please try again.';

  @override
  String toString() => message;
}

class NetworkFailure extends AppFailure {
  const NetworkFailure([super.message = 'Unable to reach the server.']);

  @override
  String get userMessage =>
      'Unable to reach Sitewise. Check your connection and try again.';
}

class NotFoundFailure extends AppFailure {
  const NotFoundFailure([super.message = 'The requested item was not found.']);

  @override
  String get userMessage => 'We could not find what you were looking for.';
}

class ValidationFailure extends AppFailure {
  const ValidationFailure([super.message = 'Some fields need attention.']);

  @override
  String get userMessage =>
      'Some details need attention. Please check and try again.';
}

class CacheFailure extends AppFailure {
  const CacheFailure([super.message = 'Unable to load local data.']);

  @override
  String get userMessage =>
      'We could not read your saved data. Please try again.';
}

/// Converts *any* thrown object into a readable, non-technical message.
///
/// Widgets and cubits must call this instead of interpolating `e.toString()`,
/// which can surface raw SDK/network text to the user. Unknown errors always
/// collapse to [fallback] so no implementation detail leaks.
String readableFailure(Object error, {required String fallback}) {
  if (error is AppFailure) return error.userMessage;
  return fallback;
}
