/// Host-unit tests for the capability classification logic of
/// [OpenCvNativeProbe].
///
/// These never call a native binding: the probe's real `run()` is exercised
/// on the DEVICE by `integration_test/opencv_orb_native_test.dart`, because a
/// missing native symbol is only observable against the shipped
/// `libdartcv.so` inside the app process. What a host test CAN prove is that
/// the probe classifies capabilities correctly and produces actionable
/// user-facing messages — the contract the stitcher and the UI rely on.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fyp/features/capture_360/data/sphere/opencv_native_probe.dart';

OpenCvCapability _ok(String module) =>
    OpenCvCapability(module: module, feature: 'stub', ok: true);

OpenCvCapability _missing(String module, String detail) => OpenCvCapability(
  module: module,
  feature: 'stub',
  ok: false,
  detail: detail,
);

void main() {
  group('missingModules', () {
    test('reports nothing when every capability resolved', () {
      final capabilities = <OpenCvCapability>[
        for (final module in OpenCvNativeProbe.requiredModules) _ok(module),
      ];
      expect(OpenCvNativeProbe.missingModules(capabilities), isEmpty);
    });

    test('names each missing module in required-module order', () {
      final capabilities = <OpenCvCapability>[
        for (final module in OpenCvNativeProbe.requiredModules)
          module == 'features2d' || module == 'stitching'
              ? _missing(module, "couldn't resolve native function")
              : _ok(module),
      ];
      expect(OpenCvNativeProbe.missingModules(capabilities), <String>[
        'features2d',
        'stitching',
      ]);
    });

    test('ignores modules outside the required set', () {
      final capabilities = <OpenCvCapability>[
        _ok('imgproc'),
        _ok('imgcodecs'),
        _ok('features2d'),
        _ok('calib3d'),
        _ok('stitching'),
        _missing('dnn', 'not required by the pipeline'),
      ];
      expect(OpenCvNativeProbe.missingModules(capabilities), isEmpty);
    });
  });

  group('failureMessage', () {
    test('is null when the library is complete', () {
      final capabilities = <OpenCvCapability>[
        for (final module in OpenCvNativeProbe.requiredModules) _ok(module),
      ];
      expect(OpenCvNativeProbe.failureMessage(capabilities), isNull);
    });

    test(
      'names the missing modules and the build setting, never the trace',
      () {
        final capabilities = <OpenCvCapability>[
          ...OpenCvNativeProbe.requiredModules.map(_ok),
          _missing(
            'features2d',
            "Couldn't resolve native function 'cv_ORB_create_1' in "
                "'package:dartcv4/dartcv.dart'",
          ),
        ];
        final message = OpenCvNativeProbe.failureMessage(capabilities)!;
        expect(message, contains('features2d'));
        expect(message, contains('hooks.user_defines.dartcv4.include_modules'));
        expect(
          message,
          contains('The 38 photographs are safe'),
          reason: 'the user must be told their captured frames are kept',
        );
      },
    );
  });
}
