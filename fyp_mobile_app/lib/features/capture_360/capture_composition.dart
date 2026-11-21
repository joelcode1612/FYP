/// Composition root for the 360° capture engines.
///
/// ONLY this file constructs concrete camera, ARCore, storage and stitching
/// implementations. Screens pass their optional test seams here; application
/// controllers receive interfaces and never import Data. The capture
/// algorithms themselves are untouched — this file only assembles them.
library;

import 'dart:typed_data';

import 'package:fyp/core/permissions/permission_service.dart';
import 'package:fyp/features/capture_360/application/capture_controller.dart';
import 'package:fyp/features/capture_360/data/repositories/capture_repository_impl.dart';
import 'package:fyp/features/capture_360/data/services/ar_session_service.dart';
import 'package:fyp/features/capture_360/data/services/photo_capture_service.dart';
import 'package:fyp/features/capture_360/data/services/plane_anchor_service.dart';
import 'package:fyp/features/capture_360/data/stitch/incremental_stitch_service.dart';
import 'package:fyp/features/capture_360/data/platform/arcore_ar.dart';
import 'package:fyp/features/capture_360/data/sphere/equirectangular_stitcher.dart';
import 'package:fyp/features/capture_360/data/sphere/jpeg_normalizer.dart';
import 'package:fyp/features/capture_360/data/sphere/platform/rotation_sensor.dart';
import 'package:fyp/features/capture_360/data/sphere/platform/sphere_camera.dart';
import 'package:fyp/features/capture_360/domain/services/panorama_stitcher.dart';

import 'domain/services/target_sphere.dart';

/// ARCore capture graph. Every argument is identical to the previous inline
/// construction in `CaptureModuleScreen._boot`; only its location moved.
Future<CaptureController> createArCaptureController({
  required CaptureGeometryConfig geometry,
  required String? stationId,
  CaptureRepository? repository,
  IncrementalStitchService? stitchService,
}) async {
  await PermissionService().ensureCapturePermissions();
  final resolvedRepository = repository ?? await FileCaptureRepository.create();
  final host = ArCoreHost();
  final session = ArSessionService(host);
  final anchors = PlaneAnchorService(host, geometry: geometry);
  final photos = PhotoCaptureService(
    host: host,
    repository: resolvedRepository,
  );
  return CaptureController(
    session: session,
    anchors: anchors,
    photos: photos,
    repository: resolvedRepository,
    geometry: geometry,
    defaultStationId: stationId,
    incrementalStitch: stitchService,
  );
}

/// Default sphere concretions (camera, rotation, normalizer). Screens may
/// inject their own test doubles; production uses these exact implementations.
class SphereCaptureDefaults {
  const SphereCaptureDefaults();

  RotationSource get rotation => NativeRotationSource();
  SphereCamera get camera => PluginSphereCamera();
  Future<NormalizedJpeg> Function(Uint8List bytes) get normalize =>
      const JpegNormalizer().normalize;
  PanoramaStitcher get stitcher => const EquirectangularStitcher();
}

/// The production default set, constructed once per capture start.
SphereCaptureDefaults createSphereDefaults() => const SphereCaptureDefaults();
