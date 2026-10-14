import '../entities/commercial_property.dart';
import '../entities/user.dart';
import '../entities/virtual_tour.dart';

abstract class VerificationRepository {
  Future<List<CommercialProperty>> getPendingQueue();
  Future<void> verify(String propertyId);
  Future<void> reject(String propertyId, String reason);
}

abstract class UserRepository {
  Future<List<SitewiseUser>> getUsers();
  Future<SitewiseUser?> getUserById(String id);
}

abstract class TourRepository {
  Future<List<VirtualTour>> getToursByOwner(String ownerId);
  Future<VirtualTour?> getTourByProperty(String propertyId);
  Future<VirtualTour?> tourById(String id);
  Future<List<VirtualTour>> pendingTours();
  Future<VirtualTour> createDraft({
    required String propertyId,
    required String title,
    required int frameCount,
  });
  Future<void> updateTour(VirtualTour tour);
  Future<void> deleteTour(String id);
}
