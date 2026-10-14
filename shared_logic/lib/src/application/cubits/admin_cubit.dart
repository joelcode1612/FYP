import 'package:bloc/bloc.dart';

import '../../domain/entities/app_role.dart';
import '../../domain/entities/commercial_property.dart';
import '../../domain/entities/user.dart';
import '../../domain/entities/virtual_tour.dart';
import '../../domain/repositories/admin_repositories.dart';
import '../services/property_service.dart';
import '../services/tour_service.dart';
import '../services/verification_service.dart';
import '../states/admin_state.dart';

/// Admin dashboard/users/verification flow.
///
/// Replaces the Flutter `AdminViewModel`
/// (`fyp_mobile_app/lib/application/viewmodels/admin_viewmodel.dart`) now that
/// the admin screens exist in both the Flutter and the Jaspr app — the
/// query/count rules are business behaviour and must not be duplicated.
///
/// Behaviour is a faithful port, including the original's quirks:
/// `setQuery` only changes view state (filtering is derived at read time),
/// `loadPendingTours` does not toggle the [loading] flag, and a failed load
/// surfaces `error` without clearing previously loaded lists.
class AdminCubit extends Cubit<AdminState> {
  final VerificationService _verification;
  final PropertyService _properties;
  final UserRepository _users;
  final TourService _tours;

  AdminCubit({
    required VerificationService verification,
    required PropertyService properties,
    required UserRepository users,
    required TourService tours,
  }) : _verification = verification,
       _properties = properties,
       _users = users,
       _tours = tours,
       super(const AdminState());

  // Read-only projections of the current state, mirroring the field names the
  // Flutter `AdminViewModel` exposed, so existing UI code reads the same
  // (`vm.loading`, `vm.queue`, ...) while all writes go through methods that
  // emit a new immutable [AdminState].
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
  int get pendingUsers =>
      state.users.where((u) => u.status == 'Pending').length;

  Future<void> loadDashboard() async {
    emit(state.copyWith(loading: true, clearError: true));
    try {
      final queue = await _verification.queue();
      final listings = await _properties.listings();
      final users = await _users.getUsers();
      emit(
        state.copyWith(
          queue: queue,
          listings: listings,
          users: users,
          loading: false,
        ),
      );
    } catch (e) {
      emit(state.copyWith(error: e.toString(), loading: false));
    }
  }

  Future<void> loadUsers() async {
    emit(state.copyWith(loading: true, clearError: true));
    try {
      final users = await _users.getUsers();
      emit(state.copyWith(users: users, loading: false));
    } catch (e) {
      emit(state.copyWith(error: e.toString(), loading: false));
    }
  }

  Future<void> loadPendingTours() async {
    try {
      final pendingTours = await _tours.pendingTours();
      emit(state.copyWith(pendingTours: pendingTours));
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
  }

  void setQuery(String value) => emit(state.copyWith(query: value));

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
