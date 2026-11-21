
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart'
    show StateNotifier, StateNotifierProvider;
import 'package:shared_logic/shared_logic.dart';

import 'package:fyp/core/di/service_locator.dart';

/// Repository for the SiteWise personalised recommendation pipeline.
///
/// Uses the existing API client configured in ServiceLocator.
final personalisedRecommendationRepositoryProvider =
    Provider<ApiPersonalisedRecommendationRepository>((ref) {
      return ApiPersonalisedRecommendationRepository(ServiceLocator.apiClient);
    });

/// Lifecycle states for a personalised recommendation batch.
enum PersonalisedBatchStatus { idle, loading, ready, error, unavailable }

/// State of the personalised recommendation screen.
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

  bool get loading =>
      status == PersonalisedBatchStatus.loading;

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
      reusedExistingBatch:
          reusedExistingBatch ?? this.reusedExistingBatch,
      error: error,
    );
  }
}

/// Manages loading and generating personalised recommendation batches.
class PersonalisedBatchNotifier extends StateNotifier<PersonalisedBatchState> {
  final ApiPersonalisedRecommendationRepository _repository;

  /// Indicates whether the live API is configured for this notifier.
  final bool liveApi;

  PersonalisedBatchNotifier(this._repository, {required this.liveApi})
    : super(const PersonalisedBatchState());

  /// Load the latest stored recommendation batch.
  Future<void> loadExisting() async {
    if (state.loading) return;

    if (!liveApi) {
      state = const PersonalisedBatchState(
        status: PersonalisedBatchStatus.unavailable,
        error:
            'Personalised recommendations require the live API. '
            'This build has no live API configured.',
      );
      return;
    }

    state = state.copyWith(
      status: PersonalisedBatchStatus.loading,
      error: null,
      clearBatch: true,
      reusedExistingBatch: false,
    );

    try {
      final batch = await _repository.latest();

      if (!mounted) return;

      state = PersonalisedBatchState(
        status: batch == null
            ? PersonalisedBatchStatus.idle
            : PersonalisedBatchStatus.ready,
        batch: batch,
      );
    } catch (err) {
      if (!mounted) return;

      state = state.copyWith(
        status: PersonalisedBatchStatus.error,
        error: err.toString(),
      );
    }
  }

  /// Generate a personalised recommendation batch.
  ///
  /// The backend may reuse an existing batch when the scoring
  /// inputs have not changed.
  Future<void> generate({int limit = 20}) async {
    if (state.loading) return;

    if (!liveApi) {
      state = const PersonalisedBatchState(
        status: PersonalisedBatchStatus.unavailable,
        error:
            'Personalised recommendations require the live API. '
            'This build has no live API configured.',
      );
      return;
    }

    state = state.copyWith(
      status: PersonalisedBatchStatus.loading,
      error: null,
      clearBatch: true,
      reusedExistingBatch: false,
    );

    try {
      final response = await _repository.generate(limit: limit);

      if (!mounted) return;

      final results = (response['results'] as List?) ?? const [];

      final batch = GeneratedBatch.fromJson({
        'batch_id': response['batch_id'] ?? '',
        'generated_at': response['generated_at'],
        'result_count': results.length,
        'results': results,
      });

      state = PersonalisedBatchState(
        status: PersonalisedBatchStatus.ready,
        batch: batch,
        reusedExistingBatch: response['reused_existing_batch'] == true,
      );
    } catch (err) {
      if (!mounted) return;

      state = state.copyWith(
        status: PersonalisedBatchStatus.error,
        error: err.toString(),
      );
    }
  }
}

/// Riverpod provider for personalised recommendation state.
final personalisedBatchProvider =
    StateNotifierProvider<PersonalisedBatchNotifier, PersonalisedBatchState>((
      ref,
    ) {
      return PersonalisedBatchNotifier(
        ref.read(personalisedRecommendationRepositoryProvider),
        liveApi: true,
      );
    });

/// Fetch one recommendation explanation per result ID.
///
/// The result is cached while the provider remains alive.
final explanationProvider = FutureProvider.autoDispose
    .family<PersonalisedExplanation, String>((ref, resultId) async {
      final repository = ref.read(personalisedRecommendationRepositoryProvider);

      return repository.explanation(resultId);
    });
