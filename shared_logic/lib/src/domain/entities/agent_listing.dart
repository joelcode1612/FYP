/// Entities for the Agent Property Management workflow.
///
/// One assigned listing (Supabase `listing` row, numeric `listing_id`) is
/// joined server-side with its OPERATIONAL property record
/// (`fyp.rental_properties`, the SAME numeric id) — the backend performs the
/// join, so no client ever converts between id systems. Every field is read
/// defensively: a row the live table does not carry is simply absent, and the
/// UI renders an explicit "not provided" state rather than inventing a value.
library;

/// The Supabase assignment row (`GET /api/v1/staff/me/listings`).
class AgentAssignment {
  /// The OPERATIONAL numeric listing id — the same value
  /// `fyp.rental_properties.id` uses.
  final int listingId;

  /// The `public.agent` profile id this listing is assigned to.
  final int? agentId;

  /// Any other columns the live `listing` table carries, keyed verbatim.
  final Map<String, dynamic> raw;

  const AgentAssignment({
    required this.listingId,
    required this.agentId,
    required this.raw,
  });

  factory AgentAssignment.fromJson(Map<String, dynamic> row) {
    final id = row['listing_id'] ?? row['id'];
    return AgentAssignment(
      listingId: id is num ? id.toInt() : int.tryParse('$id') ?? 0,
      agentId: (row['agent_id'] as num?)?.toInt(),
      raw: row,
    );
  }

  /// Best display title from the assignment row, without inventing one.
  String get displayTitle {
    for (final key in const ['original_title', 'title', 'name']) {
      final value = raw[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return '';
  }

  String get displayId => 'L-$listingId';
}

/// The operational property row joined by the backend for one assignment.
class AgentListingFacts {
  final int id;
  final String name;
  final String? propertyType;
  final String? description;
  final String? address;
  final String? city;
  final String? state;
  final String? postcode;
  final double? rentalPrice;
  final double? sizeSqft;
  final double? psf;
  final String? availability;
  final double? floorLevel;
  final bool hasParking;
  final bool isFnbSuitable;

  /// Backend wire value: `draft` | `pending` | `approved` | `rejected`.
  final String verificationStatus;
  final bool isPublished;
  final String? rejectionReason;

  /// The submitting owner's user id (`null` on imported research rows).
  final String? ownerUserId;
  final String? updatedAt;

  const AgentListingFacts({
    required this.id,
    required this.name,
    required this.verificationStatus,
    required this.hasParking,
    required this.isFnbSuitable,
    required this.isPublished,
    this.propertyType,
    this.description,
    this.address,
    this.city,
    this.state,
    this.postcode,
    this.rentalPrice,
    this.sizeSqft,
    this.psf,
    this.availability,
    this.floorLevel,
    this.rejectionReason,
    this.ownerUserId,
    this.updatedAt,
  });

  factory AgentListingFacts.fromJson(Map<String, dynamic> row) =>
      AgentListingFacts(
        id: (row['id'] as num?)?.toInt() ?? 0,
        name: '${row['name'] ?? ''}'.trim(),
        propertyType: row['property_type']?.toString(),
        description: row['description']?.toString(),
        address: row['address']?.toString(),
        city: row['city']?.toString(),
        state: row['state']?.toString(),
        postcode: row['postcode']?.toString(),
        rentalPrice: (row['rental_price'] as num?)?.toDouble(),
        sizeSqft: (row['size_sqft'] as num?)?.toDouble(),
        psf: (row['psf'] as num?)?.toDouble(),
        availability: row['availability']?.toString(),
        floorLevel: (row['floor_level'] as num?)?.toDouble(),
        hasParking: row['has_parking'] == true || row['has_parking'] == 1,
        isFnbSuitable:
            row['is_fnb_suitable'] == true || row['is_fnb_suitable'] == 1,
        verificationStatus: '${row['verification_status'] ?? ''}',
        rejectionReason: row['rejection_reason']?.toString(),
        isPublished: row['is_published'] == true,
        ownerUserId: row['owner_user_id']?.toString(),
        updatedAt: row['updated_at']?.toString(),
      );

  /// `RM 6,500` style display (whole ringgit), empty when absent.
  String get rentalDisplay =>
      rentalPrice == null ? '' : 'RM ${rentalPrice!.round().toString()}';

  String get areaDisplay =>
      sizeSqft == null ? '' : '${sizeSqft!.round().toString()} sqft';

  String get addressDisplay {
    final parts = [
      ?address,
      ?city,
      ?postcode,
      ?state,
    ].where((p) => p.trim().isNotEmpty).toList();
    return parts.join(', ');
  }
}

/// The submitting owner's identity reference, shown only when the backend
/// resolved one (imported research rows carry no owner).
class AgentOwnerReference {
  final String userId;
  final String fullName;
  final String email;

  const AgentOwnerReference({
    required this.userId,
    required this.fullName,
    required this.email,
  });

  factory AgentOwnerReference.fromJson(Map<String, dynamic> row) =>
      AgentOwnerReference(
        userId: '${row['user_id'] ?? ''}',
        fullName: '${row['full_name'] ?? ''}'.trim(),
        email: '${row['email'] ?? ''}'.trim(),
      );

  String get displayName => fullName.isNotEmpty ? fullName : email;
}

/// One property photo of the operational listing.
class AgentPhoto {
  final int id;
  final String url;
  final String caption;
  final bool isPrimary;

  const AgentPhoto({
    required this.id,
    required this.url,
    required this.caption,
    required this.isPrimary,
  });

  factory AgentPhoto.fromJson(Map<String, dynamic> row) => AgentPhoto(
    id: (row['photo_id'] as num?)?.toInt() ?? (row['id'] as num?)?.toInt() ?? 0,
    url: '${row['url'] ?? ''}',
    caption: '${row['caption'] ?? ''}',
    isPrimary: row['is_primary'] == true,
  );
}

/// One agent change request (`listing_change_request`).
class AgentChangeRequest {
  static const statusDraft = 'draft';
  static const statusPending = 'pending';
  static const statusApproved = 'approved';
  static const statusRejected = 'rejected';
  static const statusChangesRequested = 'changes_requested';

  final String changeRequestId;
  final int listingId;
  final String proposedBy;

  /// `{field: {"from": …, "to": …}}` — captured server-side.
  final Map<String, Map<String, dynamic>> changes;
  final String status;
  final String? reason;
  final String? reviewNote;
  final String createdAt;
  final String updatedAt;

  const AgentChangeRequest({
    required this.changeRequestId,
    required this.listingId,
    required this.proposedBy,
    required this.changes,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.reason,
    this.reviewNote,
  });

  factory AgentChangeRequest.fromJson(Map<String, dynamic> row) =>
      AgentChangeRequest(
        changeRequestId: '${row['change_request_id'] ?? ''}',
        listingId: (row['listing_id'] as num?)?.toInt() ?? 0,
        proposedBy: '${row['proposed_by'] ?? ''}',
        changes: (row['changes'] as Map<String, dynamic>? ?? {}).map(
          (field, value) => MapEntry(
            field,
            value is Map<String, dynamic> ? value : <String, dynamic>{},
          ),
        ),
        status: '${row['status'] ?? ''}',
        reason: row['reason']?.toString(),
        reviewNote: row['review_note']?.toString(),
        createdAt: '${row['created_at'] ?? ''}',
        updatedAt: '${row['updated_at'] ?? ''}',
      );

  bool get isDraft => status == statusDraft;
  bool get isPending => status == statusPending;
}

/// One Activity-timeline event.
///
/// [source] distinguishes the two REAL event stores: `change` rows come from
/// the local `listing_change_audit` table (draft saves, review requests,
/// administrator decisions, agent notes); `verification` rows come from the
/// Supabase `listing_verification` findings (site-visit findings recorded
/// through the pre-existing staff mechanism). Timestamps and actor ids are
/// server values in both cases.
class AgentActivityEvent {
  final String source;
  final String action;
  final String actorId;
  final String? note;

  /// Server timestamp, ISO-8601 (`''` when the row carries none).
  final String createdAt;
  final Map<String, dynamic> raw;

  const AgentActivityEvent({
    required this.source,
    required this.action,
    required this.actorId,
    required this.createdAt,
    required this.raw,
    this.note,
  });

  /// Human label per action; unknown values fall back to the raw action.
  String get label => switch (action) {
    'draft_saved' => 'Draft saved',
    'review_requested' => 'Review requested',
    'approve' || 'approved' => 'Approved',
    'reject' || 'rejected' => 'Rejected',
    'changes_requested' => 'Changes requested',
    'note_added' => 'Internal note',
    _ => action,
  };
}

/// Everything the management page needs for one assigned listing.
class AgentListingDetail {
  final AgentAssignment assignment;

  /// `null` when the numeric id has no operational row — the page shows an
  /// explicit "operational record not linked" state.
  final AgentListingFacts? facts;
  final AgentOwnerReference? owner;
  final List<AgentPhoto> photos;

  /// The open (`draft`/`pending`) request, `null` when none applies.
  final AgentChangeRequest? openRequest;

  const AgentListingDetail({
    required this.assignment,
    required this.facts,
    required this.owner,
    required this.photos,
    required this.openRequest,
  });
}

/// A proposed field change the agent is sending for server-side diffing.
///
/// Only agent-proposable fields are ever carried; the registered address and
/// publication flags have no slot here by construction.
class AgentProposal {
  final String? name;
  final double? rentalPrice;
  final double? sizeSqft;
  final String? propertyType;
  final String? floorLevel;
  final String? availability;
  final String? description;
  final bool? hasParking;
  final bool? isFnbSuitable;

  const AgentProposal({
    this.name,
    this.rentalPrice,
    this.sizeSqft,
    this.propertyType,
    this.floorLevel,
    this.availability,
    this.description,
    this.hasParking,
    this.isFnbSuitable,
  });

  Map<String, dynamic> toBody() => {
    if (name != null) 'name': name,
    if (rentalPrice != null) 'rental_price': rentalPrice,
    if (sizeSqft != null) 'size_sqft': sizeSqft,
    if (propertyType != null) 'property_type': propertyType,
    if (floorLevel != null) 'floor_level': floorLevel,
    if (availability != null) 'availability': availability,
    if (description != null) 'description': description,
    if (hasParking != null) 'has_parking': hasParking,
    if (isFnbSuitable != null) 'is_fnb_suitable': isFnbSuitable,
  };
}
