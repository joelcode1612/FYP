
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart'
    show StateNotifier, StateNotifierProvider;
import 'package:shared_logic/shared_logic.dart';

import 'services/service_locator.dart';

/// Riverpod wiring for the Layer 2/3 personalised pipeline.
///
/// The repository is injected through [ServiceLocator.apiClient].
/// Without an enabled live API, the page reports the feature as
/// unavailable rather than generating simulated recommendations.
final personalisedRecommendationRepositoryProvider =
    Provider<ApiPersonalisedRecommendationRepository>((ref) {
  return ApiPersonalisedRecommendationRepository(
    ServiceLocator.apiClient,
  );
});

/// Lifecycle of one personalised-batch screen.
enum PersonalisedBatchStatus {
  idle,
  loading,
  ready,
  error,
  unavailable,
}

/// Immutable state for personalised recommendation batches.
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

/// Controls loading and generation of personalised batches.
///
/// Uses the existing repository contract.
/// Does not generate synthetic data when the live API is unavailable.
class PersonalisedBatchNotifier
    extends StateNotifier<PersonalisedBatchState> {
  final ApiPersonalisedRecommendationRepository _repository;
  final bool _liveApi;

  /// Public constructor.
  ///
  /// Preserves the existing named parameter `liveApi`.
  factory PersonalisedBatchNotifier(
    ApiPersonalisedRecommendationRepository repository, {
    required bool liveApi,
  }) {
    return PersonalisedBatchNotifier._(
      repository,
      liveApi,
    );
  }

  /// Private constructor using initializing formals.
  ///
  /// Resolves the prefer_initializing_formals lint.
  PersonalisedBatchNotifier._(
    this._repository,
    this._liveApi,
  ) : super(const PersonalisedBatchState());

  /// Load the most recently generated recommendation batch.
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

      // Avoid updating state after the notifier is disposed.
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
  /// The backend may reuse the stored batch when scoring inputs
  /// have not changed.
  ///
  /// The backend reports reuse through `reused_existing_batch`.
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
      final response = await _repository.generate(
        limit: limit,
      );

      if (!mounted) return;

      final results =
          (response['results'] as List?) ?? const [];

      state = PersonalisedBatchState(
        status: PersonalisedBatchStatus.ready,
        batch: GeneratedBatch.fromJson({
          'batch_id': response['batch_id'] ?? '',
          'generated_at': response['generated_at'],
          'result_count': results.length,
          'results': results,
        }),
        reusedExistingBatch:
            response['reused_existing_batch'] == true,
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

/// Riverpod provider for the personalised batch lifecycle.
final personalisedBatchProvider =
    StateNotifierProvider<
        PersonalisedBatchNotifier,
        PersonalisedBatchState>((ref) {
  return PersonalisedBatchNotifier(
    ref.read(
      personalisedRecommendationRepositoryProvider,
    ),
    liveApi: true,
  );
});

/// One explanation request per result ID.
///
/// Cached for the provider's active lifecycle.
final explanationProvider = FutureProvider.autoDispose
    .family<PersonalisedExplanation, String>(
  (ref, resultId) async {
    final repository = ref.read(
      personalisedRecommendationRepositoryProvider,
    );

    return repository.explanation(resultId);
  },
);
