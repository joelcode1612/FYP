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

  /// The unfinished capture for [propertyId], if one exists.
  ///
  /// "Unfinished" means a tour whose capture has not been handed in for review:
  /// [VirtualTourStatus.draft] or [VirtualTourStatus.processing]. Approved,
  /// pending-verification, ready and rejected tours are never resumable — a
  /// finished tour must not be overwritten by a new capture, and a rejected one
  /// is a review decision, not a lost session.
  ///
  /// More than one draft can exist for a property (a restarted capture, a
  /// re-submission). The newest by [VirtualTour.capturedAt] wins, with the id as
  /// a deterministic tie-break, so "Resume" always opens the same session.
  Future<VirtualTour?> tourForPropertyDraft(String propertyId);

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
