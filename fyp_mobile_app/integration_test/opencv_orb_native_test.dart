/// On-device verification that the bundled native OpenCV library actually
/// exports every symbol the 38-target panorama pipeline calls.
///
/// ## Why an integration test (and not a unit test)
///
/// `dartcv4` links its C++ symbols through Dart *native assets*: the APK is
/// built with `libdartcv.so` compiled from the
/// `hooks.user_defines.dartcv4.include_modules` list in `pubspec.yaml`. A
/// module that was compiled out still lets every Dart file compile and every
/// unit test pass — the symbol only goes missing when the binding is called
/// against the real library on a real runtime:
///
/// ```text
/// Couldn't resolve native function 'cv_ORB_create_1'
/// in 'package:dartcv4/dartcv.dart'
/// ```
///
/// This test therefore runs the SAME probe the stitcher runs
/// ([OpenCvNativeProbe]) against the actual library inside the app process on
/// a connected Android device, and asserts that the required modules resolve.
/// It is the regression guard for the pubspec `hooks.user_defines` nesting:
/// flattening that block (or dropping a module from it) fails here, on the
/// device, instead of failing a user's panorama with no explanation.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fyp/features/capture_360/data/sphere/opencv_native_probe.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  // Real plugin/asset initialisation: the probe resolves symbols from the
  // process' own loaded library, which only exists inside the built app.
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native OpenCV exports every panorama-pipeline module', (
    tester,
  ) async {
    final capabilities = OpenCvNativeProbe.run();
    OpenCvNativeProbe.log(capabilities, tag: 'ORB_NATIVE_TEST');

    // Every module the registration + projection pipeline needs must resolve.
    // A missing one means libdartcv.so was built without it — check
    // hooks.user_defines.dartcv4.include_modules in pubspec.yaml.
    for (final capability in capabilities) {
      expect(
        capability.ok,
        isTrue,
        reason:
            'Native OpenCV module "${capability.module}" (${capability.feature}) '
            'did not resolve in the shipped library: ${capability.detail}. '
            'The panorama pipeline cannot run without it.',
      );
    }

    // The decisive regression case for the reported failure: ORB itself.
    expect(
      capabilities
          .where((OpenCvCapability c) => c.module == 'features2d')
          .every((OpenCvCapability c) => c.ok),
      isTrue,
      reason:
          "cv_ORB_create_1 (features2d) must resolve on this device — "
          "'Couldn't resolve native function cv_ORB_create_1' is exactly the "
          'defect this test exists to catch.',
    );

    expect(OpenCvNativeProbe.missingModules(capabilities), isEmpty);
    expect(OpenCvNativeProbe.failureMessage(capabilities), isNull);
  });
}
