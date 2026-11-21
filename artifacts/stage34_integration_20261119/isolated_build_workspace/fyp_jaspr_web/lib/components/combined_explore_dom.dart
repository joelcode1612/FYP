/// Client-side bridge for selecting a Leaflet marker from the Jaspr Explore UI.
/// Conditional export preserves browser/VM build compatibility.
library;

export 'combined_explore_dom_stub.dart'
    if (dart.library.js_interop) 'combined_explore_dom_browser.dart';
