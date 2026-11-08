import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../model/question.dart';
import '../model/questionnaire_state.dart';
import '../viewmodel/questionnaire_viewmodel.dart';

const navy = Color(0xFF12294C);
const ink = Color(0xFF101B36);
const blue = Color(0xFF0765EF);
const paleBlue = Color(0xFFEEF4FD);
const line = Color(0xFFDCE3ED);

extension ViewText on QuestionnaireState {
  String tr(String en, String bm) => language == AppLanguage.en ? en : bm;
  String local(LocalText text) => text.inLanguage(language);
}

class BlueButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Key? buttonKey;
  const BlueButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.buttonKey,
  });
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        colors: onPressed == null
            ? [const Color(0xFF8A99AF), const Color(0xFF8A99AF)]
            : [const Color(0xFF265B96), const Color(0xFF163D6D)],
      ),
      borderRadius: BorderRadius.circular(16),
    ),
    child: FilledButton(
      key: buttonKey,
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: Colors.transparent,
        disabledBackgroundColor: Colors.transparent,
        disabledForegroundColor: Colors.white70,
        shadowColor: Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 17),
        minimumSize: const Size(double.infinity, 56),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.center,
        spacing: 8,
        children: [
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          if (icon != null) Icon(icon, size: 22),
        ],
      ),
    ),
  );
}

class SoftCard extends StatelessWidget {
  final Widget child;
  final Color color;
  final EdgeInsets padding;
  const SoftCard({
    super.key,
    required this.child,
    this.color = paleBlue,
    this.padding = const EdgeInsets.all(18),
  });
  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: Material(
      color: color,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: line),
      ),
      child: Padding(padding: padding, child: child),
    ),
  );
}

class DemoNotice extends StatelessWidget {
  final QuestionnaireState state;
  const DemoNotice(this.state, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 9),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.science_outlined, size: 16, color: Color(0xFF646E80)),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            state.tr(
              'UI demo · mock rules · not approved for field use',
              'Demo UI · peraturan contoh · draf BM · belum diluluskan untuk kajian lapangan',
            ),
            style: const TextStyle(
              fontSize: 11,
              height: 1.4,
              color: Color(0xFF566276),
            ),
          ),
        ),
      ],
    ),
  );
}

class LanguageSwitch extends ConsumerWidget {
  const LanguageSwitch({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(questionnaireProvider);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: AppLanguage.values.map((language) {
        final selected = state.language == language;
        return Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Semantics(
            selected: selected,
            child: TextButton(
              key: ValueKey('language_${language.name}'),
              style: TextButton.styleFrom(
                minimumSize: const Size(44, 44),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                foregroundColor: selected ? Colors.white : ink,
                backgroundColor: selected
                    ? const Color(0xFF24558A)
                    : Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(color: selected ? navy : line),
                ),
              ),
              onPressed: () => ref
                  .read(questionnaireProvider.notifier)
                  .setLanguage(language),
              child: Text(
                language.name.toUpperCase(),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

class SurveyHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onBack;
  const SurveyHeader({super.key, required this.title, this.onBack});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 10, 16, 6),
    child: Row(
      children: [
        if (onBack != null)
          IconButton(
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back, color: ink),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              title,
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
            ),
          ),
        ),
        const LanguageSwitch(),
      ],
    ),
  );
}

class RouteProgress extends StatelessWidget {
  final QuestionnaireState state;
  final bool review;
  const RouteProgress(this.state, {super.key, this.review = false});
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              state.tr('Your route', 'Laluan anda'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: Text(
              review
                  ? state.tr(
                      '${state.shownCount} shown',
                      '${state.shownCount} dipaparkan',
                    )
                  : state.tr(
                      'Step ${state.index + 1} of ${state.route.length}',
                      'Langkah ${state.index + 1} daripada ${state.route.length}',
                    ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      Semantics(
        label: state.tr('Route progress', 'Kemajuan laluan'),
        value: '${(state.progress * 100).round()}%',
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            minHeight: 9,
            value: state.progress,
            color: blue,
            backgroundColor: const Color(0xFFDCE3EC),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Text(
        state.tr(
          '${state.answeredCount} answered · ${state.optionalSkippedCount} optional skipped · 13 in bank',
          '${state.answeredCount} dijawab · ${state.optionalSkippedCount} pilihan dilangkau · 13 dalam bank',
        ),
        style: const TextStyle(fontSize: 12, color: Color(0xFF59677E)),
      ),
    ],
  );
}
