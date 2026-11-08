import 'package:riverpod/riverpod.dart';

import '../../domain/entities/commercial_property.dart';
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

  void _publish(EntrepreneurState next) => state = next;
}

/// Page-scoped: destroyed once no screen is watching it anymore.
final entrepreneurNotifierProvider =
    NotifierProvider.autoDispose<EntrepreneurNotifier, EntrepreneurState>(
      EntrepreneurNotifier.new,
    );
