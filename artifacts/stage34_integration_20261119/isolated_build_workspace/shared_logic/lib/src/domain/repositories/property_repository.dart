import '../entities/commercial_property.dart';

/// Domain repository contract. Implemented in data/.
abstract class PropertyRepository {
  Future<List<CommercialProperty>> getProperties();
  Future<CommercialProperty?> getPropertyById(String id);
  Future<List<CommercialProperty>> getPropertiesByOwner(String ownerId);
  Future<CommercialProperty> createProperty(CommercialProperty property);
  Future<void> updateProperty(CommercialProperty property);
  Future<void> submitForVerification(String id);
  Future<void> updateVerification(String id, VerificationStatus status);
}
