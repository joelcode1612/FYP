import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

/// Admin dashboard, users, verification queue and tour approvals as a Jaspr
/// view model.
///
/// A thin [ChangeNotifier] over the shared [AdminController], which holds the
/// query/filter and count rules — including its documented quirks: `setQuery`
/// only changes view state (filtering is derived at read time),
/// `loadPendingTours` does not toggle [loading], and a failed load surfaces
/// [error] without clearing the lists already loaded.
///
/// Per-page: built through `AppLocator` and exposed with
/// `ChangeNotifierProvider`, which disposes it (and its controller) when the
/// route unmounts.
class AdminViewModel extends ChangeNotifier {
  final AdminController _controller;

  /// The controller is owned here: [dispose] tears it down.
  AdminViewModel(this._controller) {
    _controller.addListener(_publish);
  }

  void _publish(AdminState next) => notifyListeners();

  @override
  void dispose() {
    _controller.removeListener(_publish);
    _controller.dispose();
    super.dispose();
  }

  AdminState get state => _controller.state;

  bool get loading => _controller.loading;

  String? get error => _controller.error;

  List<SitewiseUser> get users => _controller.users;

  List<CommercialProperty> get queue => _controller.queue;

  List<CommercialProperty> get listings => _controller.listings;

  List<VirtualTour> get pendingTours => _controller.pendingTours;

  String get query => _controller.query;

  List<CommercialProperty> get filteredListings => _controller.filteredListings;

  List<SitewiseUser> get filteredUsers => _controller.filteredUsers;

  int countByStatus(VerificationStatus status) =>
      _controller.countByStatus(status);

  int get pendingUsers => _controller.pendingUsers;

  Future<void> loadDashboard() => _controller.loadDashboard();

  Future<void> loadUsers() => _controller.loadUsers();

  Future<void> loadPendingTours() => _controller.loadPendingTours();

  void setQuery(String value) => _controller.setQuery(value);

  Future<void> approve(String id) => _controller.approve(id);

  Future<void> reject(String id, String reason) =>
      _controller.reject(id, reason);

  Future<void> approveTour(String id) => _controller.approveTour(id);

  Future<void> rejectTour(String id) => _controller.rejectTour(id);
}
