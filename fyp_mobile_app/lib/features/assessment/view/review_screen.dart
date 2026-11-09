import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../application/providers.dart';
import '../../../core/routing/app_routes.dart';
import '../../../core/theme/sitewise_theme.dart';
import '../model/entities/assessment_draft.dart';

class ReviewScreen extends ConsumerWidget {
  final String assessmentId;
  const ReviewScreen({super.key, required this.assessmentId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vm = ref.watch(assessmentViewModelProvider);
    final draft = vm.getDraft(assessmentId);
    if (draft == null) {
      return const Scaffold(body: Center(child: Text('Draft missing.')));
    }
    final questions = vm.routeFor(draft);
    final complete =
        questions.isNotEmpty &&
        questions.every((q) => draft.answerCodes.containsKey(q.id));
    final alreadyDone = draft.status == DraftStatus.previewCompleted;
    return Scaffold(
      appBar: AppBar(title: const Text('Review your responses')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(22),
          children: [
            const Icon(
              Icons.fact_check_outlined,
              size: 45,
              color: SitewiseColors.action,
            ),
            const SizedBox(height: 12),
            Text(
              alreadyDone ? 'Preview completed' : 'Ready to review',
              style: const TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            const Text(
              'SYNTHETIC DEMONSTRATION — no survey submission, '
              'real respondent record, or Project1 evidence will be created.',
              style: TextStyle(color: SitewiseColors.warning, fontSize: 12),
            ),
            const SizedBox(height: 18),
            for (final q in questions)
              Card(
                color: SitewiseColors.surface,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${q.id} · ${q.category}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        q.options
                                .where((o) => o.code == draft.answerCodes[q.id])
                                .map((o) => o.label(draft.language))
                                .firstOrNull ??
                            'Not answered',
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 20),
            if (alreadyDone)
              const Center(
                child: Text('This preview cannot be submitted twice.'),
              ),
            if (!alreadyDone)
              FilledButton(
                onPressed: !complete || draft.status != DraftStatus.inProgress
                    ? null
                    : () async {
                        try {
                          await ref
                              .read(assessmentViewModelProvider)
                              .completePreview(assessmentId);
                          if (!context.mounted) return;
                          Navigator.pushNamedAndRemoveUntil(
                            context,
                            AppRoutes.assessmentHome,
                            (route) =>
                                route.isFirst &&
                                route.settings.name != AppRoutes.assessmentHome,
                          );
                        } catch (e) {
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(
                            context,
                          ).showSnackBar(SnackBar(content: Text('$e')));
                        }
                      },
                child: const Text('Finish UI Preview'),
              ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Back'),
            ),
          ],
        ),
      ),
    );
  }
}
