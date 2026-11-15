/// Touch-only compatibility implementation for [panorama_viewer].
///
/// SiteWise never enables `SensorControl`, so the panorama viewer only needs
/// these declarations to compile. Sensor streams are deliberately empty rather
/// than registering a native Android or iOS plugin.
library;

import 'dart:async';

/// The process-wide sensor facade expected by `panorama_viewer`.
final MotionSensors motionSensors = MotionSensors();

/// A relative device-orientation reading, in radians.
class OrientationEvent {
  const OrientationEvent(this.yaw, this.pitch, this.roll);

  final double yaw;
  final double pitch;
  final double roll;
}

/// An absolute device-orientation reading, in radians.
class AbsoluteOrientationEvent {
  const AbsoluteOrientationEvent(this.yaw, this.pitch, this.roll);

  final double yaw;
  final double pitch;
  final double roll;
}

/// The physical screen-orientation angle, in degrees.
class ScreenOrientationEvent {
  const ScreenOrientationEvent(this.angle);

  final double? angle;
}

/// API-compatible facade for the viewer's optional device-motion support.
///
/// All availability checks return false and all streams are empty because the
/// SiteWise viewer intentionally supports touch interaction only.
class MotionSensors {
  static const int typeAccelerometer = 1;
  static const int typeMagneticField = 2;
  static const int typeGyroscope = 4;
  static const int typeUserAccelerometer = 10;
  static const int typeAbsoluteOrientation = 11;
  static const int typeOrientation = 15;

  int? _orientationUpdateInterval;
  int? _absoluteOrientationUpdateInterval;

  set orientationUpdateInterval(int interval) {
    _orientationUpdateInterval = interval;
  }

  set absoluteOrientationUpdateInterval(int interval) {
    _absoluteOrientationUpdateInterval = interval;
  }

  int? get orientationUpdateInterval => _orientationUpdateInterval;
  int? get absoluteOrientationUpdateInterval =>
      _absoluteOrientationUpdateInterval;

  Future<bool> isSensorAvailable(int sensorType) async => false;

  Future<bool> isOrientationAvailable() => isSensorAvailable(typeOrientation);

  Future<bool> isAbsoluteOrientationAvailable() =>
      isSensorAvailable(typeAbsoluteOrientation);

  Stream<OrientationEvent> get orientation => Stream<OrientationEvent>.empty();

  Stream<AbsoluteOrientationEvent> get absoluteOrientation =>
      Stream<AbsoluteOrientationEvent>.empty();

  Stream<ScreenOrientationEvent> get screenOrientation =>
      Stream<ScreenOrientationEvent>.empty();
}
