import 'dart:convert';
import 'dart:js_interop';

import 'package:jaspr/jaspr.dart';
import 'package:universal_web/web.dart' as web;

/// Compact interactive Leaflet map for the Add Property address preview.
///
/// The map runs in a first-party iframe (`/address_preview_map.html`, the
/// same vendored Leaflet copy the other SiteWise maps use) and shows exactly
/// one marker: the matched property location. No business layers, no
/// analysis overlays, no API key in any client code.
///
/// Coordinates are pushed with `postMessage` so a fresh preview never has to
/// reload the frame; the initial URL values cover the first paint.
class AddressPreviewMap extends StatefulComponent {
  final double latitude;
  final double longitude;

  /// The matched address shown in the marker popup.
  final String label;

  final int height;

  final String title;

  const AddressPreviewMap({
    super.key,
    required this.latitude,
    required this.longitude,
    required this.label,
    required this.title,
    this.height = 300,
  });

  @override
  State<AddressPreviewMap> createState() => _AddressPreviewMapState();
}

class _AddressPreviewMapState extends State<AddressPreviewMap> {
  /// The loaded frame's window, captured from its `load` event so refreshed
  /// coordinates are pushed without re-navigating the iframe.
  web.Window? _frame;

  void _handleFrameLoad(web.Event event) {
    final frame = (event.target as web.HTMLIFrameElement).contentWindow;
    if (frame == null) return;
    _frame = frame;
    _pushLocation();
  }

  @override
  void didUpdateComponent(AddressPreviewMap oldComponent) {
    super.didUpdateComponent(oldComponent);
    if (oldComponent.latitude != component.latitude ||
        oldComponent.longitude != component.longitude ||
        oldComponent.label != component.label) {
      _pushLocation();
    }
  }

  void _pushLocation() {
    final frame = _frame;
    if (frame == null) return;
    frame.postMessage(
      'sitewiseAddressPreview:${jsonEncode({
        'lat': component.latitude,
        'lon': component.longitude,
        'label': component.label,
      })}'.toJS,
      web.window.location.origin.toJS,
    );
  }

  @override
  Component build(BuildContext context) {
    final path = Uri(
      path: '/address_preview_map.html',
      queryParameters: {
        'lat': component.latitude.toString(),
        'lon': component.longitude.toString(),
        'label': component.label,
      },
    ).toString();
    return Component.element(
      tag: 'iframe',
      classes: 'sw-addr-map-frame',
      attributes: {
        'src': path,
        'title': component.title,
        'loading': 'lazy',
        'referrerpolicy': 'strict-origin-when-cross-origin',
        // The frame's own fullscreen control needs this, or the browser
        // silently refuses the request.
        'allow': 'fullscreen',
        'allowfullscreen': 'true',
        'style': 'width:100%;height:${component.height}px;border:0;'
            'display:block;border-radius:10px;',
      },
      events: {'load': _handleFrameLoad},
    );
  }
}
