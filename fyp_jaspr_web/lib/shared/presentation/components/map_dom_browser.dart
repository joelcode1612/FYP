// Browser DOM helpers used by the explore map's pan and locate actions.
//
// Split stub/browser (see map_dom.dart) because `package:universal_web`
// compiles only for the web platform, while the explore page is also analyzed
// for the VM via the server options file.
import 'dart:js_interop';

import 'package:universal_web/web.dart' as web;

/// Horizontal pointer position in CSS pixels.
double pointerClientX(Object event) =>
    (event as web.MouseEvent).clientX.toDouble();

/// Vertical pointer position in CSS pixels.
double pointerClientY(Object event) =>
    (event as web.MouseEvent).clientY.toDouble();

double windowInnerWidth() => web.window.innerWidth.toDouble();

double windowInnerHeight() => web.window.innerHeight.toDouble();

/// Brings `#domId` into view; no-op when no such element exists.
void scrollDomIntoView(String domId) {
  final el = web.document.getElementById(domId);
  if (el == null) return;
  el.scrollIntoView(({'behavior': 'smooth', 'block': 'nearest'}).jsify()!);
}
