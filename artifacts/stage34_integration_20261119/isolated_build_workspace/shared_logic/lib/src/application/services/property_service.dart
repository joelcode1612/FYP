import 'package:shared_logic/shared_logic.dart';

/// Orchestrates property use cases. Widgets talk to this, never to repos.

class PropertyService {
  final PropertyRepository repo;
  const PropertyService(this.repo);

  Future<List<CommercialProperty>> listings() => GetProperties(repo).call();
  Future<CommercialProperty?> detail(String id) =>
      GetPropertyById(repo).call(id);
  Future<List<CommercialProperty>> ownerListings(String ownerId) =>
      GetOwnerProperties(repo).call(ownerId);
  Future<CommercialProperty> create(CommercialProperty property) =>
      CreateProperty(repo).call(property);
  Future<void> update(CommercialProperty property) =>
      UpdateProperty(repo).call(property);
  Future<void> submit(String id) =>
      SubmitPropertyForVerification(repo).call(id);
}
