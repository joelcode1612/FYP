/// Route-aware programmatic scrolling for the continuous landing page.
///
/// The public URLs are paths, not fragments, so the browser's native fragment
/// navigation cannot perform the scroll. The active route selects a section id
/// and this helper scrolls it into view after the component has rendered.
export 'landing_scroll_stub.dart'
    if (dart.library.js_interop) 'landing_scroll_browser.dart';
