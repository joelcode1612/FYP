/// No-op implementation when Jaspr builds/runs on the Dart VM.
///
/// There is no browser storage to read, so the target is always unset. That is
/// the honest answer rather than a fabricated default: a server-rendered page
/// has no entrepreneur sitting in front of it to have made the decision.
library;

abstract final class RespondentTargetStore {
  /// Smallest and largest accepted target. The upper bound is a ceiling on the
  /// input, not a claim that a study this size has been run.
  static const int minTarget = 1;
  static const int maxTarget = 9999;

  static int? read(String assessmentId) => null;

  static void write(String assessmentId, int value) {}

  static void clear(String assessmentId) {}
}
