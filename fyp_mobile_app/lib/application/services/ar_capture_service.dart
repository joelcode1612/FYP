import 'package:shared_logic/shared_logic.dart';
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ar_flutter_plugin/datatypes/node_types.dart';
import 'package:ar_flutter_plugin/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin/models/ar_node.dart';
import 'package:flutter/painting.dart';
import 'package:vector_math/vector_math_64.dart' show Matrix4, Vector3;

import '../../core/utils/ar_math.dart';
import '../../core/utils/capture_log.dart';

/// AR plugin boundary for the panorama capture flow.
///
/// Owns session initialisation, reticle node placement, camera-pose
/// retrieval, real AR snapshot acquisition and session disposal, so that
/// `ar_flutter_plugin` types never leak into Domain or Presentation.

class ArCaptureService {
  ARSessionManager? _sessionManager;
  ARObjectManager? _objectManager;
  final List<ARNode> nodes = [];

  bool get isReady => _sessionManager != null && _objectManager != null;

  Future<void> attach(
    ARSessionManager sessionManager,
    ARObjectManager objectManager,
  ) async {
    _sessionManager = sessionManager;
    _objectManager = objectManager;
    await sessionManager.onInitialize(
      showFeaturePoints: false,
      showPlanes: true,
      showWorldOrigin: true,
      handleTaps: false,
    );
    objectManager.onInitialize();
    CaptureLog.log('AR initialized');
  }

  /// Places one `localGLTF2` reticle node per capture target using the
  /// spherical-to-vector conversion.
  Future<void> placeCaptureTargets(List<CapturePoint> targets) async {
    final manager = _objectManager;
    if (manager == null) return;
    for (final target in targets) {
      final node = ARNode(
        type: NodeType.localGLTF2,
        uri: ArCaptureConfig.targetReticleAsset,
        position: sphericalToVector(
          target.pitch,
          target.yaw,
          radius: ArCaptureConfig.nodeRadius,
        ),
        scale: Vector3.all(ArCaptureConfig.nodeScale),
      );
      final added = await manager.addNode(node);
      if (added == true) nodes.add(node);
    }
    CaptureLog.log('${nodes.length} target nodes placed');
  }

  Future<Matrix4?> getCameraPose() {
    final session = _sessionManager;
    if (session == null) return Future.value();
    return session.getCameraPose();
  }

  /// Acquires a real image of the current AR scene through the plugin's
  /// native snapshot and decodes it to PNG bytes. Returns null when the
  /// session is unavailable or the snapshot fails. Never throws.
  Future<Uint8List?> captureSnapshotPng() async {
    final session = _sessionManager;
    if (session == null) return null;
    try {
      final provider = await session.snapshot();
      final stream = provider.resolve(const ImageConfiguration());
      final completer = Completer<ui.Image>();
      late ImageStreamListener listener;
      listener = ImageStreamListener(
        (info, _) {
          completer.complete(info.image);
          stream.removeListener(listener);
        },
        onError: (Object e, StackTrace? st) {
          if (!completer.isCompleted) completer.completeError(e, st);
          stream.removeListener(listener);
        },
      );
      stream.addListener(listener);
      final image = await completer.future.timeout(const Duration(seconds: 10));
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        return data?.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    } catch (e) {
      CaptureLog.log('Snapshot failed: $e');
      return null;
    }
  }

  void dispose() {
    _sessionManager?.dispose();
    _sessionManager = null;
    _objectManager = null;
    nodes.clear();
  }
}
