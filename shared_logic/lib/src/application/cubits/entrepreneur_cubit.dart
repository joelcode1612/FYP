import 'package:bloc/bloc.dart';

import '../../domain/entities/commercial_property.dart';
import '../../domain/entities/location_intelligence.dart';
import '../../domain/entities/recommendation.dart';
import '../../domain/usecases/property_usecases.dart';
import '../../domain/usecases/recommendation_usecases.dart';
import '../controllers/entrepreneur_controller.dart';
import '../states/entrepreneur_state.dart';
import '../usecases/filter_properties.dart';

/// Cubit facade over [EntrepreneurController].
///
/// Every transition lives in the controller; this class only mirrors it into a
/// `Stream` for callers that still speak cubit. The web app binds the
/// controller directly through a `ChangeNotifier` and never constructs this,
/// which is why the loading/error rules cannot drift between platforms.
///
/// The one deliberate change from the original Flutter viewmodel is **how
/// dependencies arrive**. It read `ServiceLocator.properties`,
/// `ServiceLocator.recommendations` and `ServiceLocator.preferences` — global
/// mutable statics — which made it impossible to construct with substitutes or
/// test in isolation. Here the use cases and the initial preferences are
/// constructor parameters, so each app supplies its own implementations from
/// its own composition root.
class EntrepreneurCubit extends Cubit<EntrepreneurState> {
  final EntrepreneurController _controller;

  EntrepreneurCubit({
    required GetProperties getProperties,
    required GetRecommendations getRecommendations,
    required GetLocationAnalysis getLocationAnalysis,
    required BusinessPreferences preferences,
    FilterProperties filterProperties = const FilterProperties(),
    void Function(BusinessPreferences preferences)? onPreferencesUpdated,
  }) : _controller = EntrepreneurController(
         getProperties: getProperties,
         getRecommendations: getRecommendations,
         getLocationAnalysis: getLocationAnalysis,
         preferences: preferences,
         filterProperties: filterProperties,
         onPreferencesUpdated: onPreferencesUpdated,
       ),
       super(EntrepreneurState(preferences: preferences)) {
    _controller.addListener(_publish);
  }

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
  Future<void> loadExplore() => _controller.loadExplore();

  /// Ranks recommendations against the current preferences.
  Future<void> loadRecommendations() => _controller.loadRecommendations();

  /// Loads the location analysis for one property.
  Future<void> loadAnalysis(String propertyId) =>
      _controller.loadAnalysis(propertyId);

  void setQuery(String value) => _controller.setQuery(value);

  void setFilter(String value) => _controller.setFilter(value);

  /// Replaces the current preferences. The write-back to the app's preferences
  /// store stays a callback supplied by the composition root.
  void updatePreferences(BusinessPreferences value) =>
      _controller.updatePreferences(value);

  void _publish(EntrepreneurState next) {
    if (!isClosed) super.emit(next);
  }

  @override
  Future<void> close() {
    _controller.removeListener(_publish);
    _controller.dispose();
    return super.close();
  }
}
