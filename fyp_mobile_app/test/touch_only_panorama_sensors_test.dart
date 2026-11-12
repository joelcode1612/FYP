import 'package:dchs_motion_sensors/dchs_motion_sensors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'the panorama sensor bridge stays inactive in the touch-only build',
    () async {
      motionSensors.orientationUpdateInterval = 16666;
      motionSensors.absoluteOrientationUpdateInterval = 16666;

      expect(motionSensors.orientationUpdateInterval, 16666);
      expect(motionSensors.absoluteOrientationUpdateInterval, 16666);
      expect(await motionSensors.isOrientationAvailable(), isFalse);
      expect(await motionSensors.isAbsoluteOrientationAvailable(), isFalse);
      expect(await motionSensors.orientation.isEmpty, isTrue);
      expect(await motionSensors.absoluteOrientation.isEmpty, isTrue);
      expect(await motionSensors.screenOrientation.isEmpty, isTrue);
    },
  );
}
