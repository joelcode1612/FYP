import '../errors/app_failure.dart';

/// Minimal HTTP contract for the future remote layer. Demo repositories do
/// not use this; a Supabase/REST datasource will implement it later without
/// touching domain or presentation.
abstract class ApiClient {
  Future<Map<String, dynamic>> get(String path, {Map<String, String>? query});

  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body);
}

/// Thrown when code calls the network while [AppConfig.usesDemoData].
class DemoModeFailure extends AppFailure {
  const DemoModeFailure() : super('Network is disabled in demo-data mode.');
}
