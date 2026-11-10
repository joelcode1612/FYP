import 'package:shared_logic/shared_logic.dart';

import '../../data/datasources/local/draft_local_data_source.dart';

/// Typed, user-scoped draft persistence for the mobile app's long-form
/// workflows. One authoritative store: screens and controllers never touch
/// files, and the namespace switch is the only account-isolation rule.
///
/// What is stored (deliberately):
///  * `preferences` — the entrepreneur's recommendation criteria.
///  * `assessment`  — the in-progress location assessment (inputs + step),
///    so an interrupted app resumes instead of discarding typed work.
///  * `auth_email`  — the remembered sign-in address (device scope).
///
/// What is NEVER stored: passwords, tokens, session material. Those live in
/// the secure storage the auth layer already owns. [clearAll] exists for
/// explicit discard; a failed request never triggers it (§4 of the brief).
class ApplicationDraftRepository {
  ApplicationDraftRepository(this._local);

  final DraftLocalDataSource _local;

  /// `device` until a verified identity is known, then the account id.
  String _namespace = 'device';

  String get namespace => _namespace;

  /// Re-scopes the store to an account (or back to `device` on sign-out).
  /// Does NOT delete anything — each account's drafts stay isolated under
  /// their own directory.
  void setAccount(String? userId) {
    final id = userId?.trim();
    _namespace = (id == null || id.isEmpty) ? 'device' : id;
  }

  // --- Preferences ----------------------------------------------------------

  static const _workflowPreferences = 'preferences';

  Future<BusinessPreferences?> loadPreferences() async {
    final payload = await _local.read(_namespace, _workflowPreferences);
    if (payload == null) return null;
    List<String> list(Object? raw) => [
      for (final item in (raw as List? ?? const [])) '$item',
    ];
    final maxSize = (payload['max_size_sqft'] as num?)?.toDouble();
    return BusinessPreferences(
      businessType: payload['business_type'] as String? ?? '',
      preferredLocation: payload['preferred_location'] as String? ?? '',
      minBudgetRm: (payload['min_budget_rm'] as num?)?.toDouble() ?? 0,
      maxBudgetRm: (payload['max_budget_rm'] as num?)?.toDouble() ?? 0,
      propertyType: payload['property_type'] as String? ?? 'Any',
      minSizeSqft: (payload['min_size_sqft'] as num?)?.toDouble() ?? 0,
      maxSizeSqft: maxSize ?? double.infinity,
      requirements: list(payload['requirements']),
      preferredAreas: list(payload['preferred_areas']),
      seatingModel: payload['seating_model'] as String? ?? '',
    );
  }

  Future<void> savePreferences(BusinessPreferences value) => _local.write(
    _namespace,
    _workflowPreferences,
    {
      'business_type': value.businessType,
      'preferred_location': value.preferredLocation,
      'min_budget_rm': value.minBudgetRm,
      'max_budget_rm': value.maxBudgetRm,
      'property_type': value.propertyType,
      'min_size_sqft': value.minSizeSqft,
      // `double.infinity` is not valid JSON; persist null = "no ceiling" and
      // restore it as infinity, which is what the field means.
      'max_size_sqft': value.maxSizeSqft.isFinite ? value.maxSizeSqft : null,
      'requirements': value.requirements,
      'preferred_areas': value.preferredAreas,
      'seating_model': value.seatingModel,
    },
  );

  // --- Assessment draft -----------------------------------------------------

  static const _workflowAssessment = 'assessment';

  Future<AssessmentDraftData?> loadAssessment() async {
    final payload = await _local.read(_namespace, _workflowAssessment);
    if (payload == null) return null;
    final propertyRaw = payload['property'];
    return AssessmentDraftData(
      propertyId: payload['property_id'] as String? ?? '',
      concept: payload['concept'] as String? ?? '',
      audience: payload['audience'] as String? ?? '',
      budgetRm: (payload['budget_rm'] as num?)?.toDouble(),
      saved: payload['saved'] == true,
      property: propertyRaw is Map<String, dynamic>
          ? propertyFromSnapshot(propertyRaw)
          : null,
    );
  }

  Future<void> saveAssessment(AssessmentDraftData draft) => _local.write(
    _namespace,
    _workflowAssessment,
    {
      'property_id': draft.propertyId,
      'concept': draft.concept,
      'audience': draft.audience,
      'budget_rm': draft.budgetRm,
      'saved': draft.saved,
      if (draft.property != null)
        'property': propertySnapshot(draft.property!),
    },
  );

  /// Cleared only after a confirmed successful submission or an explicit
  /// discard — never after a failed request.
  Future<void> clearAssessment() =>
      _local.clear(_namespace, _workflowAssessment);

  // --- Remembered sign-in address (non-sensitive) ----------------------------

  static const _workflowAuthEmail = 'auth_email';

  Future<String?> loadDraftEmail() async {
    final payload = await _local.read('device', _workflowAuthEmail);
    return payload?['email'] as String?;
  }

  /// Device scope on purpose: the address is not an account secret and must
  /// survive account switching only as a convenience, never as data.
  Future<void> saveDraftEmail(String email) => _local.write('device', _workflowAuthEmail, {
    'email': email.trim(),
  });

  Future<void> clearDraftEmail() =>
      _local.clear('device', _workflowAuthEmail);

  /// Explicit "discard my drafts" — the user's action, never a failure path.
  Future<void> clearAll() => _local.clearNamespace(_namespace);
}

/// Plain data carrier mirroring the in-session [assessment session draft] so
/// `AssessmentSessionStore` can be restored across process restarts without
/// a network lookup. [property] carries the persisted listing snapshot.
class AssessmentDraftData {
  final String propertyId;
  final String concept;
  final String audience;
  final double? budgetRm;
  final bool saved;
  final CommercialProperty? property;

  const AssessmentDraftData({
    required this.propertyId,
    this.concept = '',
    this.audience = '',
    this.budgetRm,
    this.saved = false,
    this.property,
  });
}

/// Snapshot codec for the property a draft points at. Persisting the entity
/// fields (not just the id) is what lets an interrupted app restore the
/// assessment inputs without a network round trip — and what keeps the
/// restore working when the listing service is unreachable. Values the
/// snapshot omits come back honestly empty/zero, never invented.
Map<String, dynamic> propertySnapshot(CommercialProperty p) => {
  'id': p.id,
  'title': p.title,
  'address': p.address,
  'city': p.city,
  'state': p.state,
  'postcode': p.postcode,
  'rental_rm': p.rentalRm,
  'rental_max_rm': p.rentalMaxRm,
  'size_sqft': p.sizeSqft,
  'latitude': p.latitude,
  'longitude': p.longitude,
  'property_type': p.propertyType,
  'verification': p.verification.name,
  'suitability_score': p.suitabilityScore,
  'has_suitability_score': p.hasSuitabilityScore,
  'owner_id': p.ownerId,
  'has_tour': p.hasTour,
  'image_url': p.imageUrl,
  'description': p.description,
  'availability': p.availability,
};

CommercialProperty propertyFromSnapshot(Map<String, dynamic> raw) =>
    CommercialProperty(
      id: raw['id'] as String? ?? '',
      title: raw['title'] as String? ?? '',
      address: raw['address'] as String? ?? '',
      city: raw['city'] as String? ?? '',
      state: raw['state'] as String? ?? '',
      postcode: raw['postcode'] as String? ?? '',
      rentalRm: (raw['rental_rm'] as num?)?.toDouble() ?? 0,
      rentalMaxRm: (raw['rental_max_rm'] as num?)?.toDouble(),
      sizeSqft: (raw['size_sqft'] as num?)?.toDouble() ?? 0,
      latitude: (raw['latitude'] as num?)?.toDouble() ?? 0,
      longitude: (raw['longitude'] as num?)?.toDouble() ?? 0,
      propertyType: raw['property_type'] as String? ?? '',
      verification: switch (raw['verification'] as String?) {
        'verified' => VerificationStatus.verified,
        'pending' => VerificationStatus.pending,
        'rejected' => VerificationStatus.rejected,
        _ => VerificationStatus.draft,
      },
      suitabilityScore: (raw['suitability_score'] as num?)?.toDouble() ?? 0,
      hasSuitabilityScore: raw['has_suitability_score'] == true,
      ownerId: raw['owner_id'] as String? ?? '',
      hasTour: raw['has_tour'] == true,
      imageUrl: raw['image_url'] as String?,
      description: raw['description'] as String?,
      availability: raw['availability'] as String?,
    );
