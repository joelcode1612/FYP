/// Shared failure types. Repositories throw these; ViewModels translate
/// them into error states. No exceptions leak raw SDK errors to UI.
abstract class AppFailure implements Exception {
  final String message;
  const AppFailure(this.message);

  @override
  String toString() => message;
}

class NetworkFailure extends AppFailure {
  const NetworkFailure([super.message = 'Unable to reach the server.']);
}

class NotFoundFailure extends AppFailure {
  const NotFoundFailure([super.message = 'The requested item was not found.']);
}

class ValidationFailure extends AppFailure {
  const ValidationFailure([super.message = 'Some fields need attention.']);
}

class CacheFailure extends AppFailure {
  const CacheFailure([super.message = 'Unable to load local data.']);
}
