import 'package:flutter/material.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../model/entities/assessment.dart';
import '../../model/entities/assessment_draft.dart';

class AssessmentCard extends StatelessWidget {
  final AssessmentOffer offer;
  final AssessmentDraft? draft;
  final int questionCount;
  final int recorded;
  final double progress;
  final VoidCallback onPressed;

  const AssessmentCard({
    super.key,
    required this.offer,
    required this.draft,
    required this.questionCount,
    required this.recorded,
    required this.progress,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final status = draft == null
        ? 'Not started'
        : draft!.status == DraftStatus.previewCompleted
        ? 'Preview completed'
        : draft!.status == DraftStatus.paused
        ? 'Paused'
        : 'In progress';
    final action = draft == null
        ? 'Start Assessment'
        : draft!.status == DraftStatus.previewCompleted
        ? 'View Summary'
        : 'Resume Assessment';
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      elevation: 0,
      color: SitewiseColors.surface,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: SitewiseColors.border),
        borderRadius: BorderRadius.circular(19),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    color: SitewiseColors.infoWash,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.local_cafe_outlined,
                    color: SitewiseColors.action,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        offer.title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 17,
                        ),
                      ),
                      Text(
                        offer.area,
                        style: const TextStyle(
                          color: SitewiseColors.muted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              status,
              style: TextStyle(
                color: draft?.status == DraftStatus.paused
                    ? SitewiseColors.warning
                    : SitewiseColors.action,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 13),
            Text(offer.description, style: const TextStyle(height: 1.4)),
            const SizedBox(height: 10),
            Text(
              '13 questions in source bank · $questionCount in UI demo route',
              style: const TextStyle(fontSize: 12, color: SitewiseColors.muted),
            ),
            if (draft != null) ...[
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Expanded(
                    child: Text(
                      'Saved progress',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '$recorded / $questionCount',
                    style: const TextStyle(color: SitewiseColors.action),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              LinearProgressIndicator(
                value: progress,
                minHeight: 7,
                borderRadius: BorderRadius.circular(7),
                backgroundColor: SitewiseColors.border,
              ),
              const SizedBox(height: 6),
              Text(
                'Last saved: ${draft!.updatedAt.toLocal().toString().substring(0, 16)}',
                style: const TextStyle(
                  color: SitewiseColors.muted,
                  fontSize: 11,
                ),
              ),
            ],
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 10),
              title: const Text(
                'Assessment details',
                style: TextStyle(fontSize: 14),
              ),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Bank: ${offer.bankVersion}\nRoute: ${offer.routingVersion}\n'
                    'Concept: ${offer.conceptVersion}\n'
                    'A local draft is saved after every answer and navigation. '
                    'This is a synthetic UI demo, not real fielding.',
                    style: const TextStyle(
                      color: SitewiseColors.muted,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onPressed,
                icon: Icon(
                  draft == null ? Icons.arrow_forward : Icons.play_arrow,
                ),
                label: Text(action),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
