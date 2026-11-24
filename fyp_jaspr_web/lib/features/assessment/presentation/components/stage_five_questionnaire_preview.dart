/// Stage 5 — Questionnaire preview.
///
/// A draft preview, not fielding. It renders the server's own envelope, so a
/// blocked preview reads as blocked: the reason the server gave is printed
/// verbatim, and no question is shown that the server did not return.
///
/// The envelope always reports `fieldingAuthorized` and `publicationAuthorized`
/// as false. The panel asserts that rather than trusting it silently — if a
/// future change ever returned true, the page would say so instead of implying
/// the questionnaire is ready to send.
///
/// **Four separate statuses, never collapsed.** "A question was generated",
/// "you reviewed it", "a scientific authority accepted it" and "it is published
/// or fielded" are four different claims with four different owners. The page
/// shows them as a ladder per question because a single "ready" badge would let
/// a generated draft read as a fielded questionnaire — the exact confusion this
/// stage exists to prevent.
///
/// The preview reads `m2_review_question_versions`. A Direct-QG candidate lives
/// in `m2_qg_candidates` and is therefore **not** in this preview. Those
/// candidates are listed separately and labelled as excluded, rather than being
/// silently dropped or quietly merged into the preview list.
library;

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'package:sitewise_jaspr_web/features/assessment/data/stage_four_five_api.dart';

class StageFiveQuestionnairePreview extends StatefulComponent {
  const StageFiveQuestionnairePreview({
    super.key,
    required this.m2AssessmentId,
    this.api = const StageFourFiveApi(),
  });

  final String m2AssessmentId;
  final StageFourFivePort api;

  @override
  State<StageFiveQuestionnairePreview> createState() => _StageFiveState();
}

/// One rung of the four-status ladder.
///
/// `tone` is `yes`, `no` or `unknown`. `unknown` is a first-class value: "the
/// server did not report this" is not the same as "no", and rendering it as "no"
/// would invent a refusal the server never made.
final class _LadderStep {
  const _LadderStep(this.label, this.value, this.tone);
  final String label;
  final String value;
  final String tone;
}

class _StageFiveState extends State<StageFiveQuestionnairePreview> {
  bool _loading = true;
  String? _error;
  QuestionnairePreview? _preview;

  /// Generated candidates, read from the Direct-QG table. Kept apart from
  /// `_preview.items` because they come from a different table and carry a
  /// different status vocabulary.
  List<QgCandidate> _candidates = const [];
  String? _candidateError;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _candidateError = null;
      _candidates = const [];
    });
    final result = await component.api.preview(
      assessmentId: component.m2AssessmentId,
    );
    if (!mounted) return;
    final candidates = await component.api.candidates(
      assessmentId: component.m2AssessmentId,
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (result.ok) {
        _preview = result.value;
      } else {
        _error =
            result.failure?.message ??
            'The questionnaire preview could not be read.';
      }
      if (candidates.ok) {
        _candidates = candidates.value!;
      } else {
        _candidateError =
            candidates.failure?.message ??
            'The generated question candidates could not be read.';
      }
    });
  }

  /// Turns the server's reason code into a sentence, keeping the code visible.
  String _reasonText(String reason) => switch (reason) {
    'CURRENT_CONFIRMATION_REQUIRED' =>
      'No current confirmation exists, so there is no assessment-bound '
          'questionnaire to preview.',
    'CONFIRMATION_STALE' =>
      'The confirmation is no longer current. Re-confirm the declaration '
          'before previewing.',
    'NO_ADMITTED_OBJECTIVE' =>
      'No research objective has been admitted for this confirmation, so no '
          'questionnaire can be assembled.',
    'NO_VALIDATED_QUESTION' =>
      'An objective exists but no validated question version does, so the '
          'preview is empty.',
    'QUESTIONNAIRE_SOURCE_PROJECTION_UNVERIFIED' =>
      'Question rows exist, but the adopted preview contract does not, so they '
          'are shown as drafts only.',
    _ => reason.isEmpty ? 'The server did not state a reason.' : reason,
  };

  String _toneClass(String tone) => switch (tone) {
    'yes' => 's4-badge s4-badge--pass',
    'no' => 's4-badge s4-badge--muted',
    _ => 's4-badge s4-badge--warn',
  };

  Component _ladder(List<_LadderStep> steps) => div(
    classes: 's5-ladder',
    [
      for (final step in steps)
        div(classes: 's5-ladder__row', [
          span(classes: 's5-ladder__label', [Component.text(step.label)]),
          span(classes: _toneClass(step.tone), [Component.text(step.value)]),
        ]),
    ],
  );

  /// The four statuses for a row of the versioned question table.
  List<_LadderStep> _previewSteps(PreviewItem item, QuestionnairePreview preview) {
    final source = item.source == null || item.source!.isEmpty
        ? 'the versioned question table'
        : item.source!;
    return [
      _LadderStep(
        'Generated',
        item.questionVersion.isEmpty
            ? 'no version recorded'
            : 'version ${item.questionVersion}',
        item.questionVersion.isEmpty ? 'unknown' : 'yes',
      ),
      // The preview endpoint does not join the owner-review table, so the
      // review state is genuinely unknown here. It is not "not reviewed".
      _LadderStep(
        'Reviewed by you',
        item.objectiveAuthority == null || item.objectiveAuthority!.isEmpty
            ? 'not reported by this endpoint'
            : item.objectiveAuthority!,
        item.objectiveAuthority == null || item.objectiveAuthority!.isEmpty
            ? 'unknown'
            : 'yes',
      ),
      _LadderStep(
        'Scientifically accepted',
        item.accepted ? 'accepted' : 'not accepted',
        item.accepted ? 'yes' : 'no',
      ),
      _LadderStep(
        'Published or fielded',
        preview.publicationAuthorized || preview.fieldingAuthorized
            ? 'authorised'
            : 'not authorised',
        preview.publicationAuthorized || preview.fieldingAuthorized
            ? 'yes'
            : 'no',
      ),
      _LadderStep('Source table', source, 'no'),
    ];
  }

  /// The four statuses for a persisted Direct-QG candidate.
  List<_LadderStep> _candidateSteps(QgCandidate candidate) => [
    _LadderStep(
      'Generated',
      candidate.candidateState.isEmpty
          ? 'no state recorded'
          : candidate.candidateState,
      candidate.candidateState.isEmpty ? 'unknown' : 'yes',
    ),
    _LadderStep(
      'Reviewed by you',
      candidate.review.reviewed
          ? '${candidate.review.decision}'
          : 'not reviewed yet',
      candidate.review.reviewed ? 'yes' : 'unknown',
    ),
    _LadderStep(
      'Scientifically accepted',
      candidate.scientificallyAccepted ? 'accepted' : 'not accepted',
      candidate.scientificallyAccepted ? 'yes' : 'no',
    ),
    _LadderStep(
      'Published or fielded',
      candidate.fieldingAuthorized ? 'fielding authorised' : 'not authorised',
      candidate.fieldingAuthorized ? 'yes' : 'no',
    ),
    _LadderStep(
      'Execution',
      candidate.isSimulated
          ? 'simulated — no provider call'
          : (candidate.dispatched ? 'live, run ${candidate.runId}' : 'no run'),
      candidate.isSimulated || !candidate.dispatched ? 'unknown' : 'yes',
    ),
  ];

  Component _questionCard(PreviewItem item, int position, QuestionnairePreview preview) =>
      section(
        classes: 'panel asw-inline',
        [
          div(classes: 'panel__body stack stack--sm', [
            div(classes: 's4-row', [
              span(classes: 's4-badge', [Component.text('Q${position + 1}')]),
              span(classes: 's4-badge', [
                Component.text(item.accepted ? 'Accepted' : 'Draft'),
              ]),
              span(
                classes: 'sr-muted',
                [Component.text('objective ${item.objectiveId}')],
              ),
            ]),
            p(classes: 's4-question', [Component.text(item.question)]),
            div(classes: 's4-options', [
              for (final option in item.options)
                div(classes: 's4-option', [
                  span(classes: 's4-option__code', [Component.text(option.code)]),
                  span(classes: 's4-option__label', [
                    Component.text(option.label),
                  ]),
                ]),
            ]),
            if (item.objectiveText.isNotEmpty)
              p(classes: 'sr-muted', [Component.text(item.objectiveText)]),
            _ladder(_previewSteps(item, preview)),
          ]),
        ],
      );

  Component _candidateCard(QgCandidate candidate, int position) => section(
    classes: 'panel asw-inline',
    [
      div(classes: 'panel__body stack stack--sm', [
        div(classes: 's4-row', [
          span(classes: 's4-badge', [Component.text('C${position + 1}')]),
          span(classes: 's4-badge s4-badge--muted', [
            Component.text('not in this preview'),
          ]),
          span(classes: 's4-badge s4-badge--objective', [
            Component.text(
              candidate.objectiveId.isEmpty ? 'no objective' : candidate.objectiveId,
            ),
          ]),
        ]),
        p(classes: 's4-question', [Component.text(candidate.question)]),
        div(classes: 's4-options', [
          for (final option in candidate.options)
            div(classes: 's4-option', [
              span(classes: 's4-option__code', [Component.text(option.code)]),
              span(classes: 's4-option__label', [Component.text(option.label)]),
            ]),
        ]),
        p(classes: 'sr-muted', [
          Component.text(
            'Measurement ${candidate.measurementId ?? 'not recorded'} @ '
            '${candidate.measurementVersion ?? 'not recorded'} · candidate '
            '${candidate.candidateId}',
          ),
        ]),
        _ladder(_candidateSteps(candidate)),
      ]),
    ],
  );

  @override
  Component build(BuildContext context) {
    if (_loading) {
      return section(
        classes: 'panel asw-inline',
        [
          div(
            classes: 'panel__body',
            [p(classes: 'body', [Component.text('Reading the preview…')])],
          ),
        ],
      );
    }
    if (_error != null) {
      return section(
        classes: 'panel asw-inline',
        [
          div(classes: 'panel__body stack stack--sm', [
            p(classes: 'body', [Component.text(_error!)]),
            button(
              classes: 'sr-button',
              events: events(onClick: _load),
              [Component.text('Retry')],
            ),
          ]),
        ],
      );
    }
    final preview = _preview!;
    return section(
      classes: 'stack stack--md',
      [
        section(
          classes: 'panel asw-inline',
          [
            div(classes: 'panel__body stack stack--sm', [
              h2([Component.text('Questionnaire preview')]),
              div(classes: 's4-row', [
                span(classes: 's4-badge', [
                  Component.text(
                    preview.isAvailable ? 'DRAFT' : preview.status,
                  ),
                ]),
                if (preview.confirmationId != null)
                  span(
                    classes: 'sr-muted',
                    [Component.text('confirmation ${preview.confirmationId}')],
                  ),
                if (preview.assessmentRevision != null)
                  span(
                    classes: 'sr-muted',
                    [
                      Component.text(
                        'revision ${preview.assessmentRevision}',
                      ),
                    ],
                  ),
              ]),
              p(classes: 'sr-muted', [
                Component.text(_reasonText(preview.reason)),
              ]),
              // Asserted, not assumed: a true value here would be a real change
              // in authority and must be visible rather than silent.
              if (preview.fieldingAuthorized || preview.publicationAuthorized)
                p(classes: 's4-blocked', [
                  Component.text(
                    'The server reports fielding or publication authority. This '
                    'preview is not a fielding surface — stop and review the '
                    'authority before proceeding.',
                  ),
                ]),
            ]),
          ],
        ),
        if (preview.items.isEmpty)
          section(
            classes: 'panel asw-inline',
            [
              div(classes: 'panel__body', [
                p(classes: 'body', [
                  Component.text(
                    'There are no questions to preview. No sample question is '
                    'shown in place of a real one.',
                  ),
                ]),
              ]),
            ],
          )
        else
          for (var index = 0; index < preview.items.length; index++)
            _questionCard(preview.items[index], index, preview),

        // -- Generated candidates, explicitly excluded from the preview -------
        section(
          classes: 'panel asw-inline',
          [
            div(classes: 'panel__body stack stack--sm', [
              h3([Component.text('Generated candidates')]),
              p(classes: 'sr-muted', [
                Component.text(
                  'These questions were generated by Direct-QG and stored in the '
                  'candidate table. The preview above is assembled from the '
                  'versioned question table, so these candidates are not part of '
                  'it. They are shown here so a generated question is never '
                  'mistaken for a previewed or fielded one.',
                ),
              ]),
            ]),
          ],
        ),
        if (_candidateError != null)
          section(
            classes: 'panel asw-inline',
            [
              div(classes: 'panel__body', [
                p(classes: 's4-blocked', [Component.text(_candidateError!)]),
              ]),
            ],
          )
        else if (_candidates.isEmpty)
          section(
            classes: 'panel asw-inline',
            [
              div(classes: 'panel__body', [
                p(classes: 'body', [
                  Component.text(
                    'No question candidate has been generated for this '
                    'assessment.',
                  ),
                ]),
              ]),
            ],
          )
        else
          for (var index = 0; index < _candidates.length; index++)
            _candidateCard(_candidates[index], index),

        section(
          classes: 'panel asw-inline',
          [
            div(classes: 'panel__body', [
              p(classes: 'sr-muted', [
                Component.text(
                  'This is a draft preview. It creates no customer response, '
                  'starts no session and authorises no fielding.',
                ),
              ]),
            ]),
          ],
        ),
      ],
    );
  }
}
