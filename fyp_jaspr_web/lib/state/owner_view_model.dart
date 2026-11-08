import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

/// Owner listings, tours and submissions as a Jaspr view model.
///
/// A thin [ChangeNotifier] over the shared [OwnerController] — the filter and
/// count rules are business behaviour and are not re-expressed here. Only the
/// notification mechanism is Jaspr's: a new state becomes `notifyListeners`,
/// never a `Stream` event.
///
/// Per-page: built through `AppLocator` and exposed with
/// `ChangeNotifierProvider`, which disposes it (and its controller) when the
/// route unmounts.
class OwnerViewModel extends ChangeNotifier {
  final OwnerController _controller;

  /// The controller is owned here: [dispose] tears it down.
  OwnerViewModel(this._controller) {
    _controller.addListener(_publish);
  }

  void _publish(OwnerState next) => notifyListeners();

  @override
  void dispose() {
    _controller.removeListener(_publish);
    _controller.dispose();
    super.dispose();
  }

  OwnerState get state => _controller.state;

  bool get loading => _controller.loading;

  String? get error => _controller.error;

  List<CommercialProperty> get properties => _controller.properties;

  List<VirtualTour> get tours => _controller.tours;

  String get query => _controller.query;

  VerificationStatus? get statusFilter => _controller.statusFilter;

  List<CommercialProperty> get filteredProperties =>
      _controller.filteredProperties;

  int countByStatus(VerificationStatus status) =>
      _controller.countByStatus(status);

  int get withTourCount => _controller.withTourCount;

  Future<void> load() => _controller.load();

  void setQuery(String value) => _controller.setQuery(value);

  void setStatusFilter(VerificationStatus? value) =>
      _controller.setStatusFilter(value);

  Future<void> submit(String id) => _controller.submit(id);

  Future<void> submitTour(String tourId) => _controller.submitTour(tourId);

  Future<void> deleteTour(String tourId) => _controller.deleteTour(tourId);
}
