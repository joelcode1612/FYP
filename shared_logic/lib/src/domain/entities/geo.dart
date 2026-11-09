import 'dart:math' as math;

import 'commercial_property.dart';

/// Pure-Dart geographic helpers shared by both apps.
///
/// The backend's PostGIS queries (ST_DWithin / ST_DistanceSphere) are the
/// authoritative source for server-side radius lookups. These helpers exist
/// for the case the backend does not cover: ranking an ALREADY LOADED set of
/// properties around a selection, where a round trip per pan/zoom frame would
/// be wasteful.
///
/// Every distance produced here is a great-circle (Haversine) straight line.
/// It is NOT walking or driving distance and must be labelled as an estimate
/// wherever it is displayed.
abstract final class GeoUtils {
  /// Mean Earth radius in metres (IUGG recommended value).
  static const double earthRadiusM = 6371008.8;

  /// Great-circle distance between two WGS84 points, in metres.
  ///
  /// Returns null when either coordinate is null, or when either coordinate
  /// is exactly (0, 0) — the sentinel this codebase uses for "no coordinates
  /// recorded". A property genuinely at 0°N 0°E (the Gulf of Guinea) is not a
  /// Malaysian commercial listing, so treating it as missing is safe here.
  static double? haversineMeters(
    double? lat1,
    double? lon1,
    double? lat2,
    double? lon2,
  ) {
    if (lat1 == null || lon1 == null || lat2 == null || lon2 == null) {
      return null;
    }
    if (_isMissing(lat1, lon1) || _isMissing(lat2, lon2)) return null;
    final phi1 = _rad(lat1);
    final phi2 = _rad(lat2);
    final dPhi = _rad(lat2 - lat1);
    final dLambda = _rad(lon2 - lon1);
    final a =
        math.pow(math.sin(dPhi / 2), 2) +
        math.cos(phi1) * math.cos(phi2) * math.pow(math.sin(dLambda / 2), 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadiusM * c;
  }

  static bool _isMissing(double lat, double lon) => lat == 0 && lon == 0;

  static double _rad(double degrees) => degrees * math.pi / 180.0;
}

/// One property with its straight-line distance from a selection point.
class NearbyProperty {
  final CommercialProperty property;
  final double distanceM;

  const NearbyProperty({required this.property, required this.distanceM});

  /// Distances are estimates; the label states the method so no UI can
  /// accidentally present them as measured or walkable routes.
  String get distanceLabel =>
      distanceM >= 1000
      ? '${(distanceM / 1000).toStringAsFixed(distanceM >= 10000 ? 0 : 1)} km'
      : '${distanceM.round()} m';
}

/// The result of a radius selection over a loaded property set: the sorted
/// nearby list (selection itself excluded) plus the counts at each of the two
/// documented research radii.
class NearbyProperties {
  /// The 500 m ring: the documented fine-grained research radius.
  final List<NearbyProperty> within500m;

  /// The 1 km ring: the documented coarse research radius.
  final List<NearbyProperty> within1km;

  /// The radius actually applied to [selected] list. Kept so a UI can echo
  /// the selection rather than infer it.
  final int radiusM;
  final List<NearbyProperty> selected;

  const NearbyProperties({
    required this.within500m,
    required this.within1km,
    required this.radiusM,
    required this.selected,
  });

  /// Ranks [candidates] around [center] within [radiusM].
  ///
  /// * [center] itself is excluded from the result (a property is never its
  ///   own neighbour), matched by id.
  /// * Properties without usable coordinates are skipped, not placed at an
  ///   invented distance.
  /// * Ties break on distance, then id, so the order is deterministic for the
  ///   grid and any list view.
  static NearbyProperties of({
    required CommercialProperty center,
    required List<CommercialProperty> candidates,
    int radiusM = 1000,
  }) {
    final nearby = <NearbyProperty>[];
    for (final p in candidates) {
      if (p.id == center.id) continue;
      final d = GeoUtils.haversineMeters(
        center.latitude,
        center.longitude,
        p.latitude,
        p.longitude,
      );
      if (d == null || d > radiusM) continue;
      nearby.add(NearbyProperty(property: p, distanceM: d));
    }
    nearby.sort((a, b) {
      final byDistance = a.distanceM.compareTo(b.distanceM);
      return byDistance != 0 ? byDistance : a.property.id.compareTo(b.property.id);
    });
    return NearbyProperties(
      within500m: [
        for (final n in nearby)
          if (n.distanceM <= 500) n,
      ],
      within1km: [
        for (final n in nearby)
          if (n.distanceM <= 1000) n,
      ],
      radiusM: radiusM,
      selected: nearby,
    );
  }
}
