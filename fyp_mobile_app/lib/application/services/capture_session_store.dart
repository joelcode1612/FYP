import 'panorama_capture_service.dart';

/// Holds the live capture session per property so retake flows can resume
/// the exact session (frames, origin, progress) instead of restarting.

class ActiveCaptureSession {
  final String propertyId;
  final String tourId;
  final PanoramaCaptureService service;

  const ActiveCaptureSession({
    required this.propertyId,
    required this.tourId,
    required this.service,
  });
}

class CaptureSessionStore {
  final Map<String, ActiveCaptureSession> _sessions = {};

  ActiveCaptureSession? forProperty(String propertyId) => _sessions[propertyId];

  ActiveCaptureSession startNew({
    required String propertyId,
    required String tourId,
    required PanoramaCaptureService service,
  }) {
    final session = ActiveCaptureSession(
      propertyId: propertyId,
      tourId: tourId,
      service: service,
    );
    _sessions[propertyId] = session;
    return session;
  }

  void clear(String propertyId) => _sessions.remove(propertyId);
}
