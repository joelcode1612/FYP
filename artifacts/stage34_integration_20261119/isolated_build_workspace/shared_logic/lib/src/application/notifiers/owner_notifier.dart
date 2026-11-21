import 'package:riverpod/riverpod.dart';

import '../../domain/entities/commercial_property.dart';
import '../../domain/entities/virtual_tour.dart';
import '../controllers/owner_controller.dart';
import '../states/owner_state.dart';
import 'providers.dart';

/// Notifier facade over [OwnerController], scoped to one owner id.
///
/// Every transition lives in the controller; this class only mirrors it into
/// the provider, which is why the filter/count rules cannot drift between the
/// mobile and web apps. The owner id arrives as the family argument — one
/// notifier instance per signed-in owner.
class OwnerNotifier extends Notifier<OwnerState> {
  OwnerNotifier(this.ownerId);

  final String ownerId;

  late OwnerController _controller;

  @override
  OwnerState build() {
    _controller = OwnerController(
      properties: ref.watch(propertyServiceProvider),
      tours: ref.watch(tourServiceProvider),
      ownerId: ownerId,
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
  // `properties`, ...) while all writes go through methods that publish a new
  // immutable [OwnerState].
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

  void _publish(OwnerState next) => state = next;
}

/// One auto-disposed instance per owner id.
final ownerNotifierProvider =
    NotifierProvider.autoDispose.family<OwnerNotifier, OwnerState, String>(
      OwnerNotifier.new,
    );
