/// VM stubs — the server compiles the page but never runs its button handlers.
void printPage() {}

/// VM stub: the in-page section navigation only exists in the browser.
void scrollToId(String id) {}

Future<bool> copyText(String text) async => false;
