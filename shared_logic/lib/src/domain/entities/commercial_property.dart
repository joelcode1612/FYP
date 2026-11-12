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

  /// Derived by the backend from an operational listing + owner/agent links.
  /// A catalogue record without a proven manager stays unassigned.
  final String managementLabel;
  final String? managerName;
  final bool hasTour;
  final String? imageUrl;

  /// Where this listing was imported from, when the dataset recorded it.
  /// Null means the source workbook has no link — never render a made-up one.
  final String? sourceUrl;

  /// Business requirements the unit satisfies (Ground Floor, F&B Suitable…).
  final List<String> requirements;
  final List<String> tags;

  /// --- Backend-served descriptive fields -----------------------------------
  ///
  /// All optional and null when the backend returned SQL NULL. A null here
  /// means "the listing does not record this" — UI must render that honestly,
  /// never as 0 or an empty-string fact.

  /// Free-text listing description (`fyp.rental_properties.description`).
  final String? description;

  /// Observed availability state from the source listing
  /// (`availability` — e.g. "Available now", "Tenanted").
  final String? availability;

  /// Land tenure (`tenure` — Freehold / Leasehold), null when unrecorded.
  final String? tenure;

  /// Furnishing state (`furnishing`), null when unrecorded.
  final String? furnishing;

  /// Floor level label (`floor_level` — Ground, 1st Floor…), null when
  /// unrecorded.
  final String? floorLevel;

  /// Bathroom count; null when the source did not record one. 0 is a genuine
  /// recorded zero and is preserved as such.
  final int? bathrooms;

  /// Research-derived boolean attributes. Nullable tri-state: true/false is a
  /// recorded value, null means the row does not carry the flag.
  final bool? isFnbSuitable;
  final bool? hasParking;
  final bool? isCornerLot;
  final bool? isFreehold;

  /// Price per square foot as the backend computed it (`psf`). Null when the
  /// row has no computed psf; use [rentalPerSqft] only as a client-side
  /// fallback, clearly derived from rental and size.
  final double? psf;

  /// True when a verified research subject link exists
  /// (`fyp.property_subject_links.match_verified`). False is the honest
  /// default: most published rows have no verified link.
  final bool hasResearchLink;

  /// All stored photo URLs (`fyp.property_photos`), primary first. Empty
  /// means the listing has no photographs — a real state, not an error.
  final List<String> imageUrls;

  /// Precomputed research indicators joined onto the listing row
  /// (`fyp.property_geospatial_features`). Nullable exactly when the
  /// backend returned NULL — "not calculated" must stay distinguishable
  /// from a genuine zero count. These are F&B-competitor research counts,
  /// NOT nearby commercial properties.
  final int? competitorCount500m;
  final int? competitorCount1km;

  /// Research population estimates joined onto the row (null = not
  /// calculated).
  final double? population500m;
  final double? population1km;

  /// The research accessibility score for the area (0–100 scale), null when
  /// the geospatial features row is absent.
  final double? accessibilityScore;

  /// Real number of OTHER approved+published commercial listings within the
  /// explore radius (geodesic PostGIS count, `nearby_property_count`). Null
  /// when the request did not ask for the nearby filter — deliberately
  /// separate from [competitorCount500m], which is an F&B research aggregate
  /// and must never be shown as a nearby-property number.
  final int? nearbyPropertyCount;

  /// True only when [suitabilityScore] carries an authoritative research
  /// value. False means "no score exists" — UI must hide the badge instead
  /// of showing a fabricated 0.
  final bool hasSuitabilityScore;

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
    this.hasSuitabilityScore = true,
    required this.ownerId,
    this.managementLabel = 'Management not assigned',
    this.managerName,
    required this.hasTour,
    this.imageUrl,
    this.sourceUrl,
    this.requirements = const [],
    this.tags = const [],
    this.description,
    this.availability,
    this.tenure,
    this.furnishing,
    this.floorLevel,
    this.bathrooms,
    this.isFnbSuitable,
    this.hasParking,
    this.isCornerLot,
    this.isFreehold,
    this.psf,
    this.hasResearchLink = false,
    this.imageUrls = const [],
    this.competitorCount500m,
    this.competitorCount1km,
    this.population500m,
    this.population1km,
    this.accessibilityScore,
    this.nearbyPropertyCount,
  }) : rentalMaxRm = rentalMaxRm ?? rentalRm;

  bool get hasRentalRange => rentalMaxRm > rentalRm;

  String get rentalDisplay {
    String fmt(double v) => 'RM ${v.toStringAsFixed(0)}';
    if (hasRentalRange) return '${fmt(rentalRm)}–${fmt(rentalMaxRm)}';
    return fmt(rentalRm);
  }

  double get rentalPerSqft => sizeSqft <= 0 ? 0 : rentalRm / sizeSqft;

  /// Coordinates usable for mapping: false when the row has none. The (0, 0)
  /// pair is the codebase's "no coordinates" sentinel and must never be
  /// plotted or routed through distance math.
  bool get hasCoordinates => latitude != 0 || longitude != 0;

  CommercialProperty copyWith({
    VerificationStatus? verification,
    String? title,
    double? rentalRm,
    double? rentalMaxRm,
    double? sizeSqft,
    String? availability,
    bool clearAvailability = false,
    String? imageUrl,
    List<String>? imageUrls,
    List<String>? tags,
    List<String>? requirements,
    String? description,
    bool clearDescription = false,
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
    hasSuitabilityScore: hasSuitabilityScore,
    ownerId: ownerId,
    managementLabel: managementLabel,
    managerName: managerName,
    hasTour: hasTour,
    imageUrl: imageUrl ?? this.imageUrl,
    sourceUrl: sourceUrl,
    requirements: requirements ?? this.requirements,
    tags: tags ?? this.tags,
    description: clearDescription ? null : (description ?? this.description),
    availability: clearAvailability ? null : (availability ?? this.availability),
    tenure: tenure,
    furnishing: furnishing,
    floorLevel: floorLevel,
    bathrooms: bathrooms,
    isFnbSuitable: isFnbSuitable,
    hasParking: hasParking,
    isCornerLot: isCornerLot,
    isFreehold: isFreehold,
    psf: psf,
    hasResearchLink: hasResearchLink,
    imageUrls: imageUrls ?? this.imageUrls,
    competitorCount500m: competitorCount500m,
    competitorCount1km: competitorCount1km,
    population500m: population500m,
    population1km: population1km,
    accessibilityScore: accessibilityScore,
    nearbyPropertyCount: nearbyPropertyCount,
  );
}
