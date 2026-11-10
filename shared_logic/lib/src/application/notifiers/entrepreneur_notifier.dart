import 'package:riverpod/riverpod.dart';

import '../../domain/entities/commercial_property.dart';
import '../../domain/entities/explore.dart';
import '../../domain/entities/location_intelligence.dart';
import '../../domain/entities/recommendation.dart';
import '../controllers/entrepreneur_controller.dart';
import '../states/entrepreneur_state.dart';
import 'providers.dart';

/// Notifier facade over [EntrepreneurController].
///
/// Every transition lives in the controller; this class only mirrors it into
/// the provider, which is why the loading/error rules cannot drift between
/// the mobile and web apps.
///
/// Dependencies arrive through the composition-root providers in
/// `providers.dart`, so each app supplies its own implementations and tests
/// can substitute fakes with provider overrides.
class EntrepreneurNotifier extends Notifier<EntrepreneurState> {
  late EntrepreneurController _controller;

  @override
  EntrepreneurState build() {
    _controller = EntrepreneurController(
      getProperties: ref.watch(getPropertiesProvider),
      getRecommendations: ref.watch(getRecommendationsProvider),
      getLocationAnalysis: ref.watch(getLocationAnalysisProvider),
      preferences: ref.watch(businessPreferencesProvider),
      exploreRepository: ref.watch(exploreRepositoryProvider),
      onPreferencesUpdated: ref.watch(onPreferencesUpdatedProvider),
    );
    _controller.addListener(_publish);
    ref.onDispose(() {
      _controller.removeListener(_publish);
      _controller.dispose();
    });
    return _controller.state;
  }

  // Read-only projections of the current state, mirroring the field names the
  // old viewmodels exposed, so existing UI code reads the same (`loading`,
  // `prefs`, ...) while all writes go through methods that publish a new
  // immutable [EntrepreneurState].
  bool get loading => state.loading;

  /// In-place refresh signal: a filter/query re-run is in flight while the
  /// previous results stay visible.
  bool get listRefreshing => state.listRefreshing;

  /// A location analysis is in flight (does not touch [loading]).
  bool get analysisLoading => state.analysisLoading;

  String? get error => state.error;

  /// Analysis failures are separate from list errors.
  String? get analysisError => state.analysisError;

  /// The property the current/in-flight analysis belongs to.
  String? get analysisPropertyId => state.analysisPropertyId;

  List<CommercialProperty> get explore => state.explore;

  /// Server-reported total for the current search, when server-driven.
  int? get exploreTotal => state.exploreTotal;

  /// True when [loadMore] can fetch another page (server-driven only).
  bool get exploreHasMore => state.exploreHasMore;

  /// Database-backed filter facets when an [ExploreRepository] is wired.
  ExploreFilterOptions? get filterOptions => state.filterOptions;

  /// The criteria (filters, sort, page size) currently driving the
  /// server-driven search. Meaningful only when [isServerDriven].
  ExploreQuery get exploreCriteria => state.exploreCriteria;

  /// True when [loadExplore]/[loadMore] run real server searches.
  bool get isServerDriven => state.filterOptions != null ||
      state.exploreTotal != null || _controller.isServerDriven;

  /// The classified failure behind [error] (connection / session / server /
  /// contract), for UIs that distinguish the states. Null when there is no
  /// error or the failure carried no classification.
  Object? get exploreFailure => state.exploreFailure;

  List<PropertyRecommendation> get recommendations => state.recommendations;

  LocationAnalysis? get analysis => state.analysis;

  String get query => state.query;

  String get filter => state.filter;

  BusinessPreferences get prefs => state.preferences;

  /// Loads listings: a real server search when an ExploreRepository is wired,
  /// otherwise the client-filtered full listing.
  Future<void> loadExplore() => _controller.loadExplore();

  /// Appends the next server page. No-op on the client-driven path.
  Future<void> loadMore() => _controller.loadMore();

  /// Ranks recommendations against the current preferences.
  Future<void> loadRecommendations() => _controller.loadRecommendations();

  /// Loads the location analysis for one property. Runs on its own loading
  /// flag; an in-flight analysis never blocks the Explore list.
  Future<void> loadAnalysis(String propertyId) =>
      _controller.loadAnalysis(propertyId);

  /// Pass [reload]: false when a criteria change will immediately follow, so
  /// the pair produces one request instead of two.
  void setQuery(String value, {bool reload = true}) =>
      _controller.setQuery(value, reload: reload);

  void setFilter(String value) => _controller.setFilter(value);

  /// Replaces the server-driven search criteria (filters, sort, page size)
  /// and re-runs the search from the first page.
  void setExploreCriteria(ExploreQuery criteria) =>
      _controller.setExploreCriteria(criteria);

  /// Replaces the current preferences. The write-back to the app's preferences
  /// store stays a callback supplied by the composition root.
  void updatePreferences(BusinessPreferences value) =>
      _controller.updatePreferences(value);

  void _publish(EntrepreneurState next) => state = next;
}

/// Page-scoped: destroyed once no screen is watching it anymore.
final entrepreneurNotifierProvider =
    NotifierProvider.autoDispose<EntrepreneurNotifier, EntrepreneurState>(
      EntrepreneurNotifier.new,
    );
