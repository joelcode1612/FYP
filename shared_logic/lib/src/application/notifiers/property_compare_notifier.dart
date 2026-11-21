import 'package:riverpod/riverpod.dart';

import '../../core/errors/app_failure.dart';
import '../../domain/entities/property_compare.dart';
import 'providers.dart';

/// View state for the shared Compare screen on web and mobile.
class PropertyCompareState {
  final PropertyCompareResult? data;
  final List<String> ids;
  final bool loading;
  final bool refreshing;
  final String? error;

  const PropertyCompareState({
    this.data,
    this.ids = const [],
    this.loading = false,
    this.refreshing = false,
    this.error,
  });

  PropertyCompareState copyWith({
    PropertyCompareResult? data,
    List<String>? ids,
    bool? loading,
    bool? refreshing,
    String? error,
    bool clearData = false,
    bool clearError = false,
  }) => PropertyCompareState(
    data: clearData ? null : (data ?? this.data),
    ids: ids ?? this.ids,
    loading: loading ?? this.loading,
    refreshing: refreshing ?? this.refreshing,
    error: clearError ? null : (error ?? this.error),
  );
}

/// Owns the single comparison request. A stale response can never overwrite a
/// newer selection, and a failed read is an error — never an empty comparison.
class PropertyCompareNotifier extends Notifier<PropertyCompareState> {
  int _seq = 0;

  @override
  PropertyCompareState build() => const PropertyCompareState();

  Future<void> load(List<String> propertyIds, {bool refresh = false}) async {
    final ids = List<String>.from(propertyIds);
    if (ids.length < 2) {
      _seq++;
      state = PropertyCompareState(ids: ids);
      return;
    }
    final repo = ref.read(propertyCompareRepositoryProvider);
    if (repo == null) {
      _seq++;
      state = PropertyCompareState(
        ids: ids,
        error: 'Comparison is not available in this build.',
      );
      return;
    }
    final seq = ++_seq;
    state = state.copyWith(
      ids: ids,
      loading: true,
      refreshing: refresh,
      error: null,
      clearData: !refresh,
    );
    try {
      final result = await repo.compare(ids);
      if (!ref.mounted || seq != _seq) return;
      state = PropertyCompareState(data: result, ids: ids);
    } on Object catch (error) {
      if (!ref.mounted || seq != _seq) return;
      state = PropertyCompareState(
        ids: ids,
        error: readableFailure(
          error,
          fallback: 'The comparison could not be loaded. Please try again.',
        ),
      );
    }
  }

  void reset() {
    _seq++;
    state = const PropertyCompareState();
  }
}

final propertyCompareProvider =
    NotifierProvider<PropertyCompareNotifier, PropertyCompareState>(
  PropertyCompareNotifier.new,
);
