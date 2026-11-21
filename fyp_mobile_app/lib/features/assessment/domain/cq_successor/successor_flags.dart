/// Explicit, immutable successor feature flags. ALL DEFAULT OFF / SAFE.
///
/// There is no flag that can promote a synthetic fixture into real
/// authorization by renaming it. Production fielding and report release are
/// hard-coded false and are not constructible as true from this class.
library;

class SuccessorFlags {
  final bool syntheticMode;
  final bool serverAuthoritativeRouting;
  final bool historicalDemoToggle;
  final bool q09Q10ScientificGatesApproved;
  final bool bilingualApproved;
  final bool productionFieldingAuthorized;
  final bool reportReleaseAuthorized;

  const SuccessorFlags({
    this.syntheticMode = false,
    this.serverAuthoritativeRouting = false,
    this.historicalDemoToggle = false,
    this.q09Q10ScientificGatesApproved = false,
    this.bilingualApproved = false,
    this.productionFieldingAuthorized = false,
    this.reportReleaseAuthorized = false,
  });

  /// The only profile available for development. Still does NOT enable
  /// authoritative server wiring, scientific gates or bilingual activation.
  const SuccessorFlags.syntheticReview()
      : syntheticMode = true,
        serverAuthoritativeRouting = false,
        historicalDemoToggle = false,
        q09Q10ScientificGatesApproved = false,
        bilingualApproved = false,
        productionFieldingAuthorized = false,
        reportReleaseAuthorized = false;
}
