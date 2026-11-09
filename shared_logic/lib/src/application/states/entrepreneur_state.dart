import '../../domain/entities/commercial_property.dart';
import '../../domain/entities/explore.dart';
import '../../domain/entities/location_intelligence.dart';
import '../../domain/entities/recommendation.dart';

/// State for the entrepreneur browsing flow.
///
/// Replaces the mutable public fields on the Flutter `EntrepreneurViewModel`.
/// The field set is identical; making them `final` means every update goes
/// through [copyWith] and is emitted, so a UI can never observe a half-applied
/// change (the old code mutated several fields and then called
/// `notifyListeners()`).
///
/// Loading is split deliberately (§12 of the integration brief): loading a
/// location analysis must never block or clear an already loaded Explore
/// list, and refreshing the list after a filter change must not blank the
/// grid the user is looking at. [loading] means "first load, nothing to
/// show yet"; [listRefreshing] and [analysisLoading] are the in-place
/// progress signals.
class EntrepreneurState {
  /// First load of the session: nothing displayed yet. Filter re-runs use
  /// [listRefreshing] instead so the visible list stays mounted.
  final bool loading;

  /// A filter/query change or explicit refresh is re-running the Explore
  /// search. The previous results stay visible underneath.
  final bool listRefreshing;

  /// A location analysis for [analysisPropertyId] is in flight.
  final bool analysisLoading;

  final String? error;

  /// Analysis failures are separate from list errors: a failed analysis must
  /// not replace the Explore grid's "Try again" state.
  final String? analysisError;

  /// The property id the current analysis (or in-flight analysis request)
  /// belongs to. A response for a different id is stale and is dropped by
  /// the controller instead of overwriting newer state.
  final String? analysisPropertyId;

  /// Listings matching the current [query] and [filter].
  final List<CommercialProperty> explore;

  /// Server-reported total for the current search (server-driven Explore
  /// only). Null when the source is a client-filtered full listing, where
  /// `explore.length` is already the whole truth.
  final int? exploreTotal;

  /// True when another page exists beyond [explore] (server-driven Explore).
  final bool exploreHasMore;

  /// Database-backed filter facets from `GET /explore/options`, when the
  /// composition root supplied a server-driven Explore repository.
  final ExploreFilterOptions? filterOptions;

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
    this.listRefreshing = false,
    this.analysisLoading = false,
    this.error,
    this.analysisError,
    this.analysisPropertyId,
    this.explore = const [],
    this.exploreTotal,
    this.exploreHasMore = false,
    this.filterOptions,
    this.recommendations = const [],
    this.analysis,
    this.query = '',
    this.filter = 'All',
  });

  EntrepreneurState copyWith({
    bool? loading,
    bool? listRefreshing,
    bool? analysisLoading,
    String? error,
    bool clearError = false,
    String? analysisError,
    bool clearAnalysisError = false,
    String? analysisPropertyId,
    List<CommercialProperty>? explore,
    int? exploreTotal,
    bool clearExploreTotal = false,
    bool? exploreHasMore,
    ExploreFilterOptions? filterOptions,
    List<PropertyRecommendation>? recommendations,
    LocationAnalysis? analysis,
    String? query,
    String? filter,
    BusinessPreferences? preferences,
  }) {
    return EntrepreneurState(
      preferences: preferences ?? this.preferences,
      loading: loading ?? this.loading,
      listRefreshing: listRefreshing ?? this.listRefreshing,
      analysisLoading: analysisLoading ?? this.analysisLoading,
      // `clearError` exists because `error: null` cannot be distinguished from
      // "leave the error unchanged" in a copyWith signature.
      error: clearError ? null : (error ?? this.error),
      analysisError: clearAnalysisError
          ? null
          : (analysisError ?? this.analysisError),
      analysisPropertyId: analysisPropertyId ?? this.analysisPropertyId,
      explore: explore ?? this.explore,
      exploreTotal: clearExploreTotal
          ? null
          : (exploreTotal ?? this.exploreTotal),
      exploreHasMore: exploreHasMore ?? this.exploreHasMore,
      filterOptions: filterOptions ?? this.filterOptions,
      recommendations: recommendations ?? this.recommendations,
      analysis: analysis ?? this.analysis,
      query: query ?? this.query,
      filter: filter ?? this.filter,
    );
  }
}
