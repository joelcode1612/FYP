import '../../domain/entities/commercial_property.dart';
import '../../domain/entities/user.dart';
import '../../domain/entities/virtual_tour.dart';
import '../../domain/repositories/admin_repositories.dart';
import '../datasources/local/demo_data.dart';
import '../../domain/repositories/property_repository.dart';

class VerificationRepositoryImpl implements VerificationRepository {
  final PropertyRepository properties;
  VerificationRepositoryImpl(this.properties);

  @override
  Future<List<CommercialProperty>> getPendingQueue() async {
    final all = await properties.getProperties();
    return all
        .where((p) => p.verification == VerificationStatus.pending)
        .toList();
  }

  @override
  Future<void> verify(String propertyId) =>
      properties.updateVerification(propertyId, VerificationStatus.verified);

  @override
  Future<void> reject(String propertyId, String reason) =>
      properties.updateVerification(propertyId, VerificationStatus.rejected);
}

class UserRepositoryImpl implements UserRepository {
  @override
  Future<List<SitewiseUser>> getUsers() async => DemoData.users;

  @override
  Future<SitewiseUser?> getUserById(String id) async {
    for (final u in DemoData.users) {
      if (u.id == id) return u;
    }
    return null;
  }
}

class TourRepositoryImpl implements TourRepository {
  List<VirtualTour>? _tours;

  List<VirtualTour> get _store {
    _tours ??= List<VirtualTour>.from(DemoData.tours);
    return _tours!;
  }

  @override
  Future<List<VirtualTour>> getToursByOwner(String ownerId) async {
    final ownedIds = DemoData.properties
        .where((p) => p.ownerId == ownerId)
        .map((p) => p.id)
        .toSet();
    return _store.where((t) => ownedIds.contains(t.propertyId)).toList();
  }

  @override
  Future<VirtualTour?> getTourByProperty(String propertyId) async {
    // Entrepreneur gate: only approved, published tours are visible.
    for (final t in _store) {
      if (t.propertyId == propertyId &&
          t.published &&
          t.status == VirtualTourStatus.approved) {
        return t;
      }
    }
    return null;
  }

  @override
  Future<VirtualTour?> tourById(String id) async {
    for (final t in _store) {
      if (t.id == id) return t;
    }
    return null;
  }

  @override
  Future<List<VirtualTour>> pendingTours() async => _store
      .where((t) => t.status == VirtualTourStatus.pendingVerification)
      .toList();

  @override
  Future<VirtualTour> createDraft({
    required String propertyId,
    required String title,
    required int frameCount,
  }) async {
    final tour = VirtualTour(
      id: 't-${DateTime.now().millisecondsSinceEpoch}',
      propertyId: propertyId,
      title: title,
      sceneCount: frameCount,
      capturedAt: DateTime.now(),
      published: false,
      status: VirtualTourStatus.draft,
      frameCount: frameCount,
    );
    _store.add(tour);
    return tour;
  }

  @override
  Future<void> updateTour(VirtualTour tour) async {
    final i = _store.indexWhere((t) => t.id == tour.id);
    if (i >= 0) _store[i] = tour;
  }

  @override
  Future<void> deleteTour(String id) async {
    _store.removeWhere((t) => t.id == id);
  }
}
