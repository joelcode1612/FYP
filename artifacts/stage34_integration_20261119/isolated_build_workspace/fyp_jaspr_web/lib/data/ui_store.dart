/// Cookie-backed store for the entrepreneur's saved / compare selections.
///
/// Server-rendered pages are separate documents, so the in-memory app-state
/// notifier no longer survives a navigation on its own. Keeping the two id
/// sets in a small cookie restores the old behaviour — and because the cookie
/// is readable by the SSR pass as well, a server-rendered page and the
/// hydrated one agree on which cards are marked.
library;

export 'ui_store_stub.dart'
    if (dart.library.js_interop) 'ui_store_browser.dart';
