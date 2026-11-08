import 'package:bloc/bloc.dart';

import '../../domain/entities/commercial_property.dart';
import '../../domain/entities/virtual_tour.dart';
import '../controllers/owner_controller.dart';
import '../services/property_service.dart';
import '../services/tour_service.dart';
import '../states/owner_state.dart';

/// Cubit facade over [OwnerController].
///
/// Every transition lives in the controller; this class only mirrors it into a
/// `Stream` for callers that still speak cubit. The web app binds the
/// controller directly through a `ChangeNotifier` and never constructs this,
/// which is why the filter/count rules cannot drift between platforms.
class OwnerCubit extends Cubit<OwnerState> {
  final OwnerController _controller;

  OwnerCubit({
    required PropertyService properties,
    required TourService tours,
    required String ownerId,
  }) : _controller = OwnerController(
         properties: properties,
         tours: tours,
         ownerId: ownerId,
       ),
       super(OwnerState(ownerId: ownerId)) {
    _controller.addListener(_publish);
  }

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
  List<CommercialProperty> get filteredProperties =>
      _controller.filteredProperties;

  /// Listings per verification status — real counts from [properties].
  int countByStatus(VerificationStatus status) =>
      _controller.countByStatus(status);

  /// Listings carrying a published 360° tour.
  int get withTourCount => _controller.withTourCount;

  Future<void> load() => _controller.load();

  void setQuery(String value) => _controller.setQuery(value);

  void setStatusFilter(VerificationStatus? value) =>
      _controller.setStatusFilter(value);

  Future<void> submit(String id) => _controller.submit(id);

  Future<void> submitTour(String tourId) => _controller.submitTour(tourId);

  Future<void> deleteTour(String tourId) => _controller.deleteTour(tourId);

  void _publish(OwnerState next) {
    if (!isClosed) super.emit(next);
  }

  @override
  Future<void> close() {
    _controller.removeListener(_publish);
    _controller.dispose();
    return super.close();
  }
}
