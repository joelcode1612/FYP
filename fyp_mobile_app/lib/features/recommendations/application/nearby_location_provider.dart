import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fyp/features/recommendations/data/services/device_location_service.dart';

/// Application boundary for the one-time, opt-in nearby discovery use case.
final nearbyLocationProvider = Provider<DeviceLocationService>(
  (ref) => const DeviceLocationService(),
);
