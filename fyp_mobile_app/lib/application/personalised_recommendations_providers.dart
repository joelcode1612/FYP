import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateNotifier, StateNotifierProvider;
import 'package:shared_logic/shared_logic.dart';

import 'services/service_locator.dart';

/// Riverpod wiring for the Layer 2/3 personalised pipeline (new file, so the
/// concurrently-maintained providers.dart stays untouched).
///
/// The repository is injected through [ServiceLocator.apiClient] exactly like
/// the other live repositories; without the live-API override the page
/// reports the feature as unavailable instead of faking data.

final personalisedRecommendationRepositoryProvider =
    Provider<ApiPersonalisedRecommendationRepository>((ref) {
  return ApiPersonalisedRecommendationRepository(ServiceLocator.apiClient);
});

/// Lifecycle of one personalised-batch screen.
enum PersonalisedBatchStatus { idle, loading, ready, error, unavailable }

class PersonalisedBatchState {
  final PersonalisedBatchStatus status;
  final GeneratedBatch? batch;
  final bool reusedExistingBatch;
  final String? error;

  const PersonalisedBatchState({
    this.status = PersonalisedBatchStatus.idle,
    this.batch,
    this.reusedExistingBatch = false,
    this.error,
  });

  bool get loading => status == PersonalisedBatchStatus.loading;

  PersonalisedBatchState copyWith({
    PersonalisedBatchStatus? status,
    GeneratedBatch? batch,
    bool? reusedExistingBatch,
    String? error,
    bool clearBatch = false,
  }) {
    return PersonalisedBatchState(
      status: status ?? this.status,
      batch: clearBatch ? null : (batch ?? this.batch),
      reusedExistingBatch: reusedExistingBatch ?? this.reusedExistingBatch,
      error: error,
    );
  }
}

class PersonalisedBatchNotifier
    extends StateNotifier<PersonalisedBatchState> {
  final ApiPersonalisedRecommendationRepository _repository;
  final bool _liveApi;

  PersonalisedBatchNotifier(this._repository, {required bool liveApi})
      : _liveApi = liveApi,
        super(const PersonalisedBatchState());

  Future<void> loadExisting() async {
    if (!_liveApi) {
      state = const PersonalisedBatchState(
        status: PersonalisedBatchStatus.unavailable,
        error:
            'Personalised recommendations need the live API connection. '
            'This build has none configured.',
      );
      return;
    }
    state = state.copyWith(
      status: PersonalisedBatchStatus.loading,
      error: null,
      clearBatch: true,
    );
    try {
      final batch = await _repository.latest();
      state = PersonalisedBatchState(
        status:
            batch == null ? PersonalisedBatchStatus.idle : PersonalisedBatchStatus.ready,
        batch: batch,
      );
    } catch (err) {
      state = state.copyWith(
        status: PersonalisedBatchStatus.error,
        error: err.toString(),
      );
    }
  }

  /// Regenerates. The backend itself reuses the stored batch (and reports
  /// `reused_existing_batch`) when no scoring input changed.
  Future<void> generate({int limit = 20}) async {
    if (!_liveApi) {
      state = const PersonalisedBatchState(
        status: PersonalisedBatchStatus.unavailable,
        error:
            'Personalised recommendations need the live API connection. '
            'This build has none configured.',
      );
      return;
    }
    state = state.copyWith(
      status: PersonalisedBatchStatus.loading,
      error: null,
      clearBatch: true,
    );
    try {
      final response = await _repository.generate(limit: limit);
      final results = (response['results'] as List?) ?? const [];
      state = PersonalisedBatchState(
        status: results.isEmpty
            ? PersonalisedBatchStatus.ready
            : PersonalisedBatchStatus.ready,
        batch: GeneratedBatch.fromJson({
          'batch_id': response['batch_id'] ?? '',
          'generated_at': response['generated_at'],
          'result_count': results.length,
          'results': results,
        }),
        reusedExistingBatch: response['reused_existing_batch'] == true,
      );
    } catch (err) {
      state = state.copyWith(
        status: PersonalisedBatchStatus.error,
        error: err.toString(),
      );
    }
  }
}

final personalisedBatchProvider =
    StateNotifierProvider<PersonalisedBatchNotifier, PersonalisedBatchState>((
  ref,
) {
  return PersonalisedBatchNotifier(
    ref.read(personalisedRecommendationRepositoryProvider),
    liveApi: true,
  );
});

/// One explanation request per result id, cached for the screen's lifetime.
final explanationProvider = FutureProvider.autoDispose
    .family<PersonalisedExplanation, String>((ref, resultId) async {
  final repository = ref.read(personalisedRecommendationRepositoryProvider);
  return repository.explanation(resultId);
});
