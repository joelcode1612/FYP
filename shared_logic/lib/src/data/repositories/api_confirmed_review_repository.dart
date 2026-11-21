import '../../core/network/api_client.dart';
import '../../domain/entities/confirmed_business_review.dart';

final class ApiConfirmedReviewRepository {
  final ApiClient client;
  const ApiConfirmedReviewRepository(this.client);

  Future<ConfirmedBusinessReview> read({
    required String assessmentId,
    required String confirmationId,
    required int revision,
  }) async {
    final uuid = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    );
    if (!uuid.hasMatch(assessmentId) ||
        !uuid.hasMatch(confirmationId) ||
        revision < 0) {
      throw ArgumentError(
        'An explicit M2 assessment, confirmation and revision are required.',
      );
    }
    final data = ConfirmedBusinessReview.fromJson(
      await client.get(
        '/api/v1/m2/assessments/$assessmentId/confirmed-review',
        query: {
          'confirmation_id': confirmationId,
          'expected_revision': '$revision',
        },
      ),
    );
    if (data.assessmentId != assessmentId ||
        data.confirmationId != confirmationId ||
        data.revision != revision) {
      throw const FormatException('Confirmed review binding mismatch.');
    }
    return data;
  }
}
