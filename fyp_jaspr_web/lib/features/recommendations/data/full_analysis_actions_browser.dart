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
