import '../../domain/entities/commercial_property.dart';
import '../../domain/repositories/property_repository.dart';
import '../datasources/local/demo_data.dart';

/// Demo implementation. Swap with a Supabase/API-backed one later without
/// touching domain or presentation.
class PropertyRepositoryImpl implements PropertyRepository {
  final List<CommercialProperty> _store = List.of(DemoData.properties);

  @override
  Future<List<CommercialProperty>> getProperties() async =>
      List.unmodifiable(_store);

  @override
  Future<CommercialProperty?> getPropertyById(String id) async {
    for (final p in _store) {
      if (p.id == id) return p;
    }
    return null;
  }

  @override
  Future<List<CommercialProperty>> getPropertiesByOwner(String ownerId) async =>
      _store.where((p) => p.ownerId == ownerId).toList();

  @override
  Future<CommercialProperty> createProperty(CommercialProperty property) async {
    _store.add(property);
    return property;
  }

  @override
  Future<void> updateProperty(CommercialProperty property) async {
    final i = _store.indexWhere((p) => p.id == property.id);
    if (i != -1) _store[i] = property;
  }

  @override
  Future<void> submitForVerification(String id) async =>
      updateVerification(id, VerificationStatus.pending);

  @override
  Future<void> updateVerification(String id, VerificationStatus status) async {
    final i = _store.indexWhere((p) => p.id == id);
    if (i != -1) _store[i] = _store[i].copyWith(verification: status);
  }
}
