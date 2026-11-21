// Browser implementations of the Full Analysis page's Copy and Print actions.
// Split stub/browser (see full_analysis_actions.dart) because the page is also
// analyzed for the VM, where these handlers never execute.
import 'dart:js_interop';

@JS('window')
external _Window get _window;

extension type _Window(JSObject _) implements JSObject {
  external void print();
  external _Navigator get navigator;
}

extension type _Navigator(JSObject _) implements JSObject {
  external _Clipboard? get clipboard;
}

extension type _Clipboard(JSObject _) implements JSObject {
  external JSPromise<JSAny?> writeText(JSString text);
}

/// Opens the browser print dialog for the current document.
void printPage() => _window.print();

/// Scrolls the element with [id] into view, for in-page section navigation.
/// A missing element is a no-op: the nav is a convenience, never a route.
void scrollToId(String id) {
  final element = _document.getElementById(id.toJS);
  element?.scrollIntoView(_scrollOptions);
}

@JS('document')
external _Document get _document;

extension type _Document(JSObject _) implements JSObject {
  external _Element? getElementById(JSString id);
}

extension type _Element(JSObject _) implements JSObject {
  external void scrollIntoView(JSAny? options);
}

final _scrollOptions = {'behavior': 'smooth', 'block': 'start'}.jsify();

/// Writes [text] to the clipboard. Returns false when the Clipboard API is
/// unavailable or the write is refused, so the button can show an honest
/// "Copy unavailable" state instead of a false success.
Future<bool> copyText(String text) async {
  final clipboard = _window.navigator.clipboard;
  if (clipboard == null) return false;
  try {
    await clipboard.writeText(text.toJS).toDart;
    return true;
  } catch (_) {
    return false;
  }
}
