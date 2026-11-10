import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

/// Interactive Leaflet map hosted in a first-party iframe. The iframe runs
/// regular JavaScript without introducing JS interop in the Dart model layer.
/// No third-party API key or client-side access to PostgreSQL is required.
class PropertyLeafletMap extends StatelessComponent {
  final CommercialProperty property;
  final int height;

  /// When set, the map opens in single-radius mode on this metres value and
  /// offers 500 m / 1 km / 2 km / 3 km circles (the Full Analysis page). Left
  /// null, the adapter keeps its legacy 500 m + 1 km "Both" view (property
  /// detail). The adapter ignores a value it does not recognise.
  final int? radius;

  const PropertyLeafletMap({
    super.key,
    required this.property,
    this.height = 340,
    this.radius,
  });

  @override
  Component build(BuildContext context) {
    final lat = property.latitude;
    final lon = property.longitude;
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
        'style': 'width:100%;height:${height}px;border:0;display:block;',
      },
    );
  }

  static String _radiusLabel(int meters) =>
      meters >= 1000 ? '${meters ~/ 1000} kilometre' : '$meters metre';
}
