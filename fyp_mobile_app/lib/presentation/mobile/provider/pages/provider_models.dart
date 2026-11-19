import 'package:shared_logic/shared_logic.dart';

import '../../../../application/services/service_locator.dart';

/// One listing as the Owner / Agent workspace needs it.
///
/// Owners and agents reach the SAME operational record (`fyp.rental_properties`)
/// through different authorized endpoints: an owner through
/// `GET /api/v1/properties/listings/mine`, an assigned agent through
/// `GET /api/v1/staff/me/listings`. This model is the single presentation shape
/// for both, so no screen has to know which endpoint answered.
class ProviderListing {
  final int id;
  final String title;
  final String address;
  final double? rent;
  final double? sizeSqft;
  final String? propertyType;

  /// Wire value from `verification_status`: draft | pending | approved | rejected.
  final String status;
  final bool isPublished;
  final String? imageUrl;

  /// Who manages this listing, as the backend derives it from ownership or
  /// assignment. Null when the list payload predates the management block —
  /// the card then reports management as unavailable instead of guessing.
  final ProviderManagement? management;

  /// How many photographs the record carries, when the endpoint reports them
  /// (an owner listing does; an agent assignment row carries no photo list).
  /// Null means unknown — a screen must treat that as "not reported", never
  /// as zero.
  final int? photoCount;

  // ── Agent task facts (assigned listings only) ────────────────────────────
  //
  // Every one of these is READ from the authoritative records by
  // `AgentAssignmentRepository` — the listing's own verification status, the
  // `property_verification` row, and the newest note-bearing listing-dimension
  // audit entry. A null here means the database holds no such record, so a
  // card omits the line rather than inventing a deadline, a note or a date.

  /// Server-derived task state: draft | corrections | awaiting_review |
  /// approved. Null on payloads from before the projection, and on owner rows.
  final String? taskState;

  /// Required fields the record still lacks, as the submission gate words them.
  final List<String> missingRequiredFields;

  /// The administrator's recorded feedback while the listing dimension is
  /// rejected or awaiting more information.
  final String? correctionNote;

  /// Which staff action recorded that feedback (`listing_rejected` /
  /// `listing_information_requested`), i.e. the response actually asked for.
  final String? correctionAction;

  /// When the feedback was recorded (ISO-8601), when a decision row exists.
  final String? correctionAt;

  /// When the listing was submitted for review (ISO-8601), from the
  /// verification row.
  final String? submittedAt;

  /// The backend's own lock policy for this record (`can_resubmit` over the
  /// verification dimensions). Null means the payload did not report it.
  final bool? backendEditable;

  const ProviderListing({
    required this.id,
    required this.title,
    required this.address,
    required this.status,
    required this.isPublished,
    this.rent,
    this.sizeSqft,
    this.propertyType,
    this.imageUrl,
    this.management,
    this.photoCount,
    this.taskState,
    this.missingRequiredFields = const [],
    this.correctionNote,
    this.correctionAction,
    this.correctionAt,
    this.submittedAt,
    this.backendEditable,
  });

  ProviderStage get stage => ProviderStage.fromWire(status);

  /// "Active" for the workspace: approved by an administrator AND actually
  /// live. An approved-but-unpublished row is not shown as active.
  bool get isActive => stage == ProviderStage.approved && isPublished;

  /// Editing is a backend policy (records under review are locked); this
  /// mirrors it for honest UI hints only — the backend decides.
  bool get locallyEditable =>
      stage == ProviderStage.draft || stage == ProviderStage.rejected;

  /// Whether an edit action may be offered at all. An assigned row carries the
  /// server's answer; a row without it (an owner listing, or an older payload)
  /// falls back to the mirrored stage policy.
  bool get canEdit => backendEditable ?? locallyEditable;

  String get displayTitle => title.trim().isNotEmpty ? title.trim() : 'Listing L-$id';

  String get rentDisplay =>
      rent == null ? 'Rent not set' : 'RM ${rent!.round()} / month';

  String get sizeDisplay =>
      sizeSqft == null ? 'Area not set' : '${sizeSqft!.round()} sq ft';

  /// Rental per square foot, computed only when both values exist.
  String get psfDisplay {
    final r = rent;
    final s = sizeSqft;
    if (r == null || s == null || s <= 0) return '';
    return 'RM ${(r / s).toStringAsFixed(2)} psf';
  }

  /// The searchable text: title, address (which already joins street, city
  /// and state) and property type — the fields the search field advertises.
  String get searchBlob => [
    displayTitle,
    address,
    propertyType ?? '',
  ].join(' ').toLowerCase();

  static double? _num(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim());
    return null;
  }

  /// An owner submission (`OwnerListing`).
  factory ProviderListing.fromOwner(OwnerListing row) => ProviderListing(
    id: int.tryParse(row.id) ?? 0,
    title: row.name,
    address: [row.address, row.city, row.state]
        .whereType<String>()
        .where((p) => p.trim().isNotEmpty)
        .join(', '),
    rent: row.rentalPrice,
    sizeSqft: row.sizeSqft,
    propertyType: row.propertyType,
    status: row.verificationStatus,
    isPublished: row.isPublished,
    imageUrl: row.photos.isEmpty ? null : row.photos.first.url,
    photoCount: row.photos.length,
    management: row.management == null
        ? null
        : ProviderManagement.fromJson({
            'type': row.management!.type,
            'label': row.management!.label,
            'name': row.management!.name,
          }),
  );

  /// An assigned agent listing (`AgentAssignment.raw`, joined server-side with
  /// the operational property row).
  factory ProviderListing.fromAssignment(AgentAssignment row) {
    final raw = row.raw;
    final address = [raw['address'], raw['city'], raw['state']]
        .whereType<String>()
        .where((p) => p.trim().isNotEmpty)
        .join(', ');
    return ProviderListing(
      id: row.listingId,
      title: row.displayTitle,
      address: address,
      rent: _num(raw['rental_price']),
      sizeSqft: _num(raw['size_sqft']),
      propertyType: raw['property_type']?.toString(),
      status: '${raw['verification_status'] ?? ''}',
      isPublished: raw['is_published'] == true,
      imageUrl: raw['image_url']?.toString(),
      management: raw['management'] is Map<String, dynamic>
          ? ProviderManagement.fromJson(
              raw['management'] as Map<String, dynamic>,
            )
          : null,
      taskState: raw['task_state']?.toString(),
      missingRequiredFields: _strings(raw['missing_required_fields']),
      correctionNote: _text(raw['correction_reason']),
      correctionAction: _text(raw['correction_action']),
      correctionAt: _text(raw['correction_at']),
      submittedAt: _text(raw['verification_submitted_at']),
      backendEditable: raw['editable'] is bool ? raw['editable'] as bool : null,
    );
  }

  static String? _text(dynamic value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  static List<String> _strings(dynamic value) {
    if (value is! List) return const [];
    final labels = <String>[];
    for (final item in value) {
      final label = '${item ?? ''}'.trim();
      if (label.isNotEmpty) labels.add(label);
    }
    return labels;
  }
}

/// The five states the workspace filters by. [unknown] is honest about a wire
/// value this build does not recognise rather than folding it into "draft".
enum ProviderStage {
  draft,
  pending,
  approved,
  rejected,
  unknown;

  static ProviderStage fromWire(String value) => switch (value.trim()) {
    'draft' => ProviderStage.draft,
    'pending' => ProviderStage.pending,
    'approved' => ProviderStage.approved,
    'rejected' => ProviderStage.rejected,
    _ => ProviderStage.unknown,
  };

  String get label => switch (this) {
    ProviderStage.draft => 'Draft',
    ProviderStage.pending => 'Pending verification',
    ProviderStage.approved => 'Published',
    ProviderStage.rejected => 'Rejected',
    ProviderStage.unknown => 'Status unavailable',
  };

  /// The filter chip caption. "All" is handled by the screen, not a stage.
  String get filterLabel => switch (this) {
    ProviderStage.draft => 'Draft',
    ProviderStage.pending => 'Pending',
    ProviderStage.approved => 'Published',
    ProviderStage.rejected => 'Rejected',
    ProviderStage.unknown => 'Unknown',
  };
}

/// Everything one provider screen needs, loaded from the authorized endpoint
/// for the signed-in role.
class ProviderWorkspace {
  final bool isAgent;
  final String? agentName;
  final List<ProviderListing> listings;

  const ProviderWorkspace({
    required this.isAgent,
    required this.listings,
    this.agentName,
  });

  int count(ProviderStage stage) =>
      listings.where((l) => l.stage == stage).length;

  /// "Published" means approved AND actually live — an approved-but-unpublished
  /// row is not a published listing. This is also the workspace's "Active"
  /// figure: the Active stat card and the Active filter chip report it.
  int get publishedCount =>
      listings.where((l) => l.isPublished && l.stage == ProviderStage.approved).length;

  List<ProviderListing> get recent {
    final sorted = [...listings]..sort((a, b) => b.id.compareTo(a.id));
    return sorted.take(4).toList();
  }

  String get providerLabel => isAgent ? 'Agent' : 'Owner';
}

/// The status filter chips on My Listings. Every value maps onto a real
/// backend state — [assigned] is the derived management relation
/// (`agent_listing_assignment`), never an invented listing status.
enum ProviderListingsFilter {
  all,
  active,
  pending,
  draft,
  rejected,
  unknown,
  assigned;

  String get label => switch (this) {
    all => 'All',
    active => 'Active',
    pending => 'Pending',
    draft => 'Draft',
    rejected => 'Rejected',
    unknown => 'Unknown',
    assigned => 'Assigned',
  };

  /// Whether [listing] belongs under this filter. `active` follows the same
  /// published-approved rule as the stat card, so chip counts and cards always
  /// agree.
  bool matches(ProviderListing listing) => switch (this) {
    all => true,
    active => listing.isActive,
    pending => listing.stage == ProviderStage.pending,
    draft => listing.stage == ProviderStage.draft,
    rejected => listing.stage == ProviderStage.rejected,
    unknown => listing.stage == ProviderStage.unknown,
    assigned => listing.management?.isAgent ?? false,
  };

  bool matchesQuery(ProviderListing listing, String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return true;
    return listing.searchBlob.contains(needle);
  }
}

/// The chips to show for [scope] after [query] is applied.
///
/// Honesty rules encoded here:
/// * a state that matches nothing is not offered as a chip — an empty
///   "Rejected (0)" would advertise a state the portfolio does not have;
/// * `assigned` appears only when at least one visible listing is actually
///   agent-managed, so a Property Owner without any agent assignment never
///   sees an irrelevant chip;
/// * every count is computed over the SAME searched set the list will show,
///   so a chip count can never disagree with its result.
List<(ProviderListingsFilter, String, int)> providerListingsChips(
  ProviderWorkspace scope,
  String query,
) {
  final searched = [
    for (final listing in scope.listings)
      if (ProviderListingsFilter.all.matchesQuery(listing, query)) listing,
  ];
  int count(ProviderListingsFilter filter) =>
      searched.where(filter.matches).length;

  final chips = <(ProviderListingsFilter, String, int)>[
    (ProviderListingsFilter.all, 'All', searched.length),
    (ProviderListingsFilter.active, 'Active', count(ProviderListingsFilter.active)),
    (ProviderListingsFilter.pending, 'Pending', count(ProviderListingsFilter.pending)),
    (ProviderListingsFilter.draft, 'Draft', count(ProviderListingsFilter.draft)),
  ];
  final rejected = count(ProviderListingsFilter.rejected);
  if (rejected > 0) {
    chips.add((ProviderListingsFilter.rejected, 'Rejected', rejected));
  }
  final unknown = count(ProviderListingsFilter.unknown);
  if (unknown > 0) {
    chips.add((ProviderListingsFilter.unknown, 'Unknown', unknown));
  }
  final assigned = count(ProviderListingsFilter.assigned);
  if (assigned > 0) {
    chips.add((ProviderListingsFilter.assigned, 'Assigned', assigned));
  }
  return chips;
}

/// The listings shown for one filter + search combination.
List<ProviderListing> providerVisibleListings(
  ProviderWorkspace scope,
  ProviderListingsFilter filter,
  String query,
) => [
  for (final listing in scope.listings)
    if (filter.matchesQuery(listing, query) && filter.matches(listing)) listing,
];

/// Loads the workspace from the endpoint the caller is authorized for.
///
/// There is no client-side role filtering: the server decides which rows an
/// account may see, and this method only chooses the transport.
abstract final class ProviderListingsService {
  static Future<ProviderWorkspace> load(AppRole role) async {
    if (role == AppRole.agent) {
      final rows = await ServiceLocator.agentListings.assignedListings();
      return ProviderWorkspace(
        isAgent: true,
        listings: [
          for (final row in rows)
            if (row.raw['property_exists'] != false)
              ProviderListing.fromAssignment(row),
        ],
      );
    }
    final rows = await ServiceLocator.ownerListings.myListings();
    return ProviderWorkspace(
      isAgent: false,
      listings: [for (final row in rows) ProviderListing.fromOwner(row)],
    );
  }
}

/// True when the failure is the backend's structured MFA gate.
///
/// `require_agent_mfa` answers 403 with `detail.code == 'staff_mfa_required'`.
/// The transport collapses that into a message, so both the code and the
/// human sentence are matched — never a bare 403, which would also catch a
/// genuinely forbidden account.
bool isMfaRequired(Object error) {
  final text = error.toString().toLowerCase();
  return text.contains('staff_mfa_required') ||
      text.contains('multi-factor') ||
      text.contains('aal2');
}

// ---------------------------------------------------------------------------
// Performance
// ---------------------------------------------------------------------------

/// One engagement metric SiteWise does NOT record, reported with its reason so
/// the screen can say "not tracked" instead of showing a fabricated zero.
class ProviderUntrackedMetric {
  const ProviderUntrackedMetric({required this.label, required this.reason});

  final String label;
  final String reason;

  factory ProviderUntrackedMetric.fromJson(Map<String, dynamic> json) =>
      ProviderUntrackedMetric(
        label: '${json['label'] ?? ''}',
        reason: '${json['reason'] ?? ''}',
      );
}

/// Everything the Performance screen shows, straight from the server.
///
/// The enquiry figures the backend still returns are deliberately NOT parsed:
/// the Enquiries feature is removed from the mobile Provider workspace, so no
/// screen consumes them. The server payload is untouched.
class ProviderPerformance {
  const ProviderPerformance({
    required this.isAgent,
    required this.managedProperties,
    required this.total,
    required this.published,
    required this.byState,
    required this.otherState,
    required this.engagementTracked,
    required this.engagementReason,
    required this.untrackedMetrics,
    this.medianRent,
    this.averageSizeSqft,
  });

  final bool isAgent;
  final int managedProperties;
  final int total;
  final int published;
  final Map<String, int> byState;
  final int otherState;

  /// Always `false` for this build: the events do not exist.
  final bool engagementTracked;
  final String engagementReason;
  final List<ProviderUntrackedMetric> untrackedMetrics;

  final double? medianRent;
  final double? averageSizeSqft;

  int stateCount(String wire) => byState[wire] ?? 0;

  String get medianRentDisplay =>
      medianRent == null ? 'Not recorded' : 'RM ${medianRent!.round()}';

  String get averageSizeDisplay => averageSizeSqft == null
      ? 'Not recorded'
      : '${averageSizeSqft!.round()} sq ft';

  factory ProviderPerformance.fromJson(Map<String, dynamic> json) {
    final scope = json['scope'] as Map? ?? const {};
    final listings = json['listings'] as Map? ?? const {};
    final byState = listings['by_state'] as Map? ?? const {};
    final portfolio = json['portfolio'] as Map? ?? const {};
    final engagement = json['engagement'] as Map? ?? const {};
    return ProviderPerformance(
      isAgent: scope['is_agent'] == true,
      managedProperties: _int(scope['managed_properties']),
      total: _int(listings['total']),
      published: _int(listings['published']),
      byState: {
        for (final entry in byState.entries) '${entry.key}': _int(entry.value),
      },
      otherState: _int(listings['other_state']),
      engagementTracked: engagement['tracked'] == true,
      engagementReason: '${engagement['reason'] ?? ''}',
      untrackedMetrics: [
        for (final row in (engagement['metrics'] as List? ?? const [])
            .whereType<Map<String, dynamic>>())
          ProviderUntrackedMetric.fromJson(row),
      ],
      medianRent: _double(portfolio['median_rent']),
      averageSizeSqft: _double(portfolio['average_size_sqft']),
    );
  }

  static int _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? 0;
  }

  static double? _double(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }
}

// ---------------------------------------------------------------------------
// Provider (account) verification
// ---------------------------------------------------------------------------

/// One piece of information the verification submission asks for. Served by
/// the backend so the screen and the server explain the same requirements.
class ProviderVerificationRequirement {
  const ProviderVerificationRequirement({
    required this.key,
    required this.label,
    required this.required,
    required this.help,
  });

  final String key;
  final String label;
  final bool required;
  final String help;

  factory ProviderVerificationRequirement.fromJson(Map<String, dynamic> json) =>
      ProviderVerificationRequirement(
        key: '${json['key'] ?? ''}',
        label: '${json['label'] ?? ''}',
        required: json['required'] == true,
        help: '${json['help'] ?? ''}',
      );
}

/// The account-level verification state — distinct from the per-listing
/// verification of an individual property.
class ProviderVerification {
  const ProviderVerification({
    required this.status,
    required this.providerRole,
    required this.businessName,
    required this.contactPhone,
    required this.registrationNo,
    required this.submissionNote,
    required this.requirements,
    this.decisionNote,
    this.submittedAt,
    this.reviewedAt,
  });

  final String status;
  final String providerRole;
  final String businessName;
  final String contactPhone;
  final String registrationNo;
  final String submissionNote;
  final List<ProviderVerificationRequirement> requirements;
  final String? decisionNote;
  final String? submittedAt;
  final String? reviewedAt;

  bool get isUnsubmitted => status == 'unsubmitted';
  bool get isPending => status == 'pending';
  bool get isApproved => status == 'approved';
  bool get isRejected => status == 'rejected';

  /// Only an unsubmitted or rejected account may (re)submit: a pending one is
  /// already with a reviewer, and an approved one has nothing left to verify.
  bool get canSubmit => isUnsubmitted || isRejected;

  String get statusLabel => switch (status) {
    'unsubmitted' => 'Not submitted',
    'pending' => 'Awaiting review',
    'approved' => 'Verified',
    'rejected' => 'Needs correction',
    _ => 'Status unavailable',
  };

  factory ProviderVerification.fromJson(Map<String, dynamic> json) {
    final details = json['details'] as Map? ?? const {};
    return ProviderVerification(
      status: '${json['status'] ?? 'unsubmitted'}',
      providerRole: '${json['provider_role'] ?? 'owner'}',
      businessName: '${details['business_name'] ?? ''}',
      contactPhone: '${details['contact_phone'] ?? ''}',
      registrationNo: '${details['registration_no'] ?? ''}',
      submissionNote: '${details['submission_note'] ?? ''}',
      decisionNote: json['decision_note']?.toString(),
      submittedAt: json['submitted_at']?.toString(),
      reviewedAt: json['reviewed_at']?.toString(),
      requirements: [
        for (final row in (json['requirements'] as List? ?? const [])
            .whereType<Map<String, dynamic>>())
          ProviderVerificationRequirement.fromJson(row),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Management attribution
// ---------------------------------------------------------------------------

/// Who manages a listing, as the backend derives it.
///
/// The distinction is not cosmetic: an **owner** reaches a record through
/// `owner_user_id`, an **agent** through `agent_listing_assignment`. The
/// workspace must say which one applies, and whose name to show, instead of
/// assuming "I am the manager" because the row appeared in the list.
///
/// `type` is the server's own vocabulary (`owner`, `agent`, `platform`,
/// `unresolved`, `unavailable`); anything else is reported as itself rather
/// than folded into a type the server did not send.
class ProviderManagement {
  const ProviderManagement({
    required this.type,
    required this.label,
    required this.name,
    required this.reason,
  });

  final String type;
  final String label;
  final String? name;

  /// Why a manager is not named, when the server supplies a reason.
  final String? reason;

  bool get isOwner => type == 'owner';
  bool get isAgent => type == 'agent';

  /// "Owner-managed · Daniel Wong" — the wording the workspace shows.
  ///
  /// A missing name is never filled in with an email or a guess: the label
  /// stands alone and the row is marked as unnamed.
  String get display {
    final who = (name ?? '').trim();
    if (who.isEmpty) return label;
    return '$label · $who';
  }

  static const ProviderManagement unknown = ProviderManagement(
    type: 'unavailable',
    label: 'Management unavailable',
    name: null,
    reason: null,
  );

  factory ProviderManagement.fromJson(Map<String, dynamic> json) {
    final type = '${json['type'] ?? 'unavailable'}';
    final name = json['name']?.toString().trim();
    return ProviderManagement(
      type: type,
      label: (json['label']?.toString().trim().isNotEmpty ?? false)
          ? json['label'].toString().trim()
          : switch (type) {
              'owner' => 'Owner-managed',
              'agent' => 'Agent-managed',
              'platform' => 'SiteWise-managed',
              'unresolved' => 'Manager unresolved',
              _ => 'Management unavailable',
            },
      name: (name == null || name.isEmpty) ? null : name,
      reason: json['reason']?.toString(),
    );
  }
}
