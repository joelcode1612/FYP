import '../../domain/entities/commercial_property.dart';
import '../../domain/repositories/admin_repositories.dart';
import '../../domain/usecases/verification_usecases.dart';

class VerificationService {
  final VerificationRepository repo;
  const VerificationService(this.repo);

  Future<List<CommercialProperty>> queue() => GetVerificationQueue(repo).call();
  Future<void> approve(String id) => VerifyProperty(repo).call(id);
  Future<void> reject(String id, String reason) =>
      RejectProperty(repo).call(id, reason);
}
