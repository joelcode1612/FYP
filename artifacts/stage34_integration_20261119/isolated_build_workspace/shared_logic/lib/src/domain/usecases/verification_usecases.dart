import '../entities/commercial_property.dart';
import '../repositories/admin_repositories.dart';

class GetVerificationQueue {
  final VerificationRepository repo;
  const GetVerificationQueue(this.repo);
  Future<List<CommercialProperty>> call() => repo.getPendingQueue();
}

class VerifyProperty {
  final VerificationRepository repo;
  const VerifyProperty(this.repo);
  Future<void> call(String id) => repo.verify(id);
}

class RejectProperty {
  final VerificationRepository repo;
  const RejectProperty(this.repo);
  Future<void> call(String id, String reason) => repo.reject(id, reason);
}
