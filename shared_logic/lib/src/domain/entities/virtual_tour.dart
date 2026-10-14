/// Lifecycle of a 360° virtual tour from capture to publication.
enum VirtualTourStatus {
  draft,
  processing,
  ready,
  pendingVerification,
  approved,
  rejected,
}

/// 360° virtual tour metadata. The capture pipeline fills [panoramaPath]
/// and [status]; only approved tours are visible to entrepreneurs.
class VirtualTour {
  final String id;
  final String propertyId;
  final String title;
  final int sceneCount;
  final DateTime capturedAt;
  final bool published;
  final VirtualTourStatus status;
  final String? panoramaPath;
  final int frameCount;

  const VirtualTour({
    required this.id,
    required this.propertyId,
    required this.title,
    required this.sceneCount,
    required this.capturedAt,
    required this.published,
    this.status = VirtualTourStatus.draft,
    this.panoramaPath,
    this.frameCount = 0,
  });

  VirtualTour copyWith({
    String? title,
    int? sceneCount,
    bool? published,
    VirtualTourStatus? status,
    String? panoramaPath,
    int? frameCount,
  }) => VirtualTour(
    id: id,
    propertyId: propertyId,
    title: title ?? this.title,
    sceneCount: sceneCount ?? this.sceneCount,
    capturedAt: capturedAt,
    published: published ?? this.published,
    status: status ?? this.status,
    panoramaPath: panoramaPath ?? this.panoramaPath,
    frameCount: frameCount ?? this.frameCount,
  );
}
