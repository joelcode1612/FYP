/// Verification lifecycle for a commercial property listing.
enum VerificationStatus { draft, pending, verified, rejected }

extension VerificationStatusLabel on VerificationStatus {
  String get label => switch (this) {
    VerificationStatus.draft => 'Draft',
    VerificationStatus.pending => 'Pending review',
    VerificationStatus.verified => 'Verified',
    VerificationStatus.rejected => 'Rejected',
  };
}

/// Core business concept. Pure Dart — no Flutter imports.
class CommercialProperty {
  final String id;
  final String title;
  final String address;
  final String city;
  final String state;
  final String postcode;

  /// Asking rental. [rentalMaxRm] is set when the owner gives a range
  /// (e.g. RM 7,000–RM 8,000); otherwise it equals [rentalRm].
  final double rentalRm;
  final double rentalMaxRm;
  final double sizeSqft;
  final double latitude;
  final double longitude;
  final String propertyType; // Shop lot, Corner unit, Food court stall…
  final VerificationStatus verification;
  final double suitabilityScore; // 0–100
  final String ownerId;
  final bool hasTour;

  /// Business requirements the unit satisfies (Ground Floor, F&B Suitable…).
  final List<String> requirements;
  final List<String> tags;

  const CommercialProperty({
    required this.id,
    required this.title,
    required this.address,
    required this.city,
    required this.state,
    required this.postcode,
    required this.rentalRm,
    double? rentalMaxRm,
    required this.sizeSqft,
    required this.latitude,
    required this.longitude,
    required this.propertyType,
    required this.verification,
    required this.suitabilityScore,
    required this.ownerId,
    required this.hasTour,
    this.requirements = const [],
    this.tags = const [],
  }) : rentalMaxRm = rentalMaxRm ?? rentalRm;

  bool get hasRentalRange => rentalMaxRm > rentalRm;

  String get rentalDisplay {
    String fmt(double v) => 'RM ${v.toStringAsFixed(0)}';
    if (hasRentalRange) return '${fmt(rentalRm)}–${fmt(rentalMaxRm)}';
    return fmt(rentalRm);
  }

  double get rentalPerSqft => sizeSqft <= 0 ? 0 : rentalRm / sizeSqft;

  CommercialProperty copyWith({
    VerificationStatus? verification,
    String? title,
    double? rentalRm,
    double? rentalMaxRm,
    double? sizeSqft,
  }) => CommercialProperty(
    id: id,
    title: title ?? this.title,
    address: address,
    city: city,
    state: state,
    postcode: postcode,
    rentalRm: rentalRm ?? this.rentalRm,
    rentalMaxRm: rentalMaxRm ?? this.rentalMaxRm,
    sizeSqft: sizeSqft ?? this.sizeSqft,
    latitude: latitude,
    longitude: longitude,
    propertyType: propertyType,
    verification: verification ?? this.verification,
    suitabilityScore: suitabilityScore,
    ownerId: ownerId,
    hasTour: hasTour,
    requirements: requirements,
    tags: tags,
  );
}
