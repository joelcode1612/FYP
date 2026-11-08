import '../../core/errors/app_failure.dart';
import '../../domain/entities/commercial_property.dart';
import '../../domain/entities/location_intelligence.dart';
import '../../domain/entities/recommendation.dart';
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
/// The behaviour is a faithful port of the cubit, including its documented
/// quirks: `loadExplore` clears the previous error before starting, and a
/// failure sets `error` without clearing the previously loaded list.
class EntrepreneurController extends StateController<EntrepreneurState> {
  final GetProperties _getProperties;
  final GetRecommendations _getRecommendations;
  final GetLocationAnalysis _getLocationAnalysis;
  final FilterProperties _filterProperties;
  final void Function(BusinessPreferences preferences)? _onPreferencesUpdated;

  EntrepreneurController({
    required GetProperties getProperties,
    required GetRecommendations getRecommendations,
    required GetLocationAnalysis getLocationAnalysis,
    required BusinessPreferences preferences,
    FilterProperties filterProperties = const FilterProperties(),
    void Function(BusinessPreferences preferences)? onPreferencesUpdated,
  }) : _getProperties = getProperties,
       _getRecommendations = getRecommendations,
       _getLocationAnalysis = getLocationAnalysis,
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

  /// Loads all listings, then applies the current query and filter.
  Future<void> loadExplore() async {
    setState(state.copyWith(loading: true, clearError: true));
    try {
      final all = await _getProperties();
      setState(
        state.copyWith(
          explore: _filterProperties(
            properties: all,
            query: state.query,
            filter: state.filter,
          ),
          loading: false,
        ),
      );
    } catch (e) {
      setState(
        state.copyWith(
          error: readableFailure(
            e,
            fallback: 'We could not load listings. Please try again.',
          ),
          loading: false,
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
      setState(
        state.copyWith(
          recommendations: ranked,
          loading: false,
          clearError: true,
        ),
      );
    } catch (e) {
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
  Future<void> loadAnalysis(String propertyId) async {
    setState(state.copyWith(loading: true, clearError: true));
    try {
      final analysis = await _getLocationAnalysis(propertyId);
      setState(
        state.copyWith(analysis: analysis, loading: false, clearError: true),
      );
    } catch (e) {
      setState(
        state.copyWith(
          error: readableFailure(
            e,
            fallback: 'We could not load the location analysis. Please try again.',
          ),
          loading: false,
        ),
      );
    }
  }

  /// Updates the query and re-runs the search. Applying the new state first
  /// matters: the filter reads `state.query`, so the value must be visible
  /// before [loadExplore] runs.
  void setQuery(String value) {
    setState(state.copyWith(query: value));
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
