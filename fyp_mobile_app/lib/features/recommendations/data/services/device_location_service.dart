import 'package:geolocator/geolocator.dart';

/// Reads one on-demand foreground position. Never starts a location stream.
class DeviceLocationService {
  const DeviceLocationService();

  Future<({double latitude, double longitude})> currentPosition() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw StateError('Enable device location in Settings to find nearby properties.');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      throw StateError('Location access is blocked. Enable it in app settings.');
    }
    if (permission == LocationPermission.denied) {
      throw StateError('Location permission was not granted.');
    }
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.low,
        timeLimit: Duration(seconds: 15),
      ),
    );
    if (!position.latitude.isFinite || !position.longitude.isFinite) {
      throw StateError('Device location is unavailable. Try again.');
    }
    return (latitude: position.latitude, longitude: position.longitude);
  }
}
