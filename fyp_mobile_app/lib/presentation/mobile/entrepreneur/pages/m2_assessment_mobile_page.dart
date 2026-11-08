import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../core/theme/sitewise_theme.dart';

/// Entrepreneur M2 questionnaire — mobile port of the Jaspr prototype page
/// (`lib/prototype/prototype_m2.dart`, `M2Page`).
///
/// **MVVM.** The view holds no assessment logic: answers, validation and
/// progress all come from [M2AssessmentNotifier] in `shared_logic`. This widget
/// is the "V"; it renders [M2AssessmentState] and forwards intents.
///
/// **The data is prototype data.** Wording, options and routing are a working
/// design pending scientific finalisation; the answers are illustrative, not
/// fielded research. That caveat is shown in the UI deliberately — the web
/// prototype shows the same notice.
class M2AssessmentMobilePage extends ConsumerStatefulWidget {
  const M2AssessmentMobilePage({super.key});

  @override
  ConsumerState<M2AssessmentMobilePage> createState() =>
      _M2AssessmentMobilePageState();
}

class _M2AssessmentMobilePageState
    extends ConsumerState<M2AssessmentMobilePage> {
  /// Controllers for text items only. Kept here because a controller is a view
  /// concern, not ViewModel state.
  final Map<String, TextEditingController> _text = {};

  @override
  void initState() {
    super.initState();
    final state = ref.read(m2AssessmentProvider);
    for (final item in kM2AnswerItems) {
      if (item.type == M2ItemType.text) {
        _text[item.id] = TextEditingController(
          text: state.answers[item.id] ?? '',
        );
      }
    }
  }

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final vm = ref.read(m2AssessmentProvider.notifier);
    final ok = vm.submit();
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Assessment submitted (prototype — nothing is stored).'),
        ),
      );
    } else {
      final missing = vm.missingRequired.length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '$missing required ${missing == 1 ? 'field is' : 'fields are'} still empty.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(m2AssessmentProvider);
    final vm = ref.read(m2AssessmentProvider.notifier);

    // Re-sync text controllers when the ViewModel resets or clears.
    ref.listen<M2AssessmentState>(m2AssessmentProvider, (_, next) {
      for (final entry in _text.entries) {
        final want = next.answers[entry.key] ?? '';
        if (entry.value.text != want) entry.value.text = want;
      }
    });

    final sections = M2AssessmentState.sectionsOf(kM2AnswerItems);

    return Scaffold(
      backgroundColor: SitewiseColors.background,
      appBar: AppBar(
        title: const Text('M2 questionnaire'),
        backgroundColor: SitewiseColors.surface,
        foregroundColor: SitewiseColors.ink,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(SitewiseSpacing.md),
        children: [
          _PrototypeNotice(),
          const SizedBox(height: SitewiseSpacing.md),
          _ProgressCard(
            answered: vm.answeredCount,
            total: vm.fieldCount,
            progress: vm.progress,
            onReset: () {
              vm.resetToSamples();
              _text.forEach((id, c) {
                c.text = ref.read(m2AssessmentProvider).answers[id] ?? '';
              });
            },
            onClear: () {
              vm.clearAll();
              _text.forEach((id, c) => c.text = '');
            },
          ),
          if (state.showErrors && vm.missingRequired.isNotEmpty) ...[
            const SizedBox(height: SitewiseSpacing.md),
            _ErrorBanner(missing: vm.missingRequired),
          ],
          for (final section in sections) ...[
            const SizedBox(height: SitewiseSpacing.lg),
            _SectionHeader(section),
            const SizedBox(height: SitewiseSpacing.sm),
            for (final item in M2AssessmentState.itemsInSection(
              kM2AnswerItems,
              section,
            ))
              _ItemCard(
                item: item,
                state: state,
                controller: _text[item.id],
                onChanged: (v) => vm.setAnswer(item.id, v),
                onToggle: (opt) => vm.toggleMulti(item.id, opt),
              ),
          ],
          if (kM2Actions.isNotEmpty) ...[
            const SizedBox(height: SitewiseSpacing.lg),
            const _SectionHeader('Review actions'),
            const SizedBox(height: SitewiseSpacing.sm),
            for (final action in kM2Actions) _ActionRow(action),
          ],
          const SizedBox(height: SitewiseSpacing.xl),
          FilledButton(
            onPressed: _submit,
            style: FilledButton.styleFrom(
              backgroundColor: SitewiseColors.action,
              minimumSize: const Size.fromHeight(48),
            ),
            child: const Text('Submit assessment'),
          ),
          const SizedBox(height: SitewiseSpacing.xl),
        ],
      ),
    );
  }
}

// --- pieces ---------------------------------------------------------------

class _PrototypeNotice extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(SitewiseSpacing.md),
      decoration: BoxDecoration(
        color: SitewiseColors.warningWash,
        borderRadius: BorderRadius.circular(SitewiseSpacing.radius),
        border: Border.all(color: SitewiseColors.borderStrong),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 18, color: SitewiseColors.warning),
          const SizedBox(width: SitewiseSpacing.sm),
          Expanded(
            child: Text(
              'Working design: wording, options and routing require scientific '
              'finalisation. Answers are versioned sample inputs, not fielded '
              'research. Nothing is stored.',
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: SitewiseColors.text,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressCard extends StatelessWidget {
  final int answered;
  final int total;
  final double progress;
  final VoidCallback onReset;
  final VoidCallback onClear;

  const _ProgressCard({
    required this.answered,
    required this.total,
    required this.progress,
    required this.onReset,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(SitewiseSpacing.md),
      decoration: BoxDecoration(
        color: SitewiseColors.surface,
        borderRadius: BorderRadius.circular(SitewiseSpacing.radius),
        border: Border.all(color: SitewiseColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Answered',
                style: TextStyle(
                  fontSize: 12,
                  color: SitewiseColors.muted,
                  letterSpacing: 0.4,
                ),
              ),
              Text(
                '$answered / $total',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: SitewiseColors.ink,
                ),
              ),
            ],
          ),
          const SizedBox(height: SitewiseSpacing.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: SitewiseColors.paper,
              valueColor: const AlwaysStoppedAnimation(SitewiseColors.action),
            ),
          ),
          const SizedBox(height: SitewiseSpacing.md),
          // FE-DEF-02: a `Row` of two buttons overflowed by 124 px at 360 px
          // width. `Wrap` keeps both reachable on narrow screens instead of
          // clipping the second one.
          Wrap(
            spacing: SitewiseSpacing.sm,
            runSpacing: SitewiseSpacing.xs,
            children: [
              OutlinedButton(
                onPressed: onReset,
                child: const Text('Reset to sample'),
              ),
              TextButton(
                onPressed: onClear,
                style: TextButton.styleFrom(
                  foregroundColor: SitewiseColors.danger,
                ),
                child: const Text('Clear all'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final List<M2Item> missing;

  const _ErrorBanner({required this.missing});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(SitewiseSpacing.md),
      decoration: BoxDecoration(
        color: SitewiseColors.dangerWash,
        borderRadius: BorderRadius.circular(SitewiseSpacing.radius),
        border: Border.all(color: SitewiseColors.danger.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${missing.length} required ${missing.length == 1 ? 'field' : 'fields'} still empty',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: SitewiseColors.danger,
            ),
          ),
          const SizedBox(height: SitewiseSpacing.xs),
          Text(
            missing.map((i) => i.id).join(', '),
            style: TextStyle(fontSize: 12, color: SitewiseColors.text),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Text(
      title.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
        color: SitewiseColors.overline,
      ),
    );
  }
}

class _ItemCard extends StatelessWidget {
  final M2Item item;
  final M2AssessmentState state;
  final TextEditingController? controller;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onToggle;

  const _ItemCard({
    required this.item,
    required this.state,
    required this.controller,
    required this.onChanged,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final answered = state.isAnswered(item);
    final showError = state.showErrors && item.required && !answered;

    return Container(
      margin: const EdgeInsets.only(bottom: SitewiseSpacing.sm),
      padding: const EdgeInsets.all(SitewiseSpacing.md),
      decoration: BoxDecoration(
        color: SitewiseColors.surface,
        borderRadius: BorderRadius.circular(SitewiseSpacing.radius),
        border: Border.all(
          color: showError ? SitewiseColors.danger : SitewiseColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.id,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: SitewiseColors.overline,
                ),
              ),
              if (item.required) ...[
                const SizedBox(width: 4),
                const Text(
                  '*',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: SitewiseColors.danger,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            item.prompt,
            style: const TextStyle(
              fontSize: 13.5,
              height: 1.35,
              color: SitewiseColors.text,
            ),
          ),
          const SizedBox(height: SitewiseSpacing.sm),
          _input(),
        ],
      ),
    );
  }

  Widget _input() {
    switch (item.type) {
      case M2ItemType.choice:
        // FE-DEF-01: `RadioListTile` is a `ListTile`, which paints its ink
        // splash on the nearest `Material`. `_ItemCard` wraps this in a
        // `Container` with a background colour, which hid that splash and
        // tripped a framework assertion on every radio row. A transparent
        // `Material` restores the expected ancestor without changing layout.
        return Material(
          type: MaterialType.transparency,
          child: RadioGroup<String>(
            groupValue: state.answers[item.id],
            onChanged: (v) => onChanged(v ?? ''),
            child: Column(
              children: [
                for (final option in item.options)
                  RadioListTile<String>(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    value: option,
                    title: Text(option, style: const TextStyle(fontSize: 13)),
                  ),
              ],
            ),
          ),
        );

      case M2ItemType.multi:
        final selected = state.multi[item.id] ?? const <String>{};
        return Wrap(
          spacing: SitewiseSpacing.sm,
          runSpacing: SitewiseSpacing.xs,
          children: [
            for (final option in item.options)
              FilterChip(
                label: Text(option, style: const TextStyle(fontSize: 12)),
                selected: selected.contains(option),
                onSelected: (_) => onToggle(option),
                selectedColor: SitewiseColors.infoWash,
                checkmarkColor: SitewiseColors.action,
              ),
          ],
        );

      case M2ItemType.text:
        return TextField(
          controller: controller,
          maxLines: 3,
          minLines: 2,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            hintText: 'Type your answer',
            hintStyle: TextStyle(fontSize: 13, color: SitewiseColors.overline),
            isDense: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(SitewiseSpacing.radiusSm),
            ),
          ),
          onChanged: onChanged,
        );

      case M2ItemType.action:
        return const SizedBox.shrink();
    }
  }
}

class _ActionRow extends StatelessWidget {
  final M2Item action;
  const _ActionRow(this.action);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: SitewiseSpacing.sm),
      padding: const EdgeInsets.all(SitewiseSpacing.md),
      decoration: BoxDecoration(
        color: SitewiseColors.paper,
        borderRadius: BorderRadius.circular(SitewiseSpacing.radius),
        border: Border.all(color: SitewiseColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.rule, size: 16, color: SitewiseColors.muted),
          const SizedBox(width: SitewiseSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  action.id,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: SitewiseColors.overline,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  action.prompt,
                  style: const TextStyle(
                    fontSize: 12.5,
                    height: 1.35,
                    color: SitewiseColors.text,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
