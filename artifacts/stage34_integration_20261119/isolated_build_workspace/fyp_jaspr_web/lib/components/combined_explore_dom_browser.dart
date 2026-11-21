import 'package:universal_web/web.dart' as web;

/// JS writes a property ID to data-choice and clicks a Jaspr-owned button.
String? selectedCombinedExplorePropertyId() {
  final root = web.document.getElementById('swcx-leaflet');
  final value = root?.getAttribute('data-choice');
  return value == null || value.isEmpty ? null : value;
}
