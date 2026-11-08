import 'package:flutter/foundation.dart';
import 'package:shared_logic/shared_logic.dart';

/// Browsing, search, filtering and recommendation ranking as a Flutter view
/// model.
///
/// A thin [ChangeNotifier] over the shared [EntrepreneurController]: every
/// loading/error transition, the query-then-refilter order and the preference
/// write-back stay in `shared_logic`, where the web app reads them too. This
/// class only turns a new state into a `notifyListeners` call, so a screen
/// rebuilds without any `Stream` subscription.
///
/// Per-screen: each entrepreneur page builds one through
/// `ServiceLocator.newEntrepreneurViewModel()` and exposes it with a
/// `ChangeNotifierProvider`, which disposes it when the route pops — the same
/// lifetime the page's `initState`/`dispose` pair had.
class EntrepreneurViewModel extends ChangeNotifier {
  final EntrepreneurController _controller;

  /// The controller is owned here: [dispose] tears it down.
  EntrepreneurViewModel(this._controller) {
    _controller.addListener(_publish);
  }

  void _publish(EntrepreneurState next) => notifyListeners();

  @override
  void dispose() {
    _controller.removeListener(_publish);
    _controller.dispose();
    super.dispose();
  }

  EntrepreneurState get state => _controller.state;

  bool get loading => _controller.loading;

  String? get error => _controller.error;

  List<CommercialProperty> get explore => _controller.explore;

  List<PropertyRecommendation> get recommendations =>
      _controller.recommendations;

  LocationAnalysis? get analysis => _controller.analysis;

  String get query => _controller.query;

  String get filter => _controller.filter;

  BusinessPreferences get prefs => _controller.prefs;

  Future<void> loadExplore() => _controller.loadExplore();

  Future<void> loadRecommendations() => _controller.loadRecommendations();

  Future<void> loadAnalysis(String propertyId) =>
      _controller.loadAnalysis(propertyId);

  void setQuery(String value) => _controller.setQuery(value);

  void setFilter(String value) => _controller.setFilter(value);

  void updatePreferences(BusinessPreferences value) =>
      _controller.updatePreferences(value);
}
