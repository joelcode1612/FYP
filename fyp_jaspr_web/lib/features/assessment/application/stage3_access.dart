/// Check the independently read current M2 link against server readiness.
/// An unavailable or changed link never grants access.
Future<bool> verifyStage3M2Link({
  required String expectedM2Id,
  required Future<Map<String, dynamic>?> Function() readCurrentLink,
}) async {
  if (expectedM2Id.isEmpty) return false;
  final link = await readCurrentLink();
  return link?['m2_assessment_id'] == expectedM2Id;
}
