import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fyp/core/di/service_locator.dart';
import 'package:fyp/features/listing/domain/property_evidence.dart';
import 'package:fyp/features/listing/data/api_property_evidence_repository.dart';

/// Composition root is the only place that constructs the data adapter.
final propertyEvidenceReaderProvider = Provider<PropertyEvidenceReader>((ref) {
  return ApiPropertyEvidenceReader(ServiceLocator.apiClient);
});

final propertyEvidenceProvider =
    FutureProvider.family<PropertyEvidenceSnapshot, String>((ref, id) {
  return ref.watch(propertyEvidenceReaderProvider).load(id);
});
