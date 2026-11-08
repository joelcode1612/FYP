import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/questionnaire_repository.dart';
import '../model/mock_routing.dart';
import '../model/question.dart';
import '../model/questionnaire_state.dart';
import '../viewmodel/questionnaire_viewmodel.dart';
import 'components.dart';

class ReviewPage extends ConsumerWidget {
  const ReviewPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(questionnaireProvider);
    final vm = ref.read(questionnaireProvider.notifier);
    return Column(
      children: [
        SurveyHeader(
          title: s.tr('Review & submit', 'Semak & hantar'),
          onBack: vm.previous,
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RouteProgress(s, review: true),
                const SizedBox(height: 22),
                SoftCard(
                  color: s.canSubmit
                      ? const Color(0xFFE9F8F2)
                      : const Color(0xFFFFF6E6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        s.canSubmit ? Icons.check_circle : Icons.info_outline,
                        color: s.canSubmit
                            ? const Color(0xFF39914A)
                            : const Color(0xFF9C6A18),
                        size: 40,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              s.canSubmit
                                  ? s.tr(
                                      'Ready to review',
                                      'Sedia untuk disemak',
                                    )
                                  : s.tr(
                                      'Your route needs attention',
                                      'Laluan anda perlu dilengkapkan',
                                    ),
                              style: const TextStyle(
                                fontSize: 21,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              s.tr(
                                '${s.answeredCount} answered of ${s.shownCount} shown on your current ${s.route.length}-question mock route. ${s.optionalSkippedCount} optional skipped.',
                                '${s.answeredCount} dijawab daripada ${s.shownCount} dipaparkan pada laluan contoh ${s.route.length} soalan. ${s.optionalSkippedCount} pilihan dilangkau.',
                              ),
                              style: const TextStyle(
                                fontSize: 13,
                                height: 1.45,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                SoftCard(
                  color: Colors.white,
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(
                          Icons.fact_check_outlined,
                          color: navy,
                        ),
                        title: Text(
                          s.tr('Review your responses', 'Semak jawapan anda'),
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        subtitle: Text(
                          s.tr(
                            'Expand a section to inspect or change an answer.',
                            'Buka bahagian untuk memeriksa atau menukar jawapan.',
                          ),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      for (final group in [
                        (
                          s.tr(
                            'A. Your profile & area',
                            'A. Profil & kawasan anda',
                          ),
                          ['Q01', 'Q02', 'Q03'],
                          Icons.person_outline,
                        ),
                        (
                          s.tr(
                            'B. Café use & interest',
                            'B. Penggunaan & minat kafe',
                          ),
                          ['Q04', 'Q05', 'Q06'],
                          Icons.coffee_outlined,
                        ),
                        (
                          s.tr(
                            'C. Offer, occasions & features',
                            'C. Tawaran, tujuan & ciri',
                          ),
                          ['Q07', 'Q08', 'Q09', 'Q10'],
                          Icons.storefront_outlined,
                        ),
                        (
                          s.tr(
                            'D. Optional final context',
                            'D. Konteks akhir pilihan',
                          ),
                          ['Q11', 'Q12', 'Q13'],
                          Icons.insights_outlined,
                        ),
                      ])
                        _ReviewGroup(
                          title: group.$1,
                          ids: group.$2,
                          icon: group.$3,
                          state: s,
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  s.tr(
                    '${13 - s.route.length} bank questions are outside this mock route.',
                    '${13 - s.route.length} soalan bank berada di luar laluan contoh ini.',
                  ),
                  style: const TextStyle(fontSize: 12, height: 1.4),
                ),
                if (s.removedExposureCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      s.tr(
                        '${s.removedExposureCount} previously displayed questions were removed after a route change. Their answers were cleared.',
                        '${s.removedExposureCount} soalan yang pernah dipaparkan telah dikeluarkan selepas perubahan laluan. Jawapannya dipadamkan.',
                      ),
                      style: const TextStyle(fontSize: 12, height: 1.4),
                    ),
                  ),
                if (!s.canSubmit)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      s.tr(
                        'Open unanswered or unvisited items above before submitting. Optional items may be skipped.',
                        'Buka soalan belum dijawab atau belum dilihat di atas sebelum menghantar. Soalan pilihan boleh dilangkau.',
                      ),
                      style: const TextStyle(
                        color: Color(0xFF9C6A18),
                        fontSize: 13,
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                Text(
                  s.tr(
                    'Answered includes refusal and uncertainty selections. It is not a count of substantive valid responses.',
                    'Bilangan dijawab termasuk pilihan tidak mahu menjawab dan tidak pasti. Ini bukan bilangan jawapan sah substantif.',
                  ),
                  style: const TextStyle(fontSize: 12, height: 1.4),
                ),
                DemoNotice(s),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              BlueButton(
                buttonKey: const ValueKey('submit'),
                label: s.tr('Submit demo responses', 'Hantar jawapan contoh'),
                onPressed: s.canSubmit ? () => vm.submit() : null,
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: vm.previous,
                  child: Text(
                    s.tr(
                      '‹  Back to ${s.route.last.id}',
                      '‹  Kembali ke ${s.route.last.id}',
                    ),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ReviewGroup extends ConsumerWidget {
  final String title;
  final List<String> ids;
  final IconData icon;
  final QuestionnaireState state;
  const _ReviewGroup({
    required this.title,
    required this.ids,
    required this.icon,
    required this.state,
  });
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = state;
    final current = s.route.where((q) => ids.contains(q.id)).toList();
    final shown = current.where((q) => s.displayed.contains(q.id)).length;
    final answered = current.where(s.isAnswered).length;
    return ExpansionTile(
      key: ValueKey('review_group_${ids.first}'),
      tilePadding: const EdgeInsets.symmetric(horizontal: 8),
      childrenPadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: CircleAvatar(
        backgroundColor: paleBlue,
        foregroundColor: navy,
        child: Icon(icon, size: 24),
      ),
      title: Text(
        title,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        s.tr(
          '$answered answered · $shown shown · ${current.length} on route',
          '$answered dijawab · $shown dipaparkan · ${current.length} dalam laluan',
        ),
        style: const TextStyle(fontSize: 11),
      ),
      children: [
        for (final q in s.bank.where((q) => ids.contains(q.id)))
          _ReviewItem(q: q, state: s),
      ],
    );
  }
}

class _ReviewItem extends ConsumerWidget {
  final Question q;
  final QuestionnaireState state;
  const _ReviewItem({required this.q, required this.state});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = state;
    final reason = MockRouting.exclusion(q.id, s.answers, s.config);
    final shown = s.displayed.contains(q.id);
    final answered = s.isAnswered(q);
    final skipped = q.optional && s.skipped.contains(q.id);
    final status = reason != null
        ? s.tr(
            shown
                ? 'Previously shown · now excluded'
                : 'Not shown · outside route',
            shown
                ? 'Pernah dipaparkan · kini dikecualikan'
                : 'Tidak dipaparkan · di luar laluan',
          )
        : !shown
        ? s.tr('Not yet shown', 'Belum dipaparkan')
        : answered
        ? s.tr('Answered', 'Dijawab')
        : skipped
        ? s.tr('Optional · skipped', 'Pilihan · dilangkau')
        : s.tr('Unanswered', 'Belum dijawab');
    final answer = s.answers[q.id];
    String value = '';
    if (reason != null) {
      value = s.local(reason);
    } else if (q.kind == QuestionKind.matrix && answer != null) {
      value = QuestionnaireRepository.features
          .map((f) {
            final selected = q.options.where(
              (o) => o.code == answer.ratings[f.id],
            );
            return '${s.local(f.label)}: ${selected.isEmpty ? s.tr('Unanswered', 'Belum dijawab') : s.local(selected.first.label)}';
          })
          .join('\n');
    } else if (answer != null) {
      value = q.options
          .where((o) => answer.codes.contains(o.code))
          .map((o) => s.local(o.label))
          .join(', ');
    }
    return Container(
      key: ValueKey('review_${q.id}'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${q.id} · ${s.local(q.title)}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (reason == null)
                TextButton(
                  key: ValueKey('edit_${q.id}'),
                  onPressed: () =>
                      ref.read(questionnaireProvider.notifier).edit(q.id),
                  child: Text(s.tr('Edit', 'Ubah')),
                ),
            ],
          ),
          Text(
            status,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: reason != null
                  ? const Color(0xFF687388)
                  : answered
                  ? const Color(0xFF2C7E41)
                  : const Color(0xFF93641A),
            ),
          ),
          if (q.optional)
            Text(
              s.tr('Optional question', 'Soalan pilihan'),
              style: const TextStyle(fontSize: 11, color: Color(0xFF687388)),
            ),
          if (value.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                value,
                style: const TextStyle(fontSize: 12, height: 1.5),
              ),
            ),
        ],
      ),
    );
  }
}

class DemoSubmittedPage extends ConsumerWidget {
  const DemoSubmittedPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(questionnaireProvider);
    return Column(
      children: [
        SurveyHeader(title: s.tr('Demo complete', 'Demo selesai')),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const SizedBox(height: 50),
                const Icon(
                  Icons.check_circle,
                  size: 80,
                  color: Color(0xFF39914A),
                ),
                const SizedBox(height: 24),
                Text(
                  s.tr(
                    'Thank you for trying Project1',
                    'Terima kasih kerana mencuba Project1',
                  ),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 20),
                SoftCard(
                  child: Text(
                    s.tr(
                      'Local demo confirmation only. No responses were sent or saved.\n\n${s.answeredCount} answered · ${s.shownCount} shown · ${s.optionalSkippedCount} optional skipped.\n\nThis is not evidence of scientific approval, actual demand or completion of all 13 bank questions.',
                      'Pengesahan demo setempat sahaja. Tiada jawapan dihantar atau disimpan.\n\n${s.answeredCount} dijawab · ${s.shownCount} dipaparkan · ${s.optionalSkippedCount} pilihan dilangkau.\n\nIni bukan bukti kelulusan saintifik, permintaan sebenar atau semua 13 soalan bank telah dilengkapkan.',
                    ),
                    style: const TextStyle(height: 1.6),
                  ),
                ),
                DemoNotice(s),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: BlueButton(
            label: s.tr('Clear & start again', 'Padam & mula semula'),
            onPressed: ref.read(questionnaireProvider.notifier).reset,
          ),
        ),
      ],
    );
  }
}
