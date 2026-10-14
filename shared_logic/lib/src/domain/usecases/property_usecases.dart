import '../entities/commercial_property.dart';
import '../repositories/property_repository.dart';

class GetProperties {
  final PropertyRepository repo;
  const GetProperties(this.repo);
  Future<List<CommercialProperty>> call() => repo.getProperties();
}

class GetPropertyById {
  final PropertyRepository repo;
  const GetPropertyById(this.repo);
  Future<CommercialProperty?> call(String id) => repo.getPropertyById(id);
}

class GetOwnerProperties {
  final PropertyRepository repo;
  const GetOwnerProperties(this.repo);
  Future<List<CommercialProperty>> call(String ownerId) =>
      repo.getPropertiesByOwner(ownerId);
}

class SubmitPropertyForVerification {
  final PropertyRepository repo;
  const SubmitPropertyForVerification(this.repo);
  Future<void> call(String id) => repo.submitForVerification(id);
}

class CreateProperty {
  final PropertyRepository repo;
  const CreateProperty(this.repo);
  Future<CommercialProperty> call(CommercialProperty property) =>
      repo.createProperty(property);
}

class UpdateProperty {
  final PropertyRepository repo;
  const UpdateProperty(this.repo);
  Future<void> call(CommercialProperty property) =>
      repo.updateProperty(property);
}
