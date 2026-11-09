import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../application/providers.dart';
import '../../../core/routing/app_routes.dart';
import '../../../core/theme/sitewise_theme.dart';
import '../model/entities/assessment_draft.dart';
import 'components/question_option_tile.dart';

class QuestionnaireScreen extends ConsumerWidget {
  final String assessmentId;
  const QuestionnaireScreen({super.key, required this.assessmentId});

  Future<void> _call(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vm = ref.watch(assessmentViewModelProvider);
    final draft = vm.getDraft(assessmentId);
    if (draft == null) {
      return const Scaffold(body: Center(child: Text('Draft not found.')));
    }

    if (draft.status == DraftStatus.paused) {
      return Scaffold(
        appBar: AppBar(title: const Text('Paused')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.pause_circle_outline,
                  size: 55,
                  color: SitewiseColors.action,
                ),
                const SizedBox(height: 12),
                const Text('Your answers have been saved.'),
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: () =>
                      _call(context, () => vm.resume(assessmentId)),
                  child: const Text('Resume Assessment'),
                ),
                TextButton(
                  onPressed: () => Navigator.pushNamedAndRemoveUntil(
                    context,
                    AppRoutes.assessmentHome,
                    (r) =>
                        r.isFirst &&
                        r.settings.name != AppRoutes.assessmentHome,
                  ),
                  child: const Text('Back to assessments'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (draft.status == DraftStatus.previewCompleted) {
      return Scaffold(
        appBar: AppBar(title: const Text('Preview complete')),
        body: Center(
          child: FilledButton(
            onPressed: () => Navigator.pushReplacementNamed(
              context,
              AppRoutes.assessmentReview,
              arguments: assessmentId,
            ),
            child: const Text('View Summary'),
          ),
        ),
      );
    }

    if (!draft.consentGiven) {
      return Scaffold(
        appBar: AppBar(title: const Text('Before you begin')),
        body: SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.coffee,
                    size: 40,
                    color: SitewiseColors.action,
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Customer questionnaire preview',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 26),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'This is a local UI demonstration. Your test selections are '
                    'stored on this device. They are not sent to a server or used '
                    'as real customer research.',
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'The real questionnaire requires separately approved consent, '
                    'eligibility, instrument and collection policies.',
                    style: TextStyle(fontSize: 12, color: SitewiseColors.muted),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: () =>
                        _call(context, () => vm.setConsent(assessmentId, true)),
                    child: const Text('Continue with demo consent'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final route = vm.routeFor(draft);
    final question = vm.currentQuestion(draft);
    if (question == null) {
      return const Scaffold(body: Center(child: Text('Route unavailable.')));
    }
    final index = route.indexWhere((q) => q.id == question.id);
    final selected = draft.answerCodes[question.id];
    final canNext = selected != null;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => _call(context, () async {
            await vm.pause(assessmentId);
            if (context.mounted) {
              Navigator.pushNamedAndRemoveUntil(
                context,
                AppRoutes.assessmentHome,
                (r) => r.isFirst && r.settings.name != AppRoutes.assessmentHome,
              );
            }
          }),
        ),
        title: const Text(
          'Questionnaire',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          TextButton(
            onPressed: () =>
                _call(context, () => vm.setLanguage(assessmentId, 'en')),
            child: Text(
              'EN',
              style: TextStyle(
                fontWeight: draft.language == 'en'
                    ? FontWeight.bold
                    : FontWeight.normal,
              ),
            ),
          ),
          TextButton(
            onPressed: () =>
                _call(context, () => vm.setLanguage(assessmentId, 'bm')),
            child: Text(
              'BM',
              style: TextStyle(
                fontWeight: draft.language == 'bm'
                    ? FontWeight.bold
                    : FontWeight.normal,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Expanded(
                      child: Text(
                        'Your route',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text('Step ${index + 1} of ${route.length}'),
                  ],
                ),
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: vm.progress(draft),
                  minHeight: 8,
                  borderRadius: BorderRadius.circular(8),
                ),
                const SizedBox(height: 10),
                Text(
                  '${vm.recordedCount(draft)} recorded · 13 in bank · ${route.length} in UI demo',
                  style: const TextStyle(
                    color: SitewiseColors.muted,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 32),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: SitewiseColors.infoWash,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Text(
                      '${question.id}   ${question.category}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  question.prompt(draft.language),
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 23,
                    color: SitewiseColors.ink,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  question.helper(draft.language),
                  style: const TextStyle(
                    color: SitewiseColors.muted,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 12),
                if (question.id == 'Q05')
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: SitewiseColors.infoWash,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text(
                      'FICTIONAL CAFÉ CONCEPT · UI TEST ONLY\n'
                      'Coffee, drinks and pastries in a simulated area. Not an approved concept card.',
                      style: TextStyle(
                        fontSize: 12,
                        color: SitewiseColors.action,
                      ),
                    ),
                  ),
                const SizedBox(height: 15),
                Column(
                  children: [
                    for (final option in question.options)
                      QuestionOptionTile(
                        label: option.label(draft.language),
                        selected: selected == option.code,
                        onPressed: () => _call(
                          context,
                          () => vm.selectAnswer(
                            assessmentId,
                            question.id,
                            option.code,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => _call(context, () async {
                          if (index == 0) {
                            await vm.pause(assessmentId);
                            if (context.mounted) {
                              Navigator.pushNamedAndRemoveUntil(
                                context,
                                AppRoutes.assessmentHome,
                                (r) =>
                                    r.isFirst &&
                                    r.settings.name != AppRoutes.assessmentHome,
                              );
                            }
                          } else {
                            await vm.moveCursor(
                              assessmentId,
                              route[index - 1].id,
                            );
                          }
                        }),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(54),
                        ),
                        child: const Text('‹ Previous'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        onPressed: !canNext
                            ? null
                            : () => _call(context, () async {
                                if (index < route.length - 1) {
                                  await vm.moveCursor(
                                    assessmentId,
                                    route[index + 1].id,
                                  );
                                } else {
                                  await Navigator.pushNamed<void>(
                                    context,
                                    AppRoutes.assessmentReview,
                                    arguments: assessmentId,
                                  );
                                }
                              }),
                        child: Text(
                          index == route.length - 1 ? 'Review' : 'Next  ›',
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
