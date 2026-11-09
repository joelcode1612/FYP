import '../../domain/entities/commercial_property.dart';
import '../dtos/property_dto.dart';
import '../models/commercial_property_model.dart';

/// DTO/model ↔ entity conversions. All mapping lives here — never in pages.
abstract final class PropertyMapper {
  /// Builds a DRAFT entity from an outbound [PropertyDto].
  ///
  /// Draft semantics, deliberately strict:
  ///  * the id must come from [dto] or [id]. A locally generated placeholder
  ///    id is NEVER fabricated — a draft without a server (or caller) id is a
  ///    programming error and throws, because a made-up id would silently
  ///    fork the record once the backend assigns the real one;
  ///  * the suitability score stays 0 with [CommercialProperty
  ///    .hasSuitabilityScore] false — no score exists before assessment, and
  ///    the old hardcoded 50 was a fabricated value.
  static CommercialProperty fromDto(PropertyDto dto, {required String id}) =>
      CommercialProperty(
        id: dto.id ?? id,
        title: dto.title,
        address: dto.address,
        city: dto.city,
        state: dto.state,
        postcode: dto.postcode,
        rentalRm: dto.rentalRm,
        rentalMaxRm: dto.rentalMaxRm,
        sizeSqft: dto.sizeSqft,
        latitude: dto.latitude,
        longitude: dto.longitude,
        propertyType: dto.propertyType,
        verification: VerificationStatus.draft,
        suitabilityScore: 0,
        hasSuitabilityScore: false,
        ownerId: dto.ownerId,
        hasTour: false,
      );

  static CommercialPropertyModel toModel(CommercialProperty e) =>
      CommercialPropertyModel(
        id: e.id,
        title: e.title,
        address: e.address,
        city: e.city,
        state: e.state,
        postcode: e.postcode,
        rentalRm: e.rentalRm,
        rentalMaxRm: e.rentalMaxRm,
        sizeSqft: e.sizeSqft,
        latitude: e.latitude,
        longitude: e.longitude,
        propertyType: e.propertyType,
        verification: e.verification.name,
        suitabilityScore: e.suitabilityScore,
        ownerId: e.ownerId,
        hasTour: e.hasTour,
        requirements: e.requirements,
        tags: e.tags,
      );
}
