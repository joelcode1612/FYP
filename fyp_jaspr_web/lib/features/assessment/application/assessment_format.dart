/// Shared rendering of the timestamps the assessment API returns.
///
/// Extracted because the workspace, the history list and the dashboard's
/// "Current assessment" card all show the same `updated_at` / `completed_at`
/// values, and three private copies of a date formatter drift apart.
library;

/// Renders an ISO timestamp as a short local date and time. Returns the raw
/// string when it cannot be parsed, rather than showing a wrong date.
String assessmentStamp(String iso) {
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return iso;
  return formatAssessmentStamp(parsed.toLocal());
}

/// [assessmentStamp] for a nullable field, so callers never have to branch.
String? assessmentStampOrNull(String? iso) =>
    iso == null ? null : assessmentStamp(iso);

String formatAssessmentStamp(DateTime value) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}';
}
