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
  ///  * `suitability_score` is the expanded64 research index, when available;
  ///  * `ownerId` is genuinely unknown for imported rows and stays ''.
  /// Photo URLs from the detail endpoint's `photos` list.
  ///
  /// The backend resolves `sitewise_app.properties.id` to one numeric
  /// `fyp.property_photos.property_id` and returns every row (id, url,
  /// caption, is_primary) primary-first. Re-applying that order here keeps the
  /// first photograph stable even against an older payload, and deduplicating
  /// stops the same image from appearing twice in the gallery.
  ///
  /// The single `image_url` column is deliberately NOT appended: callers use
  /// it only as a fallback when this list is empty, so a property with real
  /// photo records never shows the workbook cover twice.
  static List<String> _imageUrls(Map<String, dynamic> row) {
    final photos = <({String url, bool primary})>[];
    for (final item in (row['photos'] as List? ?? const []).whereType<Map>()) {
      final url = item['url']?.toString().trim() ?? '';
      if (url.isEmpty) continue;
      photos.add((url: url, primary: item['is_primary'] == true));
    }
    final ordered = <({String url, bool primary})>[
      ...photos.where((p) => p.primary),
      ...photos.where((p) => !p.primary),
    ];
    final seen = <String>{};
    return [for (final p in ordered) if (seen.add(p.url)) p.url];
  }

  static CommercialProperty fromJson(Map<String, dynamic> row) {
    final score = (row['suitability_score'] as num?)?.toDouble();
    final management = row['management'] is Map
        ? (row['management'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    // Additive commercial-listing details from the detail endpoint
    // (`listing_details` — recorded research features, optionally enriched by
    // a verified, approved and published operational match). Absent on list
    // payloads; every field stays null when the source does not record it.
    final detail = row['listing_details'] is Map
        ? (row['listing_details'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
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
      managementLabel: (management['label'] as String?) ?? 'Management not assigned',
      managerName: management['name'] as String?,
      hasTour: false,
      imageUrl: row['image_url'] as String?,
      imageUrls: _imageUrls(row),
      sourceUrl: row['source_url'] as String?,
      description: detail['description'] as String?,
      availability: detail['availability'] as String?,
      leaseDurationMonths: (detail['lease_duration_months'] as num?)?.toInt(),
      leaseDurationNegotiable: detail['lease_duration_negotiable'] as bool?,
      availableFrom: detail['available_from']?.toString(),
      rentalDepositMyr: (detail['rental_deposit_myr'] as num?)?.toDouble(),
      titleType: detail['title_type'] as String?,
      landlordFnbPermission: detail['landlord_fnb_permission'] as String?,
      floorDescription: detail['floor_description'] as String?,
      floorLevel: detail['floor_level']?.toString(),
      bathrooms: (detail['bathrooms'] as num?)?.toInt(),
      furnishing: detail['furnishing'] as String?,
      tenure: detail['tenure'] as String?,
      hasParking: detail['has_parking'] as bool?,
      isCornerLot: detail['is_corner_lot'] as bool?,
      isFreehold: detail['is_freehold'] as bool?,
      unitPosition: detail['unit_position'] as String?,
      facingDirection: detail['facing_direction'] as String?,
      frontageFt: (detail['frontage_ft'] as num?)?.toDouble(),
      depthFt: (detail['depth_ft'] as num?)?.toDouble(),
      landAreaSqft: (detail['land_area_sqft'] as num?)?.toDouble(),
      builtUpSqft: (detail['built_up_sqft'] as num?)?.toDouble(),
      availabilityVerifiedAt: detail['availability_verified_at']?.toString(),
      researchAvailabilityStatus: detail['research_availability_status'] as String?,
      listingDataNotice: detail['data_notice'] as String?,
      verifiedListing: detail['verified_listing'] == true,
      tags: [
        'Imported dataset',
        if (row['dataset_validation'] != null)
          'Quality: ${row['dataset_validation']}',
      ],
    );
  }
}
