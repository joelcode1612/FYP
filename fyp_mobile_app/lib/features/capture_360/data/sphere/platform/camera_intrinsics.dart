import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:fyp/features/capture_360/domain/sphere/adaptive_sphere_plan.dart';

/// The rear camera's real optical parameters, as the platform reports them.
///
/// ## Why this exists
///
/// Every coverage, overlap and projection number in the 360° pipeline is scaled
/// by one quantity: the focal length in pixels. Until this channel existed that
/// quantity was an **assumption** — a documented 65° vertical field of view —
/// which is honest but only approximately right. A focal that is 8% wrong makes
/// the planned spacing 8% too loose (a real gap at the seam) or the projected
/// panorama 8% too wide (stretched pixels, smeared seams).
///
/// So the device is asked what it knows. Every field is nullable and the whole
/// object is only produced when the platform actually reported the numbers
/// needed to compute a focal — there is no partial calibration and no defaulted
/// value pretending to be measured.
///
/// ## What is deliberately *not* here
///
/// * **Preview dimensions.** The preview is cropped and scaled by CameraX; using
///   it as if it were the photograph's size is the mistake this class exists to
///   avoid. Only the sensor rasters are reported.
/// * **Distortion coefficients.** Camera2 does not expose a lens distortion
///   model for the rear camera on this class of device. None is invented: the
///   projection stays pinhole, and the report says so.
/// * **Zoom.** The capture flow never changes zoom, so the reported focal
///   describes every frame. If a future version added zoom, the profile would
///   have to be re-derived — it is not silently assumed to hold.
@immutable
class CameraIntrinsics {
  const CameraIntrinsics({
    required this.available,
    this.cameraId,
    this.focalLengthMm,
    this.sensorWidthMm,
    this.sensorHeightMm,
    this.focalPxSensor,
    this.pixelArrayWidth,
    this.pixelArrayHeight,
    this.activeArrayWidth,
    this.activeArrayHeight,
    this.activeArrayLeft,
    this.activeArrayTop,
    this.sensorOrientation,
    this.horizontalFovDeg,
    this.verticalFovDeg,
    this.apiLevel,
    this.unavailableReason,
  });

  /// Whether the platform reported enough to compute a focal length.
  final bool available;

  /// Why the read failed, when it did. Logged, never shown to the photographer
  /// as a capture error — the plan simply falls back to its documented
  /// assumption.
  final String? unavailableReason;

  final String? cameraId;
  final double? focalLengthMm;
  final double? sensorWidthMm;
  final double? sensorHeightMm;

  /// Focal length in **pixel-array** pixels.
  final double? focalPxSensor;

  final int? pixelArrayWidth;
  final int? pixelArrayHeight;
  final int? activeArrayWidth;
  final int? activeArrayHeight;
  final int? activeArrayLeft;
  final int? activeArrayTop;

  /// `SENSOR_ORIENTATION` — degrees the sensor is rotated relative to the
  /// device's natural orientation (90 on a typical phone).
  final int? sensorOrientation;

  final double? horizontalFovDeg;
  final double? verticalFovDeg;
  final int? apiLevel;

  /// The saved JPEG's dimensions, in **portrait** orientation.
  ///
  /// Derived from the active array (the raster the still is taken from) and
  /// swapped when the sensor is mounted rotated, because the app is locked to
  /// portrait and the saved file is portrait. Returns `null` when the platform
  /// did not report a raster.
  ({int width, int height})? get portraitRaster {
    var width = activeArrayWidth ?? pixelArrayWidth;
    var height = activeArrayHeight ?? pixelArrayHeight;
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    final rotation = sensorOrientation ?? 0;
    if (rotation == 90 || rotation == 270) {
      final swap = width;
      width = height;
      height = swap;
    }
    return (width: width, height: height);
  }

  /// Focal length in the pixels of [portraitRaster], or `null`.
  ///
  /// The reported focal is expressed in the pixel array. A still is taken from
  /// the active array, which is the same lens sampled on a (usually slightly
  /// smaller) grid, so the focal scales by the raster ratio — the physical focal
  /// does not change. Skipping this step would make a device with a 4-pixel
  /// optical-black border look 0.1% wide, and a device that crops 10% would be
  /// out by 10%.
  double? focalPxForRaster(({int width, int height}) raster) {
    final focal = focalPxSensor;
    if (focal == null || focal <= 0) return null;
    final arrayWidth = pixelArrayWidth;
    final activeWidth = activeArrayWidth;
    if (arrayWidth != null &&
        arrayWidth > 0 &&
        activeWidth != null &&
        activeWidth > 0) {
      final landscapeFocal = focal * (activeWidth / arrayWidth);
      // The raster may have been swapped to portrait; focal is isotropic so it
      // is unchanged by the swap.
      return landscapeFocal;
    }
    return focal;
  }

  /// A [SphereCameraProfile] the plan can be evaluated against, or `null` when
  /// the device did not report real intrinsics.
  ///
  /// Returns `null` rather than a partially-filled profile: a plan built on a
  /// half-known lens would claim `source: 'calibrated'` for numbers that are
  /// partly assumed, and the guidance UI is required to tell those apart.
  ///
  /// A plausibility gate rejects obviously inconsistent reports (a focal that
  /// implies a field of view outside 30°–120° means the physical-size or raster
  /// values do not describe the same lens), because a bad calibrated profile is
  /// worse than the conservative assumption.
  SphereCameraProfile? toSphereProfile() {
    if (!available) return null;
    final raster = portraitRaster;
    if (raster == null) return null;
    final focal = focalPxForRaster(raster);
    if (focal == null || focal <= 0) return null;

    final profile = SphereCameraProfile.calibrated(
      imageWidth: raster.width,
      imageHeight: raster.height,
      focalPx: focal,
    );
    if (profile.verticalFovDeg < 30 || profile.verticalFovDeg > 120) {
      return null;
    }
    if (profile.horizontalFovDeg < 30 || profile.horizontalFovDeg > 120) {
      return null;
    }
    return profile;
  }

  /// Everything a report needs to state how the plan's lens was established.
  Map<String, Object?> toJson() => <String, Object?>{
    'available': available,
    'cameraId': cameraId,
    'focalLengthMm': focalLengthMm,
    'sensorWidthMm': sensorWidthMm,
    'sensorHeightMm': sensorHeightMm,
    'focalPxSensor': focalPxSensor,
    'pixelArray': pixelArrayWidth == null || pixelArrayHeight == null
        ? null
        : '${pixelArrayWidth}x$pixelArrayHeight',
    'activeArray': activeArrayWidth == null || activeArrayHeight == null
        ? null
        : '${activeArrayWidth}x$activeArrayHeight'
              '+$activeArrayLeft+$activeArrayTop',
    'sensorOrientation': sensorOrientation,
    'horizontalFovDeg': horizontalFovDeg,
    'verticalFovDeg': verticalFovDeg,
    'apiLevel': apiLevel,
    'unavailableReason': unavailableReason,
    'portraitRaster': portraitRaster == null
        ? null
        : '${portraitRaster!.width}x${portraitRaster!.height}',
  };

  static CameraIntrinsics fromMap(Map<Object?, Object?> map) {
    double? asDouble(Object? value) => value is num ? value.toDouble() : null;
    int? asInt(Object? value) => value is num ? value.toInt() : null;
    return CameraIntrinsics(
      available: map['available'] == true,
      cameraId: map['cameraId']?.toString(),
      focalLengthMm: asDouble(map['focalLengthMm']),
      sensorWidthMm: asDouble(map['sensorWidthMm']),
      sensorHeightMm: asDouble(map['sensorHeightMm']),
      focalPxSensor: asDouble(map['focalPxSensor']),
      pixelArrayWidth: asInt(map['pixelArrayWidth']),
      pixelArrayHeight: asInt(map['pixelArrayHeight']),
      activeArrayWidth: asInt(map['activeArrayWidth']),
      activeArrayHeight: asInt(map['activeArrayHeight']),
      activeArrayLeft: asInt(map['activeArrayLeft']),
      activeArrayTop: asInt(map['activeArrayTop']),
      sensorOrientation: asInt(map['sensorOrientation']),
      horizontalFovDeg: asDouble(map['horizontalFovDeg']),
      verticalFovDeg: asDouble(map['verticalFovDeg']),
      apiLevel: asInt(map['apiLevel']),
    );
  }

  static const CameraIntrinsics unavailable = CameraIntrinsics(
    available: false,
    unavailableReason: 'not read',
  );
}

/// Reads the rear camera's intrinsics from the Kotlin host.
///
/// Best-effort by contract: any failure — an unsupported platform, a channel
/// error, a malformed reply — returns `null` so the capture plan falls back to
/// its documented assumption. A capture is never blocked by calibration.
class CameraIntrinsicsReader {
  CameraIntrinsicsReader({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'adaptive360/camera_intrinsics';
  static const String method = 'rearCameraIntrinsics';

  final MethodChannel _channel;

  CameraIntrinsics? _cached;

  /// The last successful read, if any.
  CameraIntrinsics? get cached => _cached;

  Future<CameraIntrinsics?> read() async {
    final cached = _cached;
    if (cached != null && cached.available) return cached;
    if (!Platform.isAndroid) return null;
    try {
      final reply = await _channel.invokeMethod<Map<Object?, Object?>>(method);
      if (reply == null) return null;
      final parsed = CameraIntrinsics.fromMap(reply);
      _cached = parsed;
      if (!parsed.available) {
        debugPrint(
          'SPHERE_CAMERA: intrinsics unavailable from the platform; '
          'the plan uses its documented assumption.',
        );
        return null;
      }
      final raster = parsed.portraitRaster;
      final focal = raster == null ? null : parsed.focalPxForRaster(raster);
      debugPrint(
        'SPHERE_CAMERA: calibrated lens '
        '${parsed.focalLengthMm?.toStringAsFixed(2)} mm, '
        'sensor ${parsed.sensorWidthMm?.toStringAsFixed(2)}×'
        '${parsed.sensorHeightMm?.toStringAsFixed(2)} mm, '
        'raster ${raster?.width}×${raster?.height}, '
        'focal ${focal?.toStringAsFixed(1)} px, '
        'orientation ${parsed.sensorOrientation}°',
      );
      return parsed;
    } on PlatformException catch (error) {
      debugPrint(
        'SPHERE_CAMERA: intrinsics read failed (${error.code}: ${error.message}); '
        'the plan uses its documented assumption.',
      );
      return null;
    } on MissingPluginException {
      debugPrint(
        'SPHERE_CAMERA: no intrinsics channel on this platform; '
        'the plan uses its documented assumption.',
      );
      return null;
    }
  }

  /// The calibrated profile, or `null` when the platform could not supply one.
  Future<SphereCameraProfile?> readProfile() async {
    final intrinsics = await read();
    return intrinsics?.toSphereProfile();
  }
}
