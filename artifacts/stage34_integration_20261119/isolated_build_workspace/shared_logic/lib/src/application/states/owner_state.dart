import '../../domain/entities/commercial_property.dart';
import '../../domain/entities/virtual_tour.dart';

/// State for the property-owner flow (dashboard, properties, tours).
///
/// Replaces the mutable public fields on the Flutter `OwnerViewModel`
/// (`fyp_mobile_app/lib/application/viewmodels/owner_viewmodel.dart`).
class OwnerState {
  final bool loading;
  final String? error;
  final List<CommercialProperty> properties;
  final List<VirtualTour> tours;

  /// The owner whose data is loaded; re-loads after mutations reuse it.
  final String ownerId;

  /// Current owner-scoped search text (drives Home and Properties filtering).
  final String query;

  /// Verification-status filter, or `null` for all listings.
  final VerificationStatus? statusFilter;

  const OwnerState({
    required this.ownerId,
    this.loading = false,
    this.error,
    this.properties = const [],
    this.tours = const [],
    this.query = '',
    this.statusFilter,
  });

  OwnerState copyWith({
    bool? loading,
    String? error,
    bool clearError = false,
    List<CommercialProperty>? properties,
    List<VirtualTour>? tours,
    String? ownerId,
    String? query,
    VerificationStatus? statusFilter,
    bool clearStatusFilter = false,
  }) {
    return OwnerState(
      ownerId: ownerId ?? this.ownerId,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
      properties: properties ?? this.properties,
      tours: tours ?? this.tours,
      query: query ?? this.query,
      statusFilter: clearStatusFilter
          ? null
          : (statusFilter ?? this.statusFilter),
    );
  }
}
