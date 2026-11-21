/// Application-owned ports for the sphere-capture platform adapters.
///
/// The concrete implementations (method channels, the `camera` plugin) stay in
/// Data; the capture controller only ever sees these contracts. Signatures are
/// copied verbatim from the adapter files — behaviour is unchanged.
library;

import 'dart:async';
import 'dart:typed_data' show Uint8List;

import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/widgets.dart' show Widget;

import 'package:fyp/features/capture_360/domain/virtual_tour/math/quaternions.dart';
import 'package:fyp/features/capture_360/domain/virtual_tour/math/vectors.dart';

abstract class RotationSource {
  /// Device → world quaternions, in the Android sensor frame.
  Stream<Quat> get rotations;

  /// The world-up axis of the frame [rotations] are reported in.
  ///
  /// Defaults to `+Y`, which is what this project's own `Quat.fromYawPitch`
  /// helpers assume, so a synthetic source in a test behaves like the rest of
  /// the maths. [NativeRotationSource] overrides it with
  /// [kAndroidSensorWorldUp] because the hardware reports ENU.
  Vec3 get worldUp => Vec3.unitY;

  /// Starts the platform sensor. Idempotent.
  Future<void> start();

  /// Stops it and releases the sensor. Idempotent.
  Future<void> stop();
}

abstract class SphereCamera {
  /// Opens the rear camera at its highest still resolution.
  Future<void> open();

  bool get isOpen;

  /// Preview width ÷ height in portrait, or `null` before [open].
  double? get previewAspectRatio;

  /// The live preview, sized to cover its parent.
  Widget preview();

  /// One full-resolution JPEG.
  Future<Uint8List> takePicture();

  /// Locks exposure and focus so the whole sweep shares one tone and one focal
  /// plane.
  ///
  /// Called once the first photograph is in: by then the auto-exposure loop has
  /// converged on real content, so the locked values describe the room rather
  /// than whatever the camera happened to be pointing at while the preview
  /// started. Locking earlier would freeze a mid-convergence exposure and make
  /// every one of the 38 frames wrong together, which is worse than varying.
  ///
  /// Default body does nothing, so a fake camera needs no implementation.
  Future<void> lockCaptureSettings() async {}

  /// Releases the locks, returning the camera to auto. Called when the session
  /// ends, so a later capture is not stuck with this room's exposure.
  Future<void> unlockCaptureSettings() async {}

  Future<void> close();

  /// Completes once the camera is open **and its preview has had a chance to
  /// render its first frame**.
  ///
  /// The capture controller takes its reference heading only after this
  /// completes. Taking it earlier described a phone pose from before the user
  /// could see anything, so target 1 was anchored to wherever the phone was
  /// mid-lift and then sat 20–40° outside the viewfinder once the preview
  /// appeared.
  ///
  /// The default body covers fakes that have no texture: wait for [isOpen],
  /// then one compositor frame. [PluginSphereCamera] overrides it with a
  /// stricter wait on the real controller.
  Future<void> ensurePreviewReady({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!isOpen && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (DateTime.now().isBefore(deadline)) {
      await SchedulerBinding.instance.endOfFrame;
    }
  }
}
