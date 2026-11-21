/// Wire → entity mapping for owner-listing endpoints.
///
/// Centralises the backend's `data` envelope and the list-row shape so the
/// repository never decodes a response itself. Field names are unchanged.
library;

import '../../domain/entities/owner_listing.dart';

abstract final class OwnerListingMapper {
  static Map<String, dynamic> unwrap(Map<String, dynamic> response) =>
      response['data'] is Map<String, dynamic>
          ? response['data'] as Map<String, dynamic>
          : response;

  static OwnerListing listing(Map<String, dynamic> response) =>
      OwnerListing.fromJson(unwrap(response));

  static List<OwnerListing> list(Map<String, dynamic> response) {
    final rows = response['data'];
    if (rows is! List) return const <OwnerListing>[];
    return rows
        .whereType<Map<String, dynamic>>()
        .map(OwnerListing.fromJson)
        .toList(growable: false);
  }

  static OwnerListingPhoto photo(Map<String, dynamic> response) =>
      OwnerListingPhoto.fromJson(unwrap(response));

  static List<OwnerListingPhoto> photos(Map<String, dynamic> response) {
    final rows = response['data'];
    if (rows is! List) return const <OwnerListingPhoto>[];
    return rows
        .whereType<Map<String, dynamic>>()
        .map(OwnerListingPhoto.fromJson)
        .toList(growable: false);
  }
}
