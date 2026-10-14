import 'package:bloc/bloc.dart';

import '../../domain/entities/commercial_property.dart';
import '../../domain/entities/location_intelligence.dart';
import '../../domain/entities/recommendation.dart';
import '../../domain/usecases/property_usecases.dart';
import '../../domain/usecases/recommendation_usecases.dart';
import '../states/entrepreneur_state.dart';
import '../usecases/filter_properties.dart';

/// Browsing, search, filtering and recommendation ranking for the entrepreneur
/// flow.
///
/// Replaces `EntrepreneurViewModel` (Flutter app,
/// `lib/presentation/shared/viewmodels/entrepreneur_viewmodel.dart`).
///
/// The behaviour is a faithful port, including the original's quirks:
/// `loadExplore` clears the previous error before starting, and a failure sets
/// `error` without clearing the previously loaded list.
///
/// The one deliberate change is **how dependencies arrive**. The original read
/// `ServiceLocator.properties`, `ServiceLocator.recommendations` and
/// `ServiceLocator.preferences` — global mutable statics — which made the
/// viewmodel impossible to construct with substitutes or test in isolation.
/// Here the use cases and the initial preferences are constructor parameters, so
/// each app supplies its own implementations from its own composition root.
class EntrepreneurCubit extends Cubit<EntrepreneurState> {
  final GetProperties _getProperties;
  final GetRecommendations _getRecommendations;
  final GetLocationAnalysis _getLocationAnalysis;
  final FilterProperties _filterProperties;
  final void Function(BusinessPreferences preferences)? _onPreferencesUpdated;

  EntrepreneurCubit({
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

  // Read-only projections of the current state, mirroring the field names the
  // Flutter `EntrepreneurViewModel` exposed, so existing UI code reads the same
  // (`vm.loading`, `vm.prefs`, ...) while all writes go through methods that
  // emit a new immutable [EntrepreneurState].
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
    emit(state.copyWith(loading: true, clearError: true));
    try {
      final all = await _getProperties();
      emit(
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
      emit(state.copyWith(error: e.toString(), loading: false));
    }
  }

  /// Ranks recommendations against the current preferences.
  Future<void> loadRecommendations() async {
    emit(state.copyWith(loading: true));
    try {
      final ranked = await _getRecommendations(state.preferences);
      emit(state.copyWith(recommendations: ranked, loading: false));
    } catch (e) {
      emit(state.copyWith(error: e.toString(), loading: false));
    }
  }

  /// Loads the location analysis for one property.
  Future<void> loadAnalysis(String propertyId) async {
    emit(state.copyWith(loading: true));
    try {
      final analysis = await _getLocationAnalysis(propertyId);
      emit(state.copyWith(analysis: analysis, loading: false));
    } catch (e) {
      emit(state.copyWith(error: e.toString(), loading: false));
    }
  }

  /// Updates the query and re-runs the search. Emitting first matters: the
  /// filter reads `state.query`, so the new value must be in state before
  /// [loadExplore] runs.
  void setQuery(String value) {
    emit(state.copyWith(query: value));
    loadExplore();
  }

  void setFilter(String value) {
    emit(state.copyWith(filter: value));
    loadExplore();
  }

  /// Replaces the current preferences.
  ///
  /// The original `EntrepreneurViewModel.updatePreferences` also wrote the new
  /// value into the app-wide `ServiceLocator.preferences` global, because
  /// onboarding and other screens read from there. That side effect is
  /// preserved here through the injected [onPreferencesUpdated] callback (the
  /// app's composition root supplies the write-back); the cubit itself stays
  /// free of globals.
  void updatePreferences(BusinessPreferences value) {
    emit(state.copyWith(preferences: value));
    _onPreferencesUpdated?.call(value);
  }
}
