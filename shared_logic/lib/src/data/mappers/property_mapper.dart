import '../../domain/entities/commercial_property.dart';
import '../dtos/property_dto.dart';
import '../models/commercial_property_model.dart';

/// DTO/model ↔ entity conversions. All mapping lives here — never in pages.
abstract final class PropertyMapper {
  static CommercialProperty fromDto(PropertyDto dto, {String? id}) =>
      CommercialProperty(
        id: id ?? dto.id ?? 'p-${DateTime.now().millisecondsSinceEpoch}',
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
        suitabilityScore: 50,
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
