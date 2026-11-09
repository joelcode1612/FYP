import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../application/providers.dart';

/// Restores local drafts before a cold questionnaire/review deep link renders.
class AssessmentDraftLoader extends ConsumerStatefulWidget {
  const AssessmentDraftLoader({
    super.key,
    required this.assessmentId,
    required this.builder,
  });

  final String assessmentId;
  final Widget Function(String id) builder;

  @override
  ConsumerState<AssessmentDraftLoader> createState() =>
      _AssessmentDraftLoaderState();
}

class _AssessmentDraftLoaderState extends ConsumerState<AssessmentDraftLoader> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    try {
      await ref.read(assessmentViewModelProvider).load();
    } catch (_) {
      // The ViewModel exposes a visible, retryable error and preserves storage.
    }
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(assessmentViewModelProvider);
    if (vm.error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Saved questionnaire')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Saved drafts could not be read. Your data has been preserved.',
                ),
                FilledButton(onPressed: _load, child: const Text('Retry')),
              ],
            ),
          ),
        ),
      );
    }
    if (!vm.loaded || vm.loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (vm.getDraft(widget.assessmentId) == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Saved questionnaire')),
        body: const Center(child: Text('Draft not found on this device.')),
      );
    }
    return widget.builder(widget.assessmentId);
  }
}
