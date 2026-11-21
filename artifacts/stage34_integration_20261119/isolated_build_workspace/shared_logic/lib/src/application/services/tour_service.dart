import 'package:shared_logic/shared_logic.dart';

/// Virtual-tour lifecycle: draft → processing → ready → submitted
/// (pending verification) → approved / rejected, plus deletion with optional
/// frame cleanup. Owner-facing queries and the entrepreneur visibility gate
/// live here; property verification stays in [VerificationService].
///
/// Frame files live on the device, so the cleanup hook is injected: the
/// mobile app wires the local frame store, the web app passes none and only
/// drops the repository record.
class TourService {
  final TourRepository repo;

  /// Purges capture-frame files for a deleted tour. The mobile composition
  /// root passes the local store's delete; browser builds omit it because
  /// frames never exist there.
  final Future<void> Function(String tourId)? purgeFrames;

  const TourService(this.repo, {this.purgeFrames});

  Future<List<VirtualTour>> toursForOwner(String ownerId) =>
      repo.getToursByOwner(ownerId);

  /// Entrepreneur gate: only approved, published tours resolve.
  Future<VirtualTour?> tourForPropertyApproved(String propertyId) =>
      repo.getTourByProperty(propertyId);

  /// The unfinished capture for [propertyId], if any.
  ///
  /// Backs the Add Property "Resume Previous Capture" action: it answers only
  /// with a draft/processing tour, never with a finished one, so a completed
  /// tour cannot be reopened as if it were an interrupted session.
  Future<VirtualTour?> tourForPropertyDraft(String propertyId) =>
      repo.tourForPropertyDraft(propertyId);

  Future<List<VirtualTour>> pendingTours() => repo.pendingTours();

  Future<VirtualTour?> tourById(String id) => repo.tourById(id);

  Future<VirtualTour> createDraft({
    required String propertyId,
    required String title,
    required int frameCount,
  }) => repo.createDraft(
    propertyId: propertyId,
    title: title,
    frameCount: frameCount,
  );

  Future<void> attachPanorama(String tourId, String panoramaPath) async {
    final tour = await repo.tourById(tourId);
    if (tour == null) throw StateError('Tour not found: $tourId');
    await repo.updateTour(
      tour.copyWith(
        panoramaPath: panoramaPath,
        status: VirtualTourStatus.ready,
      ),
    );
  }

  /// Submit a ready tour for administrator verification. Refuses tours
  /// without a generated panorama.
  Future<void> submitTour(String tourId) async {
    final tour = await repo.tourById(tourId);
    if (tour == null) throw StateError('Tour not found: $tourId');
    if (tour.panoramaPath == null) {
      throw StateError('Generate the panorama before submitting.');
    }
    await repo.updateTour(
      tour.copyWith(status: VirtualTourStatus.pendingVerification),
    );
  }

  Future<void> approveTour(String tourId) async {
    final tour = await repo.tourById(tourId);
    if (tour == null) throw StateError('Tour not found: $tourId');
    await repo.updateTour(
      tour.copyWith(status: VirtualTourStatus.approved, published: true),
    );
  }

  Future<void> rejectTour(String tourId) async {
    final tour = await repo.tourById(tourId);
    if (tour == null) throw StateError('Tour not found: $tourId');
    await repo.updateTour(
      tour.copyWith(status: VirtualTourStatus.rejected, published: false),
    );
  }

  Future<void> deleteTour(String tourId) async {
    await purgeFrames?.call(tourId);
    await repo.deleteTour(tourId);
  }

  /// Frame image paths in capture-sequence order for stitching.
  List<String> orderedFramePaths(List<CapturedFrame> frames) {
    final sorted = List<CapturedFrame>.from(frames)
      ..sort((a, b) => a.frameIndex.compareTo(b.frameIndex));
    return [for (final f in sorted) f.imagePath];
  }
}
