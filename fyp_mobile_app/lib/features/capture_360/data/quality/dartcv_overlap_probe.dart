import 'dart:math' as math;
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'package:fyp/features/capture_360/domain/quality/frame_quality_analyzer.dart';

/// ORB-based neighbor-overlap confidence for the capture-time advisory check.
///
/// Pipeline mirrors the capture flow's own registration primitives (ORB
/// detect → BFMatcher knn with a ratio test → RANSAC homography) and returns
/// the inlier ratio as the overlap confidence: the fraction of matched
/// features that a single rigid image-to-image motion explains. Two frames
/// that genuinely share ~44% of content score comfortably above the 0.35
/// floor; a frame shot in the wrong direction collapses towards zero.
///
/// Every OpenCV object is released in a finally block — the capture session
/// runs 38 of these, and leaking a `Mat` per frame would exhaust a phone.
class DartCvOverlapProbe implements NeighborOverlapProbe {
  const DartCvOverlapProbe();

  @override
  Future<double?> overlapConfidence({
    required Uint8List frame,
    required Uint8List neighbor,
    required double separationDeg,
  }) async {
    cv.Mat? first;
    cv.Mat? second;
    cv.Mat? firstGray;
    cv.Mat? secondGray;
    cv.VecPoint2f? sourcePoints;
    cv.VecPoint2f? destinationPoints;
    cv.Mat? sourceMat;
    cv.Mat? destinationMat;
    cv.Mat? mask;
    cv.ORB? orb;
    cv.BFMatcher? matcher;
    try {
      first = cv.imdecode(frame, cv.IMREAD_COLOR);
      second = cv.imdecode(neighbor, cv.IMREAD_COLOR);
      if (first.isEmpty || second.isEmpty) return null;
      firstGray = cv.cvtColor(first, cv.COLOR_BGR2GRAY);
      secondGray = cv.cvtColor(second, cv.COLOR_BGR2GRAY);
      orb = cv.ORB.create(nFeatures: 1500);
      final (firstKeypoints, firstDescriptors) = orb.detectAndCompute(
        firstGray,
        cv.Mat.empty(),
      );
      final (secondKeypoints, secondDescriptors) = orb.detectAndCompute(
        secondGray,
        cv.Mat.empty(),
      );
      if (firstDescriptors.isEmpty || secondDescriptors.isEmpty) return null;
      matcher = cv.BFMatcher.create(type: cv.NORM_HAMMING);
      final knn = matcher.knnMatch(firstDescriptors, secondDescriptors, 2);
      final kept = <(int, int)>[];
      for (final row in knn) {
        if (row.length < 2) continue;
        final best = row[0];
        final runnerUp = row[1];
        // Lowe ratio test; 0.75 is the canonical value the registration
        // engine itself uses.
        if (best.distance < 0.75 * runnerUp.distance) {
          kept.add((best.queryIdx, best.trainIdx));
        }
      }
      if (kept.length < 12) return 0.0;
      final sourceList = <cv.Point2f>[];
      final destinationList = <cv.Point2f>[];
      for (final (queryIndex, trainIndex) in kept) {
        sourceList.add(
          cv.Point2f(
            firstKeypoints[queryIndex].x,
            firstKeypoints[queryIndex].y,
          ),
        );
        destinationList.add(
          cv.Point2f(
            secondKeypoints[trainIndex].x,
            secondKeypoints[trainIndex].y,
          ),
        );
      }
      sourcePoints = cv.VecPoint2f.fromList(sourceList);
      destinationPoints = cv.VecPoint2f.fromList(destinationList);
      sourceMat = cv.Mat.fromVec(sourcePoints);
      destinationMat = cv.Mat.fromVec(destinationPoints);
      mask = cv.Mat.empty();
      final homography = cv.findHomography(
        sourceMat,
        destinationMat,
        method: cv.RANSAC,
        ransacReprojThreshold: 6.0,
        mask: mask,
      );
      final homographyUsable = !homography.isEmpty;
      homography.dispose();
      if (!homographyUsable) return 0.0;
      var inliers = 0;
      for (var i = 0; i < kept.length; i++) {
        if (mask.atU8(i) != 0) inliers++;
      }
      // Confidence = inlier share of the raw matches, the same definition the
      // backend's registration audit reports.
      return math.min(1.0, inliers / math.max(kept.length, 1));
    } on Object {
      // Native unavailable or a decode failure: "not measured", never a
      // thrown error into the capture path.
      return null;
    } finally {
      mask?.dispose();
      destinationMat?.dispose();
      sourceMat?.dispose();
      destinationPoints?.dispose();
      sourcePoints?.dispose();
      matcher?.dispose();
      orb?.dispose();
      secondGray?.dispose();
      firstGray?.dispose();
      second?.dispose();
      first?.dispose();
    }
  }
}
