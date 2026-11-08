import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/questionnaire_repository.dart';
import '../model/question.dart';
import '../viewmodel/questionnaire_viewmodel.dart';
import 'components.dart';

class QuestionPage extends ConsumerWidget {
  const QuestionPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(questionnaireProvider);
    final vm = ref.read(questionnaireProvider.notifier);
    final q = s.current;
    final answer = s.answers[q.id];
    final needsConcept = [
      'Q03',
      'Q05',
      'Q06',
      'Q07',
      'Q09',
      'Q10',
      'Q11',
      'Q13',
    ].contains(q.id);
    return Column(
      children: [
        SurveyHeader(
          title: s.tr('Questionnaire', 'Soal selidik'),
          onBack: vm.previous,
        ),
        Expanded(
          child: SingleChildScrollView(
            key: ValueKey('question_scroll_${q.id}'),
            padding: const EdgeInsets.fromLTRB(22, 14, 22, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RouteProgress(s),
                const SizedBox(height: 22),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE9F1FC),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 4,
                    children: [
                      Text(
                        q.id,
                        key: const ValueKey('question_id'),
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      Text(s.local(q.title)),
                      if (q.optional)
                        Text(
                          s.tr('Optional', 'Pilihan'),
                          style: const TextStyle(
                            color: Color(0xFF5B6780),
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  s.local(q.stem),
                  key: ValueKey('stem_${q.id}'),
                  style: const TextStyle(
                    fontSize: 23,
                    height: 1.26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.35,
                  ),
                ),
                const SizedBox(height: 13),
                Text(
                  s.local(q.help),
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.45,
                    color: Color(0xFF59677E),
                  ),
                ),
                if (needsConcept) ...[
                  const SizedBox(height: 18),
                  SoftCard(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.storefront_outlined,
                          color: blue,
                          size: 35,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                s.tr(
                                  'Fictional café · demo stimulus',
                                  'Kafe rekaan · rangsangan contoh',
                                ),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                s.local(QuestionnaireRepository.concept),
                                style: const TextStyle(
                                  fontSize: 13,
                                  height: 1.4,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (q.id == 'Q07' || q.id == 'Q13') ...[
                  const SizedBox(height: 12),
                  SoftCard(
                    color: const Color(0xFFFFF8EC),
                    child: Text(
                      s.local(QuestionnaireRepository.offer),
                      style: const TextStyle(fontSize: 13, height: 1.4),
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                if (q.kind == QuestionKind.matrix)
                  for (final feature in QuestionnaireRepository.features)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: SoftCard(
                        color: Colors.white,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              s.local(feature.label),
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<String>(
                              key: ValueKey(
                                'rating_${feature.id}_${s.language.name}_${answer?.ratings[feature.id]}',
                              ),
                              initialValue: answer?.ratings[feature.id],
                              isExpanded: true,
                              decoration: InputDecoration(
                                labelText: s.tr(
                                  'Select importance',
                                  'Pilih kepentingan',
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              items: q.options
                                  .map(
                                    (o) => DropdownMenuItem(
                                      value: o.code,
                                      child: Text(
                                        s.local(o.label),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 13),
                                      ),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (value) {
                                if (value != null) vm.rate(feature.id, value);
                              },
                            ),
                          ],
                        ),
                      ),
                    )
                else
                  for (final option in q.options)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 9),
                      child: _OptionTile(
                        key: ValueKey('option_${q.id}_${option.code}'),
                        label: s.local(option.label),
                        multiple: q.kind == QuestionKind.multiple,
                        selected: answer?.codes.contains(option.code) ?? false,
                        onTap: () => vm.select(option.code),
                      ),
                    ),
                if (s.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        s.error!,
                        key: const ValueKey('validation_error'),
                        style: const TextStyle(
                          color: Color(0xFFB3261E),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                if (q.optional)
                  TextButton(
                    key: const ValueKey('skip_optional'),
                    onPressed: vm.skipOptional,
                    child: Text(
                      s.tr(
                        'Skip this optional question',
                        'Langkau soalan pilihan ini',
                      ),
                    ),
                  ),
                DemoNotice(s),
                if (s.editing)
                  OutlinedButton(
                    onPressed: vm.returnToReview,
                    child: Text(s.tr('Return to review', 'Kembali ke semakan')),
                  ),
                TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Text(
                        s.tr('Withdraw and clear?', 'Tarik diri dan padam?'),
                      ),
                      content: Text(
                        s.tr(
                          'This erases all demo answers and consent on this device.',
                          'Ini memadamkan semua jawapan contoh dan persetujuan pada peranti ini.',
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: Text(s.tr('Cancel', 'Batal')),
                        ),
                        TextButton(
                          onPressed: () {
                            Navigator.pop(context);
                            vm.reset();
                          },
                          child: Text(s.tr('Clear session', 'Padam sesi')),
                        ),
                      ],
                    ),
                  ),
                  child: Text(
                    s.tr('Withdraw & clear', 'Tarik diri & padam'),
                    style: const TextStyle(
                      color: Color(0xFF687388),
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: vm.previous,
                  child: Text(
                    s.tr('‹  Previous', '‹  Sebelum'),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: BlueButton(
                  buttonKey: const ValueKey('next'),
                  label: s.index == s.route.length - 1
                      ? s.tr('Review', 'Semak')
                      : s.tr('Next', 'Seterusnya'),
                  onPressed: vm.next,
                  icon: Icons.chevron_right,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _OptionTile extends StatelessWidget {
  final String label;
  final bool selected;
  final bool multiple;
  final VoidCallback onTap;
  const _OptionTile({
    super.key,
    required this.label,
    required this.selected,
    required this.multiple,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    selected: selected,
    button: true,
    checked: selected,
    child: Material(
      color: selected ? const Color(0xFFE0EDFF) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected ? blue : const Color(0xFFB9C4D4),
          width: selected ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
          child: Row(
            children: [
              ExcludeSemantics(
                child: Icon(
                  multiple
                      ? (selected
                            ? Icons.check_box
                            : Icons.check_box_outline_blank)
                      : (selected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off),
                  color: selected ? blue : const Color(0xFF87909D),
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.3,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
