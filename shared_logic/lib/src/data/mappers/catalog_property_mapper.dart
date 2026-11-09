import '../../domain/entities/commercial_property.dart';

/// JSON → domain mapping for the `/api/v1/catalog/*` payloads
/// (`sitewise_app.properties` — the imported F&B research workbook).
///
/// Moved here from the Jaspr-specific `ApiPropertyRepository.fromJson()` so
/// both apps map catalogue rows identically. Column allow-list lives in
/// `backend/src/sitewise/repositories/catalog_repository.py::PROPERTY_COLUMNS`.
abstract final class CatalogPropertyMapper {
  /// Catalogue row → entity.
  ///
  /// Provenance notes carried over verbatim:
  ///  * dataset quality checks are NOT administrator verification, so every
  ///    catalogue row maps to [VerificationStatus.pending] — the catalogue
  ///    table has no status column to read;
  ///  * `suitability_score` is the workbook's imported index (a ranking
  ///    input), never a success probability;
  ///  * `ownerId` is genuinely unknown for imported rows and stays ''.
  static CommercialProperty fromJson(Map<String, dynamic> row) {
    final score = (row['suitability_score'] as num?)?.toDouble();
    return CommercialProperty(
      id: row['id'] as String,
      title: row['title'] as String,
      address: row['address'] as String,
      city: row['city'] as String? ?? '',
      state: row['state'] as String,
      postcode: row['postcode'] as String? ?? '',
      rentalRm: (row['rental_rm'] as num).toDouble(),
      sizeSqft: (row['size_sqft'] as num).toDouble(),
      latitude: (row['latitude'] as num?)?.toDouble() ?? 0,
      longitude: (row['longitude'] as num?)?.toDouble() ?? 0,
      propertyType: row['property_type'] as String,
      verification: VerificationStatus.pending,
      suitabilityScore: score ?? 0,
      hasSuitabilityScore: score != null,
      ownerId: '',
      hasTour: false,
      imageUrl: row['image_url'] as String?,
      sourceUrl: row['source_url'] as String?,
      tags: [
        'Imported dataset',
        if (row['dataset_validation'] != null)
          'Quality: ${row['dataset_validation']}',
      ],
    );
  }
}
