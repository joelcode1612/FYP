// Browser implementation of landing-page section scrolling.
// Split stub/browser (see landing_scroll.dart) so the page also analyzes for
// the VM, where the DOM APIs do not exist.
import 'dart:js_interop';

@JS('document')
external _Document get _document;

extension type _Document(JSObject _) implements JSObject {
  external _Element? getElementById(JSString id);
}

extension type _Element(JSObject _) implements JSObject {
  external void scrollIntoView(JSAny? options);
}

final _smoothStart = {'behavior': 'smooth', 'block': 'start'}.jsify();

/// Scrolls the section for the active landing route into view.
/// A missing element is a no-op: navigation must still work if the section
/// has not hydrated yet or the route is rendered outside the landing tree.
void scrollToLandingSection(String sectionId) {
  _document.getElementById(sectionId.toJS)?.scrollIntoView(_smoothStart);
}
