import '../../domain/entities/commercial_property.dart';
import '../../domain/entities/location_intelligence.dart';
import '../../domain/entities/recommendation.dart';

/// State for the entrepreneur browsing flow.
///
/// Replaces the mutable public fields on the Flutter `EntrepreneurViewModel`.
/// The field set is identical; making them `final` means every update goes
/// through [copyWith] and is emitted, so a UI can never observe a half-applied
/// change (the old code mutated several fields and then called
/// `notifyListeners()`).
class EntrepreneurState {
  final bool loading;
  final String? error;

  /// Listings matching the current [query] and [filter].
  final List<CommercialProperty> explore;

  final List<PropertyRecommendation> recommendations;
  final LocationAnalysis? analysis;

  final String query;
  final String filter;

  /// The preferences used for ranking. Held in state rather than read from a
  /// global, so the cubit is self-contained and testable.
  final BusinessPreferences preferences;

  const EntrepreneurState({
    required this.preferences,
    this.loading = false,
    this.error,
    this.explore = const [],
    this.recommendations = const [],
    this.analysis,
    this.query = '',
    this.filter = 'All',
  });

  EntrepreneurState copyWith({
    bool? loading,
    String? error,
    bool clearError = false,
    List<CommercialProperty>? explore,
    List<PropertyRecommendation>? recommendations,
    LocationAnalysis? analysis,
    String? query,
    String? filter,
    BusinessPreferences? preferences,
  }) {
    return EntrepreneurState(
      preferences: preferences ?? this.preferences,
      loading: loading ?? this.loading,
      // `clearError` exists because `error: null` cannot be distinguished from
      // "leave the error unchanged" in a copyWith signature.
      error: clearError ? null : (error ?? this.error),
      explore: explore ?? this.explore,
      recommendations: recommendations ?? this.recommendations,
      analysis: analysis ?? this.analysis,
      query: query ?? this.query,
      filter: filter ?? this.filter,
    );
  }
}
