import 'package:flutter/foundation.dart';

import 'mobile_config.dart';

/// Single authority for whether synthetic demo questionnaire content may be
/// resolved at all.
///
/// Demo content is allowed ONLY in a debug build that is not pointed at the
/// live backend. A release/profile build therefore resolves NO fixture
/// questions even when no API defines were supplied, and a live build never
/// silently falls back to demo data. The customer questionnaire backend is not
/// authorized, so every other configuration is in the compliance hold.
///
/// Both the UI hold (`AssessmentLiveHold`) and the composition-root routing
/// provider (`questionnaireRoutingServiceProvider`) use this getter. Keeping
/// the rule in core/config avoids an application-layer dependency on a view
/// widget, and means a future screen cannot accidentally bypass the UI hold
/// and still receive demo questions.
bool get assessmentDemoAllowed => kDebugMode && !MobileConfig.usesLiveApi;

bool get assessmentHoldActive => !assessmentDemoAllowed;
