/// Non-browser half of [replaceStageInUrl]: there is no address bar to write.
library;

/// No-op where there is no document URL (tests, non-web targets).
void replaceStageInUrl(String stage) {}
