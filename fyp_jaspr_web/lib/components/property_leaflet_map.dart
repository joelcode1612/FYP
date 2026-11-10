import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

/// Interactive Leaflet map hosted in a first-party iframe. The iframe runs
/// regular JavaScript without introducing JS interop in the Dart model layer.
/// No third-party API key or client-side access to PostgreSQL is required.
class PropertyLeafletMap extends StatelessComponent {
  final CommercialProperty property;
  final int height;

  const PropertyLeafletMap({
    super.key,
    required this.property,
    this.height = 340,
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
    final path = Uri(
      path: '/property_leaflet_map.html',
      queryParameters: {
        'lat': lat.toString(),
        'lon': lon.toString(),
        'id': property.id,
      },
    ).toString();
    return Component.element(
      tag: 'iframe',
      classes: 'sw-pd__map-frame',
      attributes: {
        'src': path,
        'title':
            'Interactive map of ${property.title} with 500 metre and 1 kilometre catchments',
        'loading': 'lazy',
        'referrerpolicy': 'no-referrer',
        'style': 'width:100%;height:${height}px;border:0;display:block;',
      },
    );
  }
}
