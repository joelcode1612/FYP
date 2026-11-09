import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../application/providers.dart';
import '../../../core/routing/app_routes.dart';
import '../../../core/theme/sitewise_theme.dart';
import '../model/entities/assessment.dart';
import '../model/entities/assessment_draft.dart';
import 'components/assessment_card.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});
  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _load();
    });
  }

  Future<void> _load() async {
    try {
      await ref.read(assessmentViewModelProvider).load();
    } catch (_) {
      // Render the ViewModel error below without resetting the saved drafts.
    }
  }

  Future<void> _open(AssessmentOffer offer) async {
    final vm = ref.read(assessmentViewModelProvider);
    try {
      final draft = await vm.startOrResume(offer);
      if (!mounted) return;
      await Navigator.of(context).pushNamed<void>(
        draft.status == DraftStatus.previewCompleted
            ? AppRoutes.assessmentReview
            : AppRoutes.assessmentQuestionnaire,
        arguments: draft.id,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(assessmentViewModelProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Project1', style: TextStyle(fontWeight: FontWeight.bold)),
            Text(
              'Customer assessments',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.normal),
            ),
          ],
        ),
      ),
      body: vm.loading || !vm.loaded && vm.error == null
          ? const Center(child: CircularProgressIndicator())
          : vm.error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Saved drafts could not be loaded. Your data has been preserved.',
                      textAlign: TextAlign.center,
                    ),
                    FilledButton(onPressed: _load, child: const Text('Retry')),
                  ],
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const Text(
                  'Your questionnaires',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 25,
                    color: SitewiseColors.ink,
                  ),
                ),
                const SizedBox(height: 5),
                const Text(
                  'Start a questionnaire or continue where you stopped.',
                  style: TextStyle(color: SitewiseColors.muted),
                ),
                const SizedBox(height: 10),
                const Text(
                  'DEVELOPMENT PREVIEW · No customer survey is being fielded',
                  style: TextStyle(fontSize: 11, color: SitewiseColors.warning),
                ),
                const SizedBox(height: 22),
                for (final offer in demoAssessmentOffers)
                  AssessmentCard(
                    offer: offer,
                    draft: vm.getDraft(offer.id),
                    questionCount: vm
                        .routeFor(
                          vm.getDraft(offer.id) ?? AssessmentDraft.start(offer),
                        )
                        .length,
                    recorded: vm.getDraft(offer.id) == null
                        ? 0
                        : vm.recordedCount(vm.getDraft(offer.id)!),
                    progress: vm.getDraft(offer.id) == null
                        ? 0
                        : vm.progress(vm.getDraft(offer.id)!),
                    onPressed: () => _open(offer),
                  ),
              ],
            ),
    );
  }
}
