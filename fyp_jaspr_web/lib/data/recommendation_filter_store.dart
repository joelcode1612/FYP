/// Platform-independent export of the account-scoped recommendation filters.
/// Browser uses localStorage; server / VM builds never access browser APIs.
library;

export 'recommendation_filter_store_stub.dart'
    if (dart.library.js_interop) 'recommendation_filter_store_browser.dart';
