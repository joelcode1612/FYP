import '../../core/errors/app_failure.dart';
import '../entities/commercial_property.dart';
import '../repositories/property_repository.dart';
import '../repositories/saved_properties_repository.dart';

/// One saved property the entrepreneur may choose for an assessment.
///
/// [propertyRef] is the CATALOGUE text id (`EP-xxxxx`) — the same identifier
/// the assessment record is bound to. It is never swapped for a numeric
/// `fyp.rental_properties` id, a `public.property` id or an assessment UUID.
///
/// [property] is null when the catalogue read could not produce the listing
/// (delisted, or the catalogue endpoint failed). [unavailableReason] then
/// carries the reason, so the UI can say what is wrong instead of showing an
/// empty card.
class SelectableProperty {
  final String propertyRef;
  final CommercialProperty? property;
  final String? unavailableReason;

  const SelectableProperty({
    required this.propertyRef,
    this.property,
    this.unavailableReason,
  });

  /// True when this record can start (or resume) an assessment.
  bool get isSelectable => property != null;
}

/// The account's saved properties, prepared for the assessment Stage 1
/// selector.
///
/// Strongly typed and free of transport detail: the page renders states from
/// these fields and never inspects an HTTP status itself.
class AssessmentSelectableProperties {
  /// The saved records. Entries whose details could not be resolved are kept
  /// with a null [SelectableProperty.property] so the UI can show them as
  /// unavailable instead of hiding them.
  final List<SelectableProperty> properties;

  /// Saved refs the catalogue no longer contains. They are never selectable,
  /// but they are reported so the page can explain the gap honestly.
  final List<String> unresolvedRefs;

  /// The failure message when the saved list itself could not be read.
  final String? errorMessage;

  /// True when the saved list was refused because the session is not a signed
  /// in entrepreneur. The page shows the sign-in state, not an empty list.
  final bool isUnauthorized;

  const AssessmentSelectableProperties({
    this.properties = const [],
    this.unresolvedRefs = const [],
    this.errorMessage,
    this.isUnauthorized = false,
  });

  /// True when the read failed and there is nothing to show.
  bool get hasError => errorMessage != null;

  /// True when the account holds no saved property at all.
  bool get isEmpty => properties.isEmpty && unresolvedRefs.isEmpty && !hasError;

  /// The records that can be selected (their details resolved).
  List<SelectableProperty> get selectable =>
      properties.where((item) => item.isSelectable).toList(growable: false);

  /// Filters [properties] by a free-text query over the title, address,
  /// township/city, property id and type. An empty query returns everything.
  List<SelectableProperty> search(String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return List.unmodifiable(properties);
    return List.unmodifiable(
      properties.where((item) {
        final property = item.property;
        final haystack = [
          item.propertyRef,
          if (property != null) ...[
            property.title,
            property.address,
            property.city,
            property.state,
            property.propertyType,
          ],
        ].join(' ').toLowerCase();
        return haystack.contains(needle);
      }),
    );
  }
}

/// Reads the signed-in account's Saved Properties and resolves each one
/// against the catalogue, for the assessment Stage 1 selector.
///
/// The saved list is the account's own (`public.favourite_property` through the
/// authenticated `/api/v1/saved-properties/me`), so another account's items
/// can never appear. Unresolved catalogue refs are excluded from the
/// selectable records but preserved for an explanatory warning.
///
/// Each ref is resolved exactly once per call — a repeated ref never causes a
/// second catalogue request.
class GetAssessmentSelectableProperties {
  final SavedPropertiesRepository savedProperties;
  final PropertyRepository properties;

  const GetAssessmentSelectableProperties(
    this.savedProperties,
    this.properties,
  );

  Future<AssessmentSelectableProperties> call() async {
    final Set<String> resolved;
    final Set<String> unresolved;
    try {
      final saved = await savedProperties.savedWithUnresolved();
      resolved = saved.resolved;
      unresolved = saved.unresolved;
    } on UnauthorizedFailure catch (failure) {
      return AssessmentSelectableProperties(
        errorMessage: failure.message,
        isUnauthorized: true,
      );
    } on AppFailure catch (failure) {
      return AssessmentSelectableProperties(errorMessage: failure.message);
    } on Object {
      return const AssessmentSelectableProperties(
        errorMessage: 'The saved properties service could not be reached.',
      );
    }

    final records = <SelectableProperty>[];
    // One catalogue read per distinct ref, even if the server repeats a ref.
    // The reads run in small bounded batches instead of strictly one-by-one:
    // they are independent idempotent GETs, so resolving them concurrently
    // removes the avoidable latency of N sequential round trips while the
    // per-ref error isolation (a failed read becomes an unavailable record,
    // never a thrown error) and the output order are preserved.
    const batchSize = 6;
    final cache = <String, SelectableProperty>{};
    for (var start = 0; start < resolved.length; start += batchSize) {
      final batch = resolved.skip(start).take(batchSize).toList(growable: false);
      final resolvedBatch = await Future.wait(
        batch.map((ref) async {
          final cached = cache[ref];
          if (cached != null) return cached;
          CommercialProperty? property;
          String? unavailableReason;
          try {
            property = await properties.getPropertyById(ref);
          } on AppFailure catch (failure) {
            unavailableReason = failure.message;
          } on Object {
            unavailableReason =
                'The listing details could not be loaded from the catalogue.';
          }
          if (property == null && unavailableReason == null) {
            unavailableReason =
                'This listing is no longer available in the property catalogue.';
          }
          return SelectableProperty(
            propertyRef: ref,
            property: property,
            unavailableReason: unavailableReason,
          );
        }),
      );
      for (final record in resolvedBatch) {
        cache[record.propertyRef] = record;
        records.add(record);
      }
    }

    final unresolvedList = unresolved.toList()..sort();
    return AssessmentSelectableProperties(
      properties: List.unmodifiable(records),
      unresolvedRefs: List.unmodifiable(unresolvedList),
    );
  }
}
