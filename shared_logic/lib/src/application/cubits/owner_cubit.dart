import 'package:bloc/bloc.dart';

import '../../domain/entities/commercial_property.dart';
import '../../domain/entities/virtual_tour.dart';
import '../services/property_service.dart';
import '../services/tour_service.dart';
import '../states/owner_state.dart';

/// Owner dashboard/properties/tours flow.
///
/// Replaces the Flutter `OwnerViewModel`
/// (`fyp_mobile_app/lib/application/viewmodels/owner_viewmodel.dart`) now that
/// the owner screens exist in both the Flutter and the Jaspr app — the
/// filter/count rules are business behaviour and must not be duplicated.
///
/// Behaviour is a faithful port, including the original's quirks:
/// `setQuery`/`setStatusFilter` only change view state (filtering is derived
/// at read time), and a failed load surfaces `error` without clearing the
/// previously loaded lists.
class OwnerCubit extends Cubit<OwnerState> {
  final PropertyService _properties;
  final TourService _tours;

  OwnerCubit({
    required PropertyService properties,
    required TourService tours,
    required String ownerId,
  }) : _properties = properties,
       _tours = tours,
       super(OwnerState(ownerId: ownerId));

  // Read-only projections of the current state, mirroring the field names the
  // Flutter `OwnerViewModel` exposed, so existing UI code reads the same
  // (`vm.loading`, `vm.properties`, ...) while all writes go through methods
  // that emit a new immutable [OwnerState].
  bool get loading => state.loading;

  String? get error => state.error;

  List<CommercialProperty> get properties => state.properties;

  List<VirtualTour> get tours => state.tours;

  String get query => state.query;

  VerificationStatus? get statusFilter => state.statusFilter;

  /// Owner listings narrowed by the current [query] and [statusFilter].
  /// Pure view-state derivation — no new data source.
  List<CommercialProperty> get filteredProperties {
    return state.properties.where((p) {
      final matchesQuery =
          state.query.isEmpty ||
          '${p.title} ${p.city} ${p.state} ${p.address} ${p.propertyType}'
              .toLowerCase()
              .contains(state.query.toLowerCase());
      final matchesStatus =
          state.statusFilter == null || p.verification == state.statusFilter;
      return matchesQuery && matchesStatus;
    }).toList();
  }

  /// Listings per verification status — real counts from [properties].
  int countByStatus(VerificationStatus status) =>
      state.properties.where((p) => p.verification == status).length;

  /// Listings carrying a published 360° tour.
  int get withTourCount => state.properties.where((p) => p.hasTour).length;

  Future<void> load() async {
    final ownerId = state.ownerId;
    emit(state.copyWith(loading: true, clearError: true));
    try {
      final properties = await _properties.ownerListings(ownerId);
      final tours = await _tours.toursForOwner(ownerId);
      emit(
        state.copyWith(properties: properties, tours: tours, loading: false),
      );
    } catch (e) {
      emit(state.copyWith(error: e.toString(), loading: false));
    }
  }

  void setQuery(String value) => emit(state.copyWith(query: value));

  void setStatusFilter(VerificationStatus? value) {
    // copyWith cannot express "set to null" (null means unchanged), so
    // clearing the filter takes an explicit branch.
    if (value == null) {
      emit(state.copyWith(clearStatusFilter: true));
    } else {
      emit(state.copyWith(statusFilter: value));
    }
  }

  Future<void> submit(String id) async {
    await _properties.submit(id);
    await load();
  }

  Future<void> submitTour(String tourId) async {
    await _tours.submitTour(tourId);
    await load();
  }

  Future<void> deleteTour(String tourId) async {
    await _tours.deleteTour(tourId);
    await load();
  }
}
