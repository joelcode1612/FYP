import 'dart:convert';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../data/property_insights_api.dart';

/// Interactive Leaflet map hosted in a first-party iframe. The iframe runs
/// regular JavaScript without introducing JS interop in the Dart model layer.
/// No third-party API key or client-side access to PostgreSQL is required.
///
/// Layer data is passed in rather than fetched by the iframe, so the map and
/// the "Why this score?" panel are guaranteed to describe the same payload.
/// Only layers the backend marked `mapped` can be drawn as pins; the rest are
/// toggles that report their recorded count and say plainly that no locations
/// are stored for them.
class PropertyLeafletMap extends StatelessComponent {
  final CommercialProperty property;
  final int height;

  /// When set, the map opens in single-radius mode on this metres value and
  /// offers 500 m / 1 km / 2 km / 3 km circles (the Full Analysis page). Left
  /// null, the adapter keeps its legacy 500 m + 1 km "Both" view (property
  /// detail). The adapter ignores a value it does not recognise.
  final int? radius;

  /// The five map layers from the insights payload. Empty means the backend
  /// supplied none, and the adapter falls back to the reference-property view.
  final List<MapLayer> layers;

  /// The coordinate the backend scored. Preferred over the listing's own
  /// fields so the map centres on exactly the point the analysis describes.
  final MapOrigin? origin;

  const PropertyLeafletMap({
    super.key,
    required this.property,
    this.height = 340,
    this.radius,
    this.layers = const [],
    this.origin,
  });

  @override
  Component build(BuildContext context) {
    final lat = origin?.lat ?? property.latitude;
    final lon = origin?.lon ?? property.longitude;
    final valid =
        lat.isFinite &&
        lon.isFinite &&
        lat >= -90 &&
        lat <= 90 &&
        lon >= -180 &&
        lon <= 180 &&
        !(lat == 0 && lon == 0);
    if (!valid) {
      return div(classes: 'sw-pd__map-empty', [
        Component.text(
          'Map unavailable: this listing has no usable coordinates.',
        ),
      ]);
    }
    final radiusMeters = radius;
    final query = {
      'lat': lat.toString(),
      'lon': lon.toString(),
      'id': property.id,
      if (radiusMeters != null) 'radius': '$radiusMeters',
      if (layers.isNotEmpty) 'layers': _encodeLayers(layers),
    };
    final path = Uri(
      path: '/property_leaflet_map.html',
      queryParameters: query,
    ).toString();
    return Component.element(
      tag: 'iframe',
      classes: 'sw-pd__map-frame',
      attributes: {
        'src': path,
        'title': radiusMeters == null
            ? 'Interactive map of ${property.title} with 500 metre and 1 kilometre catchments'
            : 'Interactive map of ${property.title} with a selectable '
                  '${_radiusLabel(radiusMeters)} straight-line radius',
        'loading': 'lazy',
        'referrerpolicy': 'strict-origin-when-cross-origin',
        // The map's own fullscreen control needs this, or the browser refuses
        // the request and the button silently does nothing.
        'allow': 'fullscreen',
        'allowfullscreen': 'true',
        'style': 'width:100%;height:${height}px;border:0;display:block;',
      },
    );
  }

  /// Short keys keep the iframe URL well inside browser limits; the adapter
  /// documents the same abbreviations.
  static String _encodeLayers(List<MapLayer> layers) => jsonEncode([
    for (final layer in layers)
      {
        'k': layer.key,
        'l': layer.label,
        'c': layer.color,
        'm': layer.mapped,
        'a': layer.count500m,
        'b': layer.count1000m,
        'n': layer.nearestM,
      },
  ]);

  static String _radiusLabel(int meters) =>
      meters >= 1000 ? '${meters ~/ 1000} kilometre' : '$meters metre';
}
