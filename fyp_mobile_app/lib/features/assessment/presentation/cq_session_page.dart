import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:fyp/core/config/cq_development_access.dart';
import 'package:fyp/features/assessment/presentation/viewmodels/cq_view_model.dart';
import 'package:fyp/features/assessment/presentation/widgets/cq_ui_primitives.dart';
import 'package:fyp/features/assessment/presentation/widgets/question_option_tile.dart';

/// Redesigned presentation around the existing versioned FastAPI CQ session.
/// The view model still owns all consent, stimulus, routing, answer, edit,
/// submission, and withdrawal operations; this widget adds no local authority.
class CqSessionPage extends ConsumerStatefulWidget {
  final String sessionId;
  final CqViewModel? viewModel;
  const CqSessionPage({super.key, required this.sessionId, this.viewModel});

  @override
  ConsumerState<CqSessionPage> createState() => _CqSessionPageState();
}

class _CqSessionPageState extends ConsumerState<CqSessionPage> {
  final _scroll = ScrollController(keepScrollOffset: false);
  String? _viewToken;
  String? _renderedDisplay;

  @override
  void initState() {
    super.initState();
    widget.viewModel?.addListener(_changed);
    Future.microtask(() {
      if (mounted) {
        (widget.viewModel ??
                ref.read<CqViewModel>(cqViewModelProvider(widget.sessionId)))
            .load();
      }
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.viewModel?.removeListener(_changed);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final CqViewModel vm =
        widget.viewModel ??
        ref.watch<CqViewModel>(cqViewModelProvider(widget.sessionId));
    final s = vm.session;
    final syntheticFlow = vm.repository.syntheticRunId != null;
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
                  ? syntheticFlow
                        ? 'Synthetic session ended.'
                        : 'Participation withdrawn.'
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
        CqNotice(
          message: syntheticFlow
              ? 'SYNTHETIC / NOT REPORTABLE — session WITHDRAWN. Saved test answers and audit history are retained.'
              : 'Participation withdrawn. Your earlier audit records are retained.',
          tone: CqNoticeTone.info,
        ),
      );
    }

    if (s != null) {
      final locale = s.data['locale'] as String;
      final synthetic = s.data['synthetic_execution'] == true;
      final terminalSynthetic =
          synthetic &&
          ['SCREENED_OUT', 'UNRESOLVED'].contains(s.data['lifecycle_status']);
      if (synthetic) {
        children.add(
          CqNotice(
            message:
                'SYNTHETIC / NOT REPORTABLE · ${s.data['synthetic_case']}\nNonhuman test acknowledgement; real collection remains disabled.',
            tone: CqNoticeTone.warning,
          ),
        );
      }
      if (s.data['execution_scope'] == 'ISOLATED_TEST') {
        children.add(
          const CqNotice(
            message: 'Isolated technical test — no customer fielding',
            tone: CqNoticeTone.info,
          ),
        );
      }

      if (terminalSynthetic) {
        children.add(
          CqPanel(
            title: s.data['lifecycle_status'] as String,
            child: Text(
              s.data['lifecycle_status'] == 'SCREENED_OUT'
                  ? 'TEST-ONLY hypothetical eligibility fixture. This termination is independent of geography, zero days and preferences. No submission receipt or demand finding is created.'
                  : 'TEST-ONLY unresolved eligibility. No completion or demand eligibility is inferred.',
            ),
          ),
        );
      } else if (s.data['status'] == 'SUBMITTED') {
        final receipt = s.data['receipt'] as Map<String, dynamic>;
        children.add(
          CqPanel(
            title: 'Submission received',
            icon: Icons.check_circle_outline,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (s.data['lifecycle_status'] == 'COMPLETED')
                  const Text(
                    'You have completed this questionnaire.',
                    key: Key('cq-completed'),
                  ),
                const Text(
                  'Submission received',
                  key: Key('cq-submitted'),
                  style: TextStyle(
                    color: CqUiColors.success,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                const Text('Your answers have been submitted.'),
                const SizedBox(height: 14),
                const CqMetaText(text: 'Reference'),
                SelectableText('${receipt['receipt_id']}'),
                // The verification hash is an integrity value for staff and
                // diagnostics, not something a respondent can use. It stays in
                // the payload and is only shown when development access is on.
                if (CqDevelopmentAccess.enabled) ...[
                  const SizedBox(height: 12),
                  const CqMetaText(text: 'Verification hash (development)'),
                  SelectableText('${receipt['receipt_hash']}'),
                ],
              ],
            ),
          ),
        );
      } else if (s.data['status'] == 'PAUSED') {
        children.add(
          CqPanel(
            title: 'Questionnaire paused',
            icon: Icons.pause_circle_outline,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Your saved answers are retained. Resume this same questionnaire to continue.',
                ),
                const SizedBox(height: 16),
                CqFullWidthAction(
                  text: 'Resume questionnaire',
                  actionKey: const Key('cq-resume'),
                  onPressed: vm.busy || error != null ? null : vm.resume,
                ),
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
                _CqConsentDisclosure(
                  session: s,
                  locale: locale,
                  fallbackText: (s.manifest['consent_text'] as Map)[locale]
                      as String,
                ),
                const SizedBox(height: 24),
                CqFullWidthAction(
                  text: synthetic
                      ? 'Acknowledge nonhuman synthetic test'
                      : 'I agree to participate',
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
        final kinds = synthetic ? vm.displayedSyntheticStimuli : [kind];
        children.add(
          CqPanel(
            title: synthetic
                ? 'Review the questionnaire information'
                : 'Information for this question',
            icon: Icons.info_outline,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final displayedKind in kinds) ...[
                  Text(
                    ((((s.manifest['stimuli'] as Map)[displayedKind]
                                as Map)['text']
                            as Map)[locale])
                        as String,
                    style: const TextStyle(
                      fontSize: 15,
                      height: 1.55,
                      color: CqUiColors.ink,
                    ),
                  ),
                  const SizedBox(height: 12),
                  CqMetaText(
                    text:
                        'Source version: ${((s.manifest['stimuli'] as Map)[displayedKind] as Map)['version']}',
                  ),
                  const SizedBox(height: 20),
                ],
                CqFullWidthAction(
                  text: synthetic
                      ? 'Continue to questions'
                      : 'Continue with this information',
                  actionKey: const Key('cq-stimulus'),
                  onPressed: vm.busy || error != null
                      ? null
                      : synthetic
                      ? () => vm.acknowledgeDisplayedStimuli(kinds)
                      : vm.stimulus,
                ),
              ],
            ),
          ),
        );
      } else if (s.presentation != null) {
        final p = s.presentation!;
        if (s.data['render_ack_version'] == 'cq-render/1' &&
            _renderedDisplay != p['display_id'] &&
            !vm.busy &&
            error == null) {
          final display = p['display_id'] as String;
          _renderedDisplay = display;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              vm.acknowledgeRendered(display).whenComplete(() {
                if (mounted && vm.session?.presentation?['rendered'] != true) {
                  _renderedDisplay = null;
                }
              });
            }
          });
        }
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
                if (synthetic)
                  OutlinedButton.icon(
                    key: const Key('cq-previous'),
                    onPressed:
                        vm.busy ||
                            error != null ||
                            vm.previousAnsweredSlot == null
                        ? null
                        : vm.previous,
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('Previous saved question'),
                  ),
                CqFullWidthAction(
                  text: synthetic ? 'Save & Next' : 'Save answer',
                  icon: Icons.save_outlined,
                  actionKey: const Key('cq-answer'),
                  onPressed:
                      vm.busy ||
                          error != null ||
                          vm.selected.isEmpty ||
                          s.data['render_ack_version'] == 'cq-render/1' &&
                              p['rendered'] != true
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

      if (s.data['lifecycle_version'] == 'cq-lifecycle/1' &&
          !terminalSynthetic &&
          s.data['status'] == 'ACTIVE' &&
          s.data['consented'] == true) {
        children.add(
          Center(
            child: TextButton.icon(
              key: const Key('cq-pause'),
              onPressed: vm.busy || error != null ? null : vm.pause,
              icon: const Icon(Icons.pause_circle_outline),
              label: const Text('Pause questionnaire'),
            ),
          ),
        );
      }
      if (s.data['status'] != 'WITHDRAWN') {
        children.add(
          Center(
            child: TextButton.icon(
              key: const Key('cq-withdraw'),
              onPressed: vm.busy
                  ? null
                  : () async {
                      if (synthetic) {
                        final end = await showDialog<bool>(
                          context: context,
                          builder: (dialogContext) => AlertDialog(
                            title: const Text('End this synthetic session?'),
                            content: const Text(
                              'This records WITHDRAWN and closes the case. To continue answering, choose Keep answering. Saved audit records are retained.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.pop(dialogContext, false),
                                child: const Text('Keep answering'),
                              ),
                              TextButton(
                                onPressed: () =>
                                    Navigator.pop(dialogContext, true),
                                child: const Text('End session'),
                              ),
                            ],
                          ),
                        );
                        if (end != true) return;
                      }
                      await vm.withdraw();
                    },
              icon: const Icon(Icons.exit_to_app_outlined),
              label: Text(
                synthetic ? 'End synthetic session' : 'Withdraw participation',
              ),
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

/// Renders the consent disclosure carried by the session's `consent_notice`.
///
/// The backend derives that notice from the hash-pinned CUST03 contract, so this
/// widget adds no wording of its own: it prints the disclosure statements the
/// contract entails and marks any disclosure still awaiting an Owner decision.
/// A synthetic run carries no human disclosures, so it falls back to the
/// manifest's own consent text, which is the accurate statement for that scope.
class _CqConsentDisclosure extends StatelessWidget {
  const _CqConsentDisclosure({
    required this.session,
    required this.locale,
    required this.fallbackText,
  });

  final CqSession session;
  final String locale;
  final String fallbackText;

  static const _headings = <String, String>{
    'purpose': 'Why this research is being done',
    'voluntariness': 'Taking part is voluntary',
    'what_is_collected': 'What is recorded',
    'report_use': 'How responses are used in reports',
    'confidentiality': 'How confidentiality is protected',
    'withdrawal_and_retention': 'Withdrawal and data handling',
  };

  @override
  Widget build(BuildContext context) {
    final notice = session.data['consent_notice'];
    final disclosures = notice is Map ? notice['disclosures'] : null;
    final approved = notice is Map && notice['approved_for_scope'] == true;

    if (disclosures is! List || disclosures.isEmpty) {
      // No human disclosures apply (synthetic scope) or the backend is older than
      // this build. Either way the manifest text is the honest thing to show.
      return Text(
        fallbackText,
        style: const TextStyle(
          color: CqUiColors.ink,
          fontSize: 15,
          height: 1.55,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!approved)
          const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: CqNotice(
              message:
                  'This notice is pending privacy approval and is shown for review only.',
              tone: CqNoticeTone.warning,
              messageKey: Key('cq-consent-not-approved'),
            ),
          ),
        for (final entry in disclosures)
          if (entry is Map && (entry['statement'] as String?) != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _headings[entry['id']] ?? '${entry['id']}',
                    style: const TextStyle(
                      color: CqUiColors.navy,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    entry['statement'] as String,
                    style: const TextStyle(
                      color: CqUiColors.ink,
                      fontSize: 15,
                      height: 1.55,
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}
