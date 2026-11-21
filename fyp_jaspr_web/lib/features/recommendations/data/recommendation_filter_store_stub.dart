/// No-op implementation when Jaspr builds/runs on the Dart VM.
library;

import 'package:shared_logic/shared_logic.dart';

abstract final class RecommendationFilterStore {
  static RecommendationSearchRequest? read() => null;
  static void write(RecommendationSearchRequest request) {}
  static void clear() {}
}
