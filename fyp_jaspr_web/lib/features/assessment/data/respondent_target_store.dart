/// Platform-independent export of the account-scoped respondent target.
///
/// The target is the entrepreneur's own decision about how many respondents an
/// assessment is for. It is a *planning* figure, never a count of responses the
/// server has collected, and it is what gates the report.
///
/// Browser builds persist it in localStorage; server / VM builds never touch
/// browser APIs and simply report "not set".
library;

export 'package:sitewise_jaspr_web/features/assessment/data/respondent_target_store_stub.dart'
    if (dart.library.js_interop) 'respondent_target_store_browser.dart';
