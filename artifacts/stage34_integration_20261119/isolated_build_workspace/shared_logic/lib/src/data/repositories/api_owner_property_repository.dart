import '../../domain/entities/commercial_property.dart';
import '../../domain/repositories/property_repository.dart';
import '../../core/network/api_client.dart';

/// Live [PropertyRepository] for the OWNER LISTING workflow over the
/// authenticated FastAPI `/properties` endpoints
/// (`backend/src/sitewise/api/v1/properties.py`, table `public.property`).
///
/// Depends only on the abstract [ApiClient] port: pure Dart, browser-safe.
/// Ownership is decided by the backend from the verified bearer identity —
/// `getPropertiesByOwner` calls `/properties/mine` and never sends a user id,
/// so a client cannot read or mutate another account's listings.
///
/// This is the operational `public.property` table (owner-created listings),
/// NOT the imported research catalogue (`sitewise_app.properties`) nor the
/// `fyp.rental_properties` research schema — those ids are different
/// universes and must not be mixed. The table stores no coordinates or
/// city/state (address resolution lives in `public.address`), so those
/// entity fields are honestly empty/zero rather than invented.
class ApiOwnerPropertyRepository implements PropertyRepository {
  final ApiClient _client;

  ApiOwnerPropertyRepository(this._client);

  /// The backend caps `limit` at 100 (`list_properties`), returning a bare
  // array per page (the bridge wraps arrays as {'data': [...]}).
  static const int _pageSize = 100;

  /// `public.property.status` is a free text column; keyword-match it to the
  /// shared verification vocabulary the same way `StatusBadge.forText` does.
  static VerificationStatus _verification(String? raw) {
    final s = (raw ?? '').toLowerCase();
    if (s.contains('reject')) return VerificationStatus.rejected;
    if (s.contains('verif') || s.contains('approv')) {
      return VerificationStatus.verified;
    }
    if (s.contains('pend') || s.contains('review')) {
      return VerificationStatus.pending;
    }
    return VerificationStatus.draft;
  }

  /// Backend row (`RentalProperty` SQLModel) → domain entity. Nullable
  /// numerics default to 0; the status keyword maps to the shared enum.
  static CommercialProperty fromJson(Map<String, dynamic> row) {
    final price = (row['price'] as num?)?.toDouble() ?? 0;
    final title = (row['title'] as String?) ?? '';
    return CommercialProperty(
      id: '${row['property_id']}',
      title: title,
      address: (row['normalized_address'] as String?) ?? '',
      city: '',
      state: '',
      postcode: '',
      rentalRm: price,
      sizeSqft: (row['built_up_area_sqft'] as num?)?.toDouble() ?? 0,
      latitude: 0,
      longitude: 0,
      propertyType: (row['property_type_normalized'] as String?) ?? '',
      verification: _verification(row['status'] as String?),
      suitabilityScore: 0,
      ownerId: '${row['user_id'] ?? ''}',
      hasTour: false,
      tags: [
        if ((row['company_name'] as String?)?.isNotEmpty == true)
          'Company: ${row['company_name']}',
      ],
    );
  }

  /// Domain entity → backend write body. Field names match the SQLModel
  /// columns exactly; the backend re-stamps ownership and rejects client
  /// `user_id` values.
  static Map<String, dynamic> _toBody(CommercialProperty p) => {
    'title': p.title,
    'description': p.address,
    'price': p.rentalRm,
    'built_up_area_sqft': p.sizeSqft,
    'property_type_normalized': p.propertyType,
    'normalized_address': p.address,
  };

  @override
  Future<List<CommercialProperty>> getProperties() async {
    final properties = <CommercialProperty>[];
    var offset = 0;
    while (true) {
      final response = await _client.get(
        '/api/v1/properties/',
        query: {'limit': '$_pageSize', 'offset': '$offset'},
      );
      final page = (response['data'] as List? ?? const [])
          .cast<Map<String, dynamic>>();
      properties.addAll(page.map(fromJson));
      offset += page.length;
      if (page.length < _pageSize) break;
    }
    return List.unmodifiable(properties);
  }

  @override
  Future<CommercialProperty?> getPropertyById(String id) async {
    try {
      return fromJson(await _client.get('/api/v1/properties/$id'));
    } on Object {
      return null;
    }
  }

  @override
  Future<List<CommercialProperty>> getPropertiesByOwner(String ownerId) async {
    // `ownerId` is deliberately ignored: the backend derives the owner from
    // the verified token (`/properties/mine`), so this parameter exists only
    // to satisfy the domain interface.
    final response = await _client.get('/api/v1/properties/mine');
    final rows = (response['data'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    return List.unmodifiable(rows.map(fromJson));
  }

  @override
  Future<CommercialProperty> createProperty(
    CommercialProperty property,
  ) async => fromJson(await _client.post('/api/v1/properties/', _toBody(property)));

  @override
  Future<void> updateProperty(CommercialProperty property) =>
      _client.patch('/api/v1/properties/${property.id}', _toBody(property));

  @override
  Future<void> submitForVerification(String id) =>
      updateVerification(id, VerificationStatus.pending);

  @override
  Future<void> updateVerification(String id, VerificationStatus status) =>
      _client.patch('/api/v1/properties/$id', {
        'status': switch (status) {
          VerificationStatus.draft => 'draft',
          VerificationStatus.pending => 'pending',
          VerificationStatus.verified => 'verified',
          VerificationStatus.rejected => 'rejected',
        },
      });
}
