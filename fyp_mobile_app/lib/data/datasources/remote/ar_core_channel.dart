import 'dart:async';

import 'package:flutter/services.dart';

/// Dart seam for the in-app ARCore host.
///
/// The host ships inside the Android app (`com.example.fyp.ar.ArCoreCapturePlugin`)
/// and speaks two channels, exactly as the reference implementation does:
/// `adaptive360/arcore` for commands and `adaptive360/arcore/events` for the
/// per-frame pose/tracking/anchor stream.
///
/// This class is deliberately a thin transport: it owns no capture state, no
/// target order and no stitching. `PanoramaCaptureService` remains the single
/// state machine, and the tour service remains the single persistence path.
/// Nothing here fabricates a pose: when the host reports tracking as paused or
/// unavailable, the event payload says so.
class ArCoreChannel {
  ArCoreChannel({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _method = methodChannel ?? const MethodChannel(_methodName),
        _events = eventChannel ?? const EventChannel(_eventName);

  static const String _methodName = 'adaptive360/arcore';
  static const String _eventName = 'adaptive360/arcore/events';

  final MethodChannel _method;
  final EventChannel _events;

  Stream<Map<String, dynamic>>? _eventStream;

  /// ARCore availability on this device: installed, supported, and whether an
  /// install/update request is required.
  Future<Map<String, dynamic>> checkAvailability() async {
    final result = await _method.invokeMethod<Map<Object?, Object?>>('checkAvailability');
    return _stringKeyed(result);
  }

  /// Launches ARCore's own install/update flow when [checkAvailability]
  /// reports it is needed. Returns the host's outcome map.
  Future<Map<String, dynamic>> requestInstall() async {
    final result = await _method.invokeMethod<Map<Object?, Object?>>('requestInstall');
    return _stringKeyed(result);
  }

  /// Starts the ARCore session and the GL texture that renders the world-anchored
  /// GLB target. [rotation] is the display rotation in degrees (0/90/180/270).
  Future<Map<String, dynamic>> start({
    bool planes = true,
    required int width,
    required int height,
    int rotation = 0,
  }) async {
    final result = await _method.invokeMethod<Map<Object?, Object?>>('start', {
      'planes': planes,
      'width': width,
      'height': height,
      'rotation': rotation,
    });
    return _stringKeyed(result);
  }

  Future<void> pause() => _method.invokeMethod<void>('pause');

  Future<void> resume() => _method.invokeMethod<void>('resume');

  Future<void> resize({required int width, required int height}) =>
      _method.invokeMethod<void>('resize', {'width': width, 'height': height});

  Future<void> setDisplayRotation(int rotation) =>
      _method.invokeMethod<void>('setDisplayRotation', {'rotation': rotation});

  /// Stops the session and releases the GL/camera resources. Safe to call when
  /// no session is running (the host returns success in that case).
  Future<void> stop() => _method.invokeMethod<void>('stop');

  /// Pose/tracking/anchor events emitted by the host. Broadcast so a rebuild
  /// cannot consume the stream twice; cancelling the subscription does not stop
  /// the native session — call [stop] for that.
  Stream<Map<String, dynamic>> get events {
    return _eventStream ??= _events
        .receiveBroadcastStream()
        .map((event) => _stringKeyed(event is Map ? event : const {}))
        .asBroadcastStream();
  }

  static Map<String, dynamic> _stringKeyed(Object? raw) {
    if (raw is! Map) return const {};
    return {
      for (final entry in raw.entries)
        '${entry.key}': entry.value,
    };
  }
}
