import '../../core/errors/app_failure.dart';
import '../../domain/entities/commercial_property.dart';
import '../../domain/entities/explore.dart';
import '../../domain/entities/location_intelligence.dart';
import '../../domain/entities/recommendation.dart';
import '../../domain/repositories/explore_repository.dart';
import '../../domain/usecases/property_usecases.dart';
import '../../domain/usecases/recommendation_usecases.dart';
import '../states/entrepreneur_state.dart';
import '../usecases/filter_properties.dart';
import 'state_controller.dart';

/// Browsing, search, filtering and recommendation ranking for the entrepreneur
/// flow, without `package:bloc`.
///
/// [EntrepreneurCubit] is a thin adapter over this class, and the Jaspr
/// `EntrepreneurViewModel` is a thin adapter over the same instance, so the
/// loading/error transitions below are written exactly once.
///
/// Two data paths, one state owner:
///
///  * **Server-driven** — when the composition root supplies an
///    [ExploreRepository], [loadExplore] runs a real `/explore/properties`
///    search (server-side filtering, sorting and pagination) and
///    [loadMore] appends pages. [exploreTotal]/[exploreHasMore] carry the
///    server's paging metadata.
///  * **Client-driven** — otherwise [loadExplore] loads the full listing set
///    once and [FilterProperties] applies the query/filter locally. This is
///    the demo-data path and the web catalogue path.
///
/// Race safety: every asynchronous load carries a sequence number, so a slow
/// response triggered by an earlier query can never overwrite the results of
/// a newer one, and a disposed controller never publishes. Analysis loads
/// additionally drop responses whose property id no longer matches the latest
/// request.
///
/// The behaviour is a faithful port of the original cubit, including its
/// documented quirks: `loadExplore` clears the previous error before starting,
/// and a failure sets `error` without clearing the previously loaded list.
class EntrepreneurController extends StateController<EntrepreneurState> {
  final GetProperties _getProperties;
  final GetRecommendations _getRecommendations;
  final GetLocationAnalysis _getLocationAnalysis;
  final FilterProperties _filterProperties;
  final ExploreRepository? _exploreRepository;
  final void Function(BusinessPreferences preferences)? _onPreferencesUpdated;

  /// Monotonic guards against stale asynchronous responses.
  int _exploreSeq = 0;
  int _analysisSeq = 0;

  /// Rows fetched from the server for the CURRENT search, before the
  /// client-side filter may have trimmed them. The pagination offset must
  /// count raw server rows — using the post-filtered list length would skip
  /// rows whenever the filter removes any.
  int _serverFetched = 0;

  EntrepreneurController({
    required GetProperties getProperties,
    required GetRecommendations getRecommendations,
    required GetLocationAnalysis getLocationAnalysis,
    required BusinessPreferences preferences,
    FilterProperties filterProperties = const FilterProperties(),
    ExploreRepository? exploreRepository,
    void Function(BusinessPreferences preferences)? onPreferencesUpdated,
  }) : _getProperties = getProperties,
       _getRecommendations = getRecommendations,
       _getLocationAnalysis = getLocationAnalysis,
       _exploreRepository = exploreRepository,
       _filterProperties = filterProperties,
       _onPreferencesUpdated = onPreferencesUpdated,
       super(EntrepreneurState(preferences: preferences));

  bool get loading => state.loading;

  String? get error => state.error;

  List<CommercialProperty> get explore => state.explore;

  List<PropertyRecommendation> get recommendations => state.recommendations;

  LocationAnalysis? get analysis => state.analysis;

  String get query => state.query;

  String get filter => state.filter;

  BusinessPreferences get prefs => state.preferences;

  /// Whether [loadExplore]/[loadMore] run real server searches.
  bool get isServerDriven => _exploreRepository != null;

  /// True while another page of the current server search is in flight.
  bool get _isLoadingMore => state.listRefreshing && state.explore.isNotEmpty;

  /// The server query for one page: the stored criteria (filters, sort,
  /// page size) with the live free-text query and pagination offset applied.
  /// The free-text filter string stays a client-side vocabulary (it matches
  /// type OR city via [FilterProperties]), so it is deliberately NOT sent as
  /// a server parameter beyond the backend's own `q` search.
  ExploreQuery _serverQuery({required int offset}) =>
      state.exploreCriteria.copyWith(query: state.query, offset: offset);

  /// Loads listings, then applies the current query and filter.
  ///
  /// The first call of a session shows the loading surface ([loading]);
  /// subsequent re-runs (filter edits, query changes) refresh in place with
  /// the previous results still visible.
  Future<void> loadExplore() async {
    final firstLoad = state.explore.isEmpty && !state.listRefreshing;
    final seq = ++_exploreSeq;
    setState(
      state.copyWith(
        loading: firstLoad,
        listRefreshing: !firstLoad,
        clearError: true,
      ),
    );
    try {
      final repo = _exploreRepository;
      if (repo != null) {
        _serverFetched = 0;
        final page = await repo.search(_serverQuery(offset: 0));
        if (seq != _exploreSeq || isDisposed) return;
        _serverFetched = page.items.length;
        // The server already applied the free-text `q` against
        // name/address/city/type; re-checking it here would drop rows the
        // server matched on a field the client predicate does not know (e.g.
        // property type). The predicate runs with an empty query, keeping
        // only the string-vocabulary filter — which stays 'All' on this
        // path — as a final consistency pass.
        setState(
          state.copyWith(
            explore: _filterProperties(
              properties: page.items,
              query: '',
              filter: state.filter,
            ),
            exploreTotal: page.total,
            exploreHasMore: page.hasMore,
            loading: false,
            listRefreshing: false,
            clearError: true,
            clearExploreFailure: true,
          ),
        );
        // Facets are fetched once per session; a failure leaves the current
        // (possibly derived) options untouched rather than failing the page.
        if (state.filterOptions == null) {
          try {
            final options = await repo.filterOptions();
            if (seq == _exploreSeq && !isDisposed) {
              setState(state.copyWith(filterOptions: options));
            }
          } on Object {
            // Facets are enhancement data; the search result stands alone.
          }
        }
        return;
      }
      final all = await _getProperties();
      if (seq != _exploreSeq || isDisposed) return;
      setState(
        state.copyWith(
          explore: _filterProperties(
            properties: all,
            query: state.query,
            filter: state.filter,
          ),
          loading: false,
          listRefreshing: false,
          clearError: true,
        ),
      );
    } catch (e) {
      if (seq != _exploreSeq || isDisposed) return;
      setState(
        state.copyWith(
          error: readableFailure(
            e,
            fallback: 'We could not load listings. Please try again.',
          ),
          exploreFailure: e,
          loading: false,
          listRefreshing: false,
        ),
      );
    }
  }

  /// Appends the next page of the current server search. No-op on the
  /// client-driven path (its full listing is already loaded) and while a
  /// page is already in flight, so double taps cannot duplicate rows.
  Future<void> loadMore() async {
    final repo = _exploreRepository;
    if (repo == null || !state.exploreHasMore || _isLoadingMore) return;
    final seq = ++_exploreSeq;
    setState(state.copyWith(listRefreshing: true));
    try {
      final page = await repo.search(_serverQuery(offset: _serverFetched));
      if (seq != _exploreSeq || isDisposed) return;
      _serverFetched += page.items.length;
      final existingIds = state.explore.map((p) => p.id).toSet();
      setState(
        state.copyWith(
          explore: [
            ...state.explore,
            // A server-side race between search and refresh can resend a row;
            // the visible list must never show it twice.
            for (final p in _filterProperties(
              properties: page.items,
              query: '',
              filter: state.filter,
            ))
              if (!existingIds.contains(p.id)) p,
          ],
          exploreTotal: page.total,
          exploreHasMore: page.hasMore,
          listRefreshing: false,
          clearError: true,
          clearExploreFailure: true,
        ),
      );
    } catch (e) {
      if (seq != _exploreSeq || isDisposed) return;
      setState(
        state.copyWith(
          error: readableFailure(
            e,
            fallback: 'We could not load more listings. Please try again.',
          ),
          exploreFailure: e,
          listRefreshing: false,
        ),
      );
    }
  }

  /// Ranks recommendations against the current preferences.
  ///
  /// A failed request must be distinguishable from a genuine empty result, so
  /// the previous error is cleared on *every* new attempt and on success, and
  /// the failed list is left untouched rather than rendered as "no matches".
  Future<void> loadRecommendations() async {
    setState(state.copyWith(loading: true, clearError: true));
    try {
      final ranked = await _getRecommendations(state.preferences);
      if (isDisposed) return;
      setState(
        state.copyWith(
          recommendations: ranked,
          loading: false,
          clearError: true,
        ),
      );
    } catch (e) {
      if (isDisposed) return;
      setState(
        state.copyWith(
          error: readableFailure(
            e,
            fallback: 'We could not load recommendations. Please try again.',
          ),
          loading: false,
        ),
      );
    }
  }

  /// Loads the location analysis for one property.
  ///
  /// Runs on its own loading flag ([analysisLoading]) so an in-flight
  /// analysis never blocks or blanks the Explore list. A response that
  /// arrives after a newer analysis request started (or after disposal) is
  /// dropped, never published.
  Future<void> loadAnalysis(String propertyId) async {
    final seq = ++_analysisSeq;
    setState(
      state.copyWith(
        analysisLoading: true,
        analysisPropertyId: propertyId,
        clearAnalysisError: true,
      ),
    );
    try {
      final analysis = await _getLocationAnalysis(propertyId);
      if (seq != _analysisSeq || isDisposed) return;
      setState(
        state.copyWith(
          analysis: analysis,
          analysisLoading: false,
          analysisPropertyId: propertyId,
          clearAnalysisError: true,
        ),
      );
    } catch (e) {
      if (seq != _analysisSeq || isDisposed) return;
      setState(
        state.copyWith(
          analysisError: readableFailure(
            e,
            fallback:
                'We could not load the location analysis. Please try again.',
          ),
          analysisLoading: false,
        ),
      );
    }
  }

  /// Updates the query and re-runs the search. Applying the new state first
  /// matters: the filter reads `state.query`, so the value must be visible
  /// before [loadExplore] runs. The server criteria object is kept in sync
  /// so the next page request carries the same term.
  ///
  /// [reload] is false when the caller is about to change the criteria too:
  /// saving the query without searching lets a single [setExploreCriteria]
  /// perform one request instead of two.
  void setQuery(String value, {bool reload = true}) {
    setState(
      state.copyWith(
        query: value,
        exploreCriteria: state.exploreCriteria.copyWith(query: value),
      ),
    );
    if (reload) loadExplore();
  }

  /// Replaces the server-driven search criteria (filters, sort, page size)
  /// and re-runs the search from the first page. Pagination resets because
  /// [_serverQuery] derives every request from this object. The demo /
  /// client-driven path ignores the criteria (its full listing is already
  /// in memory) but still stores them so a later live wiring inherits the
  /// last chosen filters.
  void setExploreCriteria(ExploreQuery criteria) {
    setState(state.copyWith(exploreCriteria: criteria));
    loadExplore();
  }

  void setFilter(String value) {
    setState(state.copyWith(filter: value));
    loadExplore();
  }

  /// Replaces the current preferences.
  ///
  /// The write-back to the app's preferences store stays a callback so this
  /// class holds no globals; each composition root supplies it.
  void updatePreferences(BusinessPreferences value) {
    setState(state.copyWith(preferences: value));
    _onPreferencesUpdated?.call(value);
  }
}
