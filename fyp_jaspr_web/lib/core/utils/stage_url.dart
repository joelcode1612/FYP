/// Keeps the checkpoint in the address bar so a refresh lands on the same stage.
///
/// Why this exists
/// ---------------
/// The workspace renders one checkpoint at a time from `?stage=`, but switching
/// checkpoints only changed widget state. A refresh — or a copied link — fell
/// back to the record's own current stage, so a reader who had navigated to
/// Stage 4 was returned to Stage 3 and had to navigate again (DD-043).
///
/// The write is `replaceState`, not `pushState`: a checkpoint switch is not a
/// document navigation, and pushing an entry per click would make the browser's
/// Back button walk backwards through checkpoints the user did not consider
/// pages. Only the `stage` parameter is touched; every other query parameter is
/// preserved, so `?id=` deep links keep working.
library;

export 'package:sitewise_jaspr_web/core/utils/stage_url_stub.dart'
    if (dart.library.js_interop) 'stage_url_browser.dart';
