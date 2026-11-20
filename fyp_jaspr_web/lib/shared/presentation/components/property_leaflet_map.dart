import 'dart:convert';
import 'dart:js_interop';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:universal_web/web.dart' as web;

import 'package:sitewise_jaspr_web/features/listing/data/property_insights_api.dart';

/// Google Maps "Maps URLs" directions link for the point, or null when the
/// coordinates are not usable. Keyless by design: Maps URLs never carry the
/// Address Validation key, and the user leaves the app to Google's own
/// branded page instead of Google data being merged into the Leaflet view.
String? googleMapsDirectionsUrl(double lat, double lon) {
  final usable =
      lat.isFinite &&
      lon.isFinite &&
      lat >= -90 &&
      lat <= 90 &&
      lon >= -180 &&
      lon <= 180 &&
      !(lat == 0 && lon == 0);
  if (!usable) return null;
  return 'https://www.google.com/maps/dir/?api=1&destination=$lat,$lon';
}

/// Interactive Leaflet map hosted in a first-party iframe. The iframe runs
/// regular JavaScript without introducing JS interop in the Dart model layer.
/// No third-party API key or client-side access to PostgreSQL is required.
///
/// Layer data is passed in rather than fetched by the iframe, so the map and
/// the "Why this score?" panel are guaranteed to describe the same payload.
/// Only layers the backend marked `mapped` can be drawn as pins; the rest are
/// toggles that report their recorded count and say plainly that no locations
/// are stored for them.
///
/// Individual nearby locations ([nearby], fetched by the page through the
/// authenticated API) are delivered to the frame with `postMessage` rather
/// than the URL: the payload reaches thousands of places, and the frame is
/// same-origin so the message is origin-checked on both sides.
class PropertyLeafletMap extends StatefulComponent {
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

  /// The nearby-places payload from
  /// `GET /api/v1/catalog/properties/{id}/nearby-places`, passed through so
  /// the frame can draw the individual locations as markers. Null (fetch
  /// failed or not yet loaded) leaves the recorded-counts-only state; the
  /// frame never invents pins from absence.
  final Map<String, dynamic>? nearby;

  const PropertyLeafletMap({
    super.key,
    required this.property,
    this.height = 340,
    this.radius,
    this.layers = const [],
    this.origin,
    this.nearby,
  });

  @override
  State<PropertyLeafletMap> createState() => _MapFrameState();
}

class _MapFrameState extends State<PropertyLeafletMap> {
  /// The loaded frame's window, captured from its `load` event so new data
  /// can be pushed without re-navigating the iframe.
  web.Window? _frame;

  void _handleFrameLoad(web.Event event) {
    final frame = (event.target as web.HTMLIFrameElement).contentWindow;
    if (frame == null) return;
    _frame = frame;
    _pushPlaces();
  }

  @override
  void didUpdateComponent(PropertyLeafletMap oldComponent) {
    super.didUpdateComponent(oldComponent);
    if (!identical(component.nearby, oldComponent.nearby)) _pushPlaces();
  }

  void _pushPlaces() {
    final frame = _frame;
    final payload = component.nearby;
    if (frame == null || payload == null) return;
    frame.postMessage(
      'sitewiseNearbyPlaces:${jsonEncode(payload)}'.toJS,
      web.window.location.origin.toJS,
    );
  }

  @override
  Component build(BuildContext context) {
    final lat = component.origin?.lat ?? component.property.latitude;
    final lon = component.origin?.lon ?? component.property.longitude;
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
    final radiusMeters = component.radius;
    final query = {
      'lat': lat.toString(),
      'lon': lon.toString(),
      'id': component.property.id,
      if (radiusMeters != null) 'radius': '$radiusMeters',
      if (component.layers.isNotEmpty) 'layers': _encodeLayers(component.layers),
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
            ? 'Interactive map of ${component.property.title} with 500 metre and 1 kilometre catchments'
            : 'Interactive map of ${component.property.title} with a selectable '
                  '${_radiusLabel(radiusMeters)} straight-line radius',
        'loading': 'lazy',
        'referrerpolicy': 'strict-origin-when-cross-origin',
        // The map's own fullscreen control needs this, or the browser refuses
        // the request and the button silently does nothing.
        'allow': 'fullscreen',
        'allowfullscreen': 'true',
        'style': 'width:100%;height:${component.height}px;border:0;display:block;',
      },
      events: {'load': _handleFrameLoad},
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
