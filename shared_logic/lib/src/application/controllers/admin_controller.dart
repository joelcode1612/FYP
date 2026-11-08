import '../../domain/entities/app_role.dart';
import '../../domain/entities/commercial_property.dart';
import '../../domain/entities/user.dart';
import '../../domain/entities/virtual_tour.dart';
import '../../domain/repositories/admin_repositories.dart';
import '../services/property_service.dart';
import '../services/tour_service.dart';
import '../services/verification_service.dart';
import '../states/admin_state.dart';
import 'state_controller.dart';

/// Admin dashboard/users/verification flow, without `package:bloc`.
///
/// [AdminCubit] adapts this class to a `Stream`; the Jaspr `AdminViewModel`
/// adapts the same instance to a `ChangeNotifier`. The query and count rules
/// are business behaviour and exist in one place.
///
/// Faithful to the cubit's quirks: `setQuery` only changes view state
/// (filtering is derived at read time), `loadPendingTours` does not toggle the
/// [loading] flag, and a failed load surfaces `error` without clearing
/// previously loaded lists.
class AdminController extends StateController<AdminState> {
  final VerificationService _verification;
  final PropertyService _properties;
  final UserRepository _users;
  final TourService _tours;

  AdminController({
    required VerificationService verification,
    required PropertyService properties,
    required UserRepository users,
    required TourService tours,
  }) : _verification = verification,
       _properties = properties,
       _users = users,
       _tours = tours,
       super(const AdminState());

  bool get loading => state.loading;

  String? get error => state.error;

  List<SitewiseUser> get users => state.users;

  List<CommercialProperty> get queue => state.queue;

  List<CommercialProperty> get listings => state.listings;

  List<VirtualTour> get pendingTours => state.pendingTours;

  String get query => state.query;

  /// Listings (including queue items) narrowed by [query].
  List<CommercialProperty> get filteredListings {
    if (state.query.isEmpty) return state.listings;
    final q = state.query.toLowerCase();
    return state.listings
        .where(
          (p) =>
              '${p.title} ${p.city} ${p.state} ${p.address} '
                      '${p.propertyType} ${p.ownerId}'
                  .toLowerCase()
                  .contains(q),
        )
        .toList();
  }

  /// Users narrowed by [query].
  List<SitewiseUser> get filteredUsers {
    if (state.query.isEmpty) return state.users;
    final q = state.query.toLowerCase();
    return state.users
        .where(
          (u) => '${u.name} ${u.email} ${u.role.label} ${u.location}'
              .toLowerCase()
              .contains(q),
        )
        .toList();
  }

  /// Listings per verification status — real counts from [listings].
  int countByStatus(VerificationStatus status) =>
      state.listings.where((p) => p.verification == status).length;

  /// Users marked pending — the real onboarding queue size.
  int get pendingUsers => state.users.where((u) => u.status == 'Pending').length;

  Future<void> loadDashboard() async {
    setState(state.copyWith(loading: true, clearError: true));
    try {
      final queue = await _verification.queue();
      final listings = await _properties.listings();
      final users = await _users.getUsers();
      setState(
        state.copyWith(
          queue: queue,
          listings: listings,
          users: users,
          loading: false,
        ),
      );
    } catch (e) {
      setState(state.copyWith(error: e.toString(), loading: false));
    }
  }

  Future<void> loadUsers() async {
    setState(state.copyWith(loading: true, clearError: true));
    try {
      final users = await _users.getUsers();
      setState(state.copyWith(users: users, loading: false));
    } catch (e) {
      setState(state.copyWith(error: e.toString(), loading: false));
    }
  }

  Future<void> loadPendingTours() async {
    try {
      final pendingTours = await _tours.pendingTours();
      setState(state.copyWith(pendingTours: pendingTours));
    } catch (e) {
      setState(state.copyWith(error: e.toString()));
    }
  }

  void setQuery(String value) => setState(state.copyWith(query: value));

  Future<void> approve(String id) async {
    await _verification.approve(id);
    await loadDashboard();
  }

  Future<void> reject(String id, String reason) async {
    await _verification.reject(id, reason);
    await loadDashboard();
  }

  Future<void> approveTour(String id) async {
    await _tours.approveTour(id);
    await loadPendingTours();
  }

  Future<void> rejectTour(String id) async {
    await _tours.rejectTour(id);
    await loadPendingTours();
  }
}
