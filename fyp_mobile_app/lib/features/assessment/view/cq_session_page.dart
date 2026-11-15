import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../viewmodel/cq_view_model.dart';
import 'components/cq_ui_primitives.dart';
import 'components/question_option_tile.dart';

/// Redesigned presentation around the existing versioned FastAPI CQ session.
/// The view model still owns all consent, stimulus, routing, answer, edit,
/// submission, and withdrawal operations; this widget adds no local authority.
class CqSessionPage extends ConsumerStatefulWidget {
  final String sessionId;
  const CqSessionPage({super.key, required this.sessionId});

  @override
  ConsumerState<CqSessionPage> createState() => _CqSessionPageState();
}

class _CqSessionPageState extends ConsumerState<CqSessionPage> {
  final _scroll = ScrollController(keepScrollOffset: false);
  String? _viewToken;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (mounted) ref.read(cqViewModelProvider(widget.sessionId)).load();
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = ref.watch(cqViewModelProvider(widget.sessionId));
    final s = vm.session;
    final error = vm.error;
    final token = '${s?.revision}-${s?.presentation?['display_id']}';
    if (token != _viewToken) {
      _viewToken = token;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
      });
    }

    final children = <Widget>[
      CqHero(
        title: s == null
            ? 'Customer questionnaire'
            : s.manifest['title'] as String,
        subtitle: s == null
            ? vm.busy
                  ? 'Loading your saved questionnaire session.'
                  : vm.withdrawn
                  ? 'Participation withdrawn.'
                  : 'Your saved questionnaire is unavailable.'
            : 'Version ${s.manifest['version']}',
      ),
    ];

    if (vm.busy) children.add(const LinearProgressIndicator());
    if (error != null) {
      children.add(
        CqNotice(
          message: error,
          tone: CqNoticeTone.error,
          messageKey: const Key('cq-error'),
        ),
      );
      children.add(
        CqPanel(
          child: Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: vm.busy ? null : vm.retry,
                icon: const Icon(Icons.refresh_outlined),
                label: const Text('Retry'),
              ),
              TextButton(
                onPressed: vm.busy ? null : vm.load,
                child: const Text('Reload saved session'),
              ),
            ],
          ),
        ),
      );
    }
    if (vm.withdrawn) {
      children.add(
        const CqNotice(
          message:
              'Participation withdrawn. Your earlier audit records are retained.',
          tone: CqNoticeTone.info,
        ),
      );
    }

    if (s != null) {
      final locale = s.data['locale'] as String;
      if (s.data['execution_scope'] == 'ISOLATED_TEST') {
        children.add(
          const CqNotice(
            message: 'Isolated technical test — no customer fielding',
            tone: CqNoticeTone.info,
          ),
        );
      }

      if (s.data['status'] == 'SUBMITTED') {
        final receipt = s.data['receipt'] as Map<String, dynamic>;
        children.add(
          CqPanel(
            title: 'Submission received',
            icon: Icons.check_circle_outline,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Submission received',
                  key: Key('cq-submitted'),
                  style: TextStyle(
                    color: CqUiColors.success,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 14),
                const CqMetaText(text: 'Receipt identifier'),
                SelectableText('${receipt['receipt_id']}'),
                const SizedBox(height: 12),
                const CqMetaText(text: 'Verification hash'),
                SelectableText('${receipt['receipt_hash']}'),
              ],
            ),
          ),
        );
      } else if (s.data['status'] == 'WITHDRAWN') {
        children.add(
          const CqNotice(
            message: 'Participation withdrawn.',
            tone: CqNoticeTone.info,
          ),
        );
      } else if (s.data['consented'] != true) {
        children.add(
          CqPanel(
            title: 'About this questionnaire',
            icon: Icons.description_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  (s.manifest['consent_text'] as Map)[locale] as String,
                  style: const TextStyle(
                    color: CqUiColors.ink,
                    fontSize: 15,
                    height: 1.55,
                  ),
                ),
                const SizedBox(height: 24),
                CqFullWidthAction(
                  text: 'I agree to participate',
                  icon: Icons.check_rounded,
                  actionKey: const Key('cq-consent'),
                  onPressed: vm.busy || error != null ? null : vm.consent,
                ),
              ],
            ),
          ),
        );
      } else if (s.data['next_stimulus_kind'] != null) {
        final kind = s.data['next_stimulus_kind'] as String;
        final stimulus = (s.manifest['stimuli'] as Map)[kind] as Map;
        children.add(
          CqPanel(
            title: 'Information for this question',
            icon: Icons.info_outline,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  (stimulus['text'] as Map)[locale] as String,
                  style: const TextStyle(
                    fontSize: 15,
                    height: 1.55,
                    color: CqUiColors.ink,
                  ),
                ),
                const SizedBox(height: 12),
                CqMetaText(text: 'Source version: ${stimulus['version']}'),
                const SizedBox(height: 20),
                CqFullWidthAction(
                  text: 'Continue with this information',
                  actionKey: const Key('cq-stimulus'),
                  onPressed: vm.busy || error != null ? null : vm.stimulus,
                ),
              ],
            ),
          ),
        );
      } else if (s.presentation != null) {
        final p = s.presentation!;
        final q = vm.question!;
        final labels = (q['labels'] as Map)[locale] as Map;
        final multiSelect = (q['type'] as String).startsWith('multi_select');
        final isIsolatedAdditionalQuestion =
            s.manifest['test_placement'] == 'isolated-last/1' &&
            q['id'] == 'Q14';
        children.add(
          CqPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: CqUiColors.blueSoft,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        p['slot_id'] as String,
                        key: const Key('cq-slot'),
                        style: const TextStyle(
                          color: CqUiColors.blue,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const Spacer(),
                    const Icon(
                      Icons.assignment_outlined,
                      color: CqUiColors.secondary,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (isIsolatedAdditionalQuestion) ...[
                  CqNotice(
                    message: 'Isolated test preview · ${q['stimulus_text']}',
                    tone: CqNoticeTone.info,
                  ),
                  const SizedBox(height: 14),
                ],
                Text(
                  (q['wording'] as Map)[locale] as String,
                  key: const Key('cq-wording'),
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: CqUiColors.ink,
                    fontWeight: FontWeight.w800,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 12),
                CqMetaText(text: 'Question version: ${p['question_version']}'),
                if (isIsolatedAdditionalQuestion)
                  CqMetaText(text: 'Option version: ${q['option_version']}'),
                if (multiSelect) ...[
                  const SizedBox(height: 12),
                  const CqNotice(
                    message:
                        'Select all that apply. Exclusive answers must be selected alone.',
                    tone: CqNoticeTone.info,
                  ),
                ],
                const SizedBox(height: 18),
                for (final code in (q['codes'] as List).cast<String>())
                  QuestionOptionTile(
                    key: ValueKey('cq-option-$code'),
                    label: labels[code] as String,
                    selected: vm.selected.contains(code),
                    multiple: multiSelect,
                    onPressed: vm.busy || error != null
                        ? null
                        : () => vm.choose(code),
                  ),
                const SizedBox(height: 12),
                CqFullWidthAction(
                  text: 'Save answer',
                  icon: Icons.save_outlined,
                  actionKey: const Key('cq-answer'),
                  onPressed: vm.busy || error != null || vm.selected.isEmpty
                      ? null
                      : vm.answer,
                ),
                if (q['required_for_answer'] == false) ...[
                  const SizedBox(height: 6),
                  TextButton(
                    key: const Key('cq-skip'),
                    onPressed: vm.busy || error != null
                        ? null
                        : () => vm.answer(skip: true),
                    child: const Text('Skip this question'),
                  ),
                ],
              ],
            ),
          ),
        );
      } else if (s.data['can_submit'] == true) {
        children.add(
          CqPanel(
            title: 'Review your current answers',
            icon: Icons.fact_check_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final row in s.routing.where(
                  (r) => r['verdict'] == 'SHOWN',
                ))
                  Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                      border: Border.all(color: CqUiColors.outline),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                      ),
                      title: Text(
                        (s.question(row['slot_id'] as String)['wording']
                                as Map)[locale]
                            as String,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        _answerText(
                          s.question(row['slot_id'] as String),
                          row,
                          locale,
                        ),
                      ),
                      trailing: TextButton(
                        key: ValueKey('cq-edit-${row['slot_id']}'),
                        onPressed: vm.busy || error != null
                            ? null
                            : () => vm.edit(row['slot_id'] as String),
                        child: const Text('Edit'),
                      ),
                    ),
                  ),
                const SizedBox(height: 10),
                CqFullWidthAction(
                  text: 'Submit questionnaire',
                  icon: Icons.send_outlined,
                  actionKey: const Key('cq-submit'),
                  onPressed: vm.busy || error != null ? null : vm.submit,
                ),
              ],
            ),
          ),
        );
      }

      if (s.data['status'] != 'WITHDRAWN') {
        children.add(
          Center(
            child: TextButton.icon(
              key: const Key('cq-withdraw'),
              onPressed: vm.busy ? null : vm.withdraw,
              icon: const Icon(Icons.exit_to_app_outlined),
              label: const Text('Withdraw participation'),
            ),
          ),
        );
      }
    }

    return CqPageFrame(
      key: ValueKey('cq-${s?.revision}-${s?.presentation?['display_id']}'),
      controller: _scroll,
      children: children,
    );
  }

  String _answerText(
    Map<String, dynamic> q,
    Map<String, dynamic> row,
    String locale,
  ) {
    final labels = (q['labels'] as Map)[locale] as Map;
    final value = row['value'];
    final codes = value is List
        ? value
        : value == null
        ? []
        : [value];
    return '${row['state']}: ${codes.map((c) => labels[c] ?? c).join(', ')}';
  }
}
