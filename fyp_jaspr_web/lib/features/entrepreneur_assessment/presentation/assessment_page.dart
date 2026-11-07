import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../application/assessment_view_model.dart';
import '../domain/assessment_draft.dart';
import '../domain/m2_questions.dart';
import '../domain/review_notes.dart';

const _steps = <String>[
  'Business profile',
  'Business idea & customers',
  'Finances & operations',
  'Evidence & concerns',
  'Review',
];

/// Hydratable SSR island. No server-owned user state, no form submission.
@client
class AssessmentIsland extends StatelessComponent {
  const AssessmentIsland({super.key});

  @override
  Component build(BuildContext context) {
    return ProviderScope(child: const AssessmentPage());
  }
}

class AssessmentPage extends StatelessComponent {
  const AssessmentPage({super.key});

  @override
  Component build(BuildContext context) {
    final draft = context.watch(assessmentProvider);
    final vm = context.read(assessmentProvider.notifier);
    return div(classes: 'm2-ui site-shell', [
      _header(),
      main_(classes: 'workspace', [
        div(classes: 'eyebrow', [text('PROJECT1 · ENTREPRENEUR WORKSPACE · UI-ONLY CANDIDATE')]),
        h1([text(draft.page == 4 ? 'Review your café plan' : 'Tell us about your café')]),
        p(classes: 'subtitle', [text(draft.page == 4
            ? 'Review your declared information and illustrative source-linked notes.'
            : 'Share your business plans in your own words and through short structured questions.')]),
        div(classes: 'notice', [text('Prototype only · No submission, evidence admission, or confirmed report generated')]),
        _stepper(draft, vm),
        div(classes: 'layout', [
          div(classes: 'main-panel', [
            if (draft.page < 4) ...[
              _intro(draft.page),
              for (final q in m2Questions.where((q) => q.page == draft.page))
                _question(q, draft, vm),
              if (draft.page == 1) _concernField(draft, vm),
            ] else ...[
              _review(draft, vm),
            ],
            _bottomNavigation(draft, vm),
          ]),
          _sidePanel(draft),
        ]),
      ]),
      footer(classes: 'footer', [
        text('Sitewise · Project1 · M2 CAND-02 UI prototype · Local browser state only'),
      ]),
    ]);
  }

  Component _header() => header(classes: 'topbar', [
    div(classes: 'logo', [span(classes: 'logo-mark', [text('S')]), text('Sitewise')]),
    nav(classes: 'toplinks', [
      span([text('Overview')]),
      span(classes: 'active', [text('My Assessment')]),
      span([text('Reports')]),
      span([text('Evidence')]),
    ]),
    span(classes: 'workspace-label', [text('Entrepreneur workspace')]),
  ]);

  Component _stepper(AssessmentDraft draft, AssessmentViewModel vm) =>
      div(classes: 'stepper', [
        for (var i = 0; i < _steps.length; i++)
          button(classes: 'step ${draft.page == i ? 'selected' : ''}',
            onClick: () => vm.changePage(i),
            attributes: {'type': 'button', 'aria-current': draft.page == i ? 'step' : 'false'}, [
            span(classes: 'step-number', [text('${i + 1}')]),
            span([text(_steps[i])]),
          ]),
      ]);

  Component _intro(int page) => div(classes: 'intro', [
    h2([text(const ['Your background', 'Your café idea', 'Your finances and assumptions', 'Your evidence and unanswered questions'][page])]),
    p([text(const [
      'Tell us your role, background and preferred operating setting.',
      'Describe your concept and the intended people you hope to serve.',
      'Share your intended financial and operational assumptions. Estimates are not calculations.',
      'Tell us what evidence you report holding and what you still need to learn.',
    ][page])]),
  ]);

  Component _question(M2Question q, AssessmentDraft draft, AssessmentViewModel vm) {
    return section(classes: 'question-card', [
      div(classes: 'question-head', [
        div([span(classes: 'question-id', [text(q.id)]),
          h3([text(q.label)])]),
        span(classes: 'tag', [text(q.kind == M2Kind.held
            ? 'Held' : q.required ? 'Required · Candidate' :
            q.kind == M2Kind.description ? 'Recommended' : 'Optional')]),
      ]),
      if (q.note != null) p(classes: 'help', [text(q.note!)]),
      if (q.kind == M2Kind.held)
        div(classes: 'held', [text('This question is preserved in the 23-ID inventory but is not answerable in this UI prototype pending the existing review decisions.')])
      else if (q.kind == M2Kind.description)
        textarea(classes: 'long-input',
          value: draft.description,
          placeholder: 'Write your café idea in your own words. A short relevant description is acceptable.',
          rows: 4, onInput: vm.setDescription, [])
      else ...[
        div(classes: 'choice-grid', [
          for (final option in q.options)
            _choiceButton(
              option,
              selected: q.kind == M2Kind.single
                  ? draft.single(q.id) == option
                  : draft.multi(q.id).contains(option),
              onTap: () => q.kind == M2Kind.single
                  ? vm.setSingle(q.id, option)
                  : vm.toggleMulti(q.id, option),
            ),
        ]),
        if (q.kind == M2Kind.multi && q.maximum != null)
          p(classes: 'help', [text('Select up to ${q.maximum} choices.')]),
        if (q.options.contains('Other') &&
            (draft.single(q.id) == 'Other' || draft.multi(q.id).contains('Other')))
          input(classes: 'other-input',
            value: draft.otherDetails[q.id] ?? '',
            placeholder: 'Describe your Other selection (your own words)',
            onInput: (value) => vm.setOtherDetail(q.id, value), []),
        if (q.id == 'M2-07' && draft.multi('M2-07').isNotEmpty)
          div(classes: 'primary-box', [
            h4([text('Which is your primary intended customer group?')]),
            div(classes: 'choice-grid', [
              for (final option in draft.multi('M2-07'))
                _choiceButton(option,
                  selected: draft.primaryCustomer == option,
                  onTap: () => vm.setPrimaryCustomer(option)),
            ]),
          ]),
      ],
    ]);
  }

  Component _choiceButton(String value, {required bool selected, required void Function() onTap}) =>
      button(classes: 'choice ${selected ? 'chosen' : ''}',
        onClick: onTap,
        attributes: {'type': 'button', 'aria-pressed': selected ? 'true' : 'false'}, [
          span(classes: 'choice-icon', [text(selected ? '✓' : '○')]),
          span([text(value)]),
        ]);

  Component _concernField(AssessmentDraft draft, AssessmentViewModel vm) =>
      section(classes: 'question-card', [
        span(classes: 'question-id', [text('EXPLORATORY NOTE · NOT AN M2 ANSWER FIELD')]),
        h3([text('What are you most unsure or concerned about right now?')]),
        p(classes: 'help', [text('Optional entrepreneur-authored context. It is not silently added to M2-17, verified evidence, or the report.')]),
        textarea(classes: 'long-input',
          rows: 3,
          placeholder: 'For example, a question you want the Business Understanding to investigate.',
          value: draft.entrepreneurConcern,
          onInput: vm.setEntrepreneurConcern, []),
      ]);

  Component _review(AssessmentDraft draft, AssessmentViewModel vm) {
    final notes = makeDemoReviewNotes(draft);
    return div(classes: 'review', [
      div(classes: 'intro', [
        h2([text('Review your café plan')]),
        p([text('Your answers are entrepreneur declarations. No values are independently verified here.')]),
      ]),
      section(classes: 'review-block', [
        h3([text('Your original business description')]),
        p([text(draft.description.trim().isEmpty
            ? 'Not provided (recommended M2-04).' : draft.description)]),
        p(classes: 'source', [text('Source M2-04 · local draft revision ${draft.answerRevision}')]),
        if (draft.entrepreneurConcern.trim().isNotEmpty) ...[
          h4([text('Your own concern (exploratory note)')]),
          p([text(draft.entrepreneurConcern)]),
        ],
      ]),
      section(classes: 'review-block', [
        h3([text('Your key answers')]),
        for (final q in m2Questions)
          div(classes: 'answer-row', [
            span(classes: 'answer-key', [text(q.id)]),
            span(classes: 'answer-label', [text(q.label)]),
            span(classes: 'answer-value', [text(_answerLabel(q, draft))]),
          ]),
        div(classes: 'answer-row', [
          span(classes: 'answer-key', [text('M2-07 PRIMARY')]),
          span(classes: 'answer-label', [text('Primary intended customer')]),
          span(classes: 'answer-value', [text(draft.primaryCustomer.isEmpty ? 'Not selected' : draft.primaryCustomer)]),
        ]),
      ]),
      section(classes: 'review-block', [
        h3([text('Things worth checking next')]),
        p(classes: 'help', [text('Example deterministic source-based UI notes only. Not BDJ validation, verified external facts, critical risk ratings or admitted report claims.')]),
        if (notes.isEmpty)
          p([text('No demo rule matched the supplied answers. This does not establish that the business is viable.')]),
        for (final note in notes)
          article(classes: 'finding', [
            h4([text(note.title)]),
            p([strong([text('What you supplied: ')]), text(note.basis)]),
            p([strong([text('What is unknown: ')]), text(note.limitation)]),
            p([strong([text('Possible next step: ')]), text(note.nextAction)]),
            span(classes: 'source', [text('Source: ${note.sourceIds.join(', ')} · draft revision ${draft.answerRevision}')]),
          ]),
      ]),
      section(classes: 'review-block', [
        h3([text('M2-20 — Review your answers')]),
        p([text(draft.reviewed ? 'Review acknowledgement recorded in this browser demo.' : 'Review every applicable answer and its source status.')]),
        button(classes: 'primary-btn', onClick: vm.reviewDemo, [text('I reviewed my answers (demo)')]),
        h3([text('M2-21 — Confirm planned assumptions')]),
        p([text('Demo only: this does not perform AUTH12 authorization or persist a confirmation snapshot.')]),
        button(classes: 'primary-btn ${draft.reviewed ? '' : 'is-disabled'}',
          onClick: draft.reviewed ? vm.confirmDemo : null, [text('Confirm for demo only')]),
        if (draft.confirmedInDemo)
          p(classes: 'confirmed-text', [text('Local demonstration acknowledged. No authorization or report admission occurred.')]),
      ]),
    ]);
  }

  String _answerLabel(M2Question q, AssessmentDraft draft) {
    if (q.kind == M2Kind.held) return 'Held / not collected';
    if (q.kind == M2Kind.description) return draft.description.isEmpty ? 'Not supplied' : 'Original text above';
    final base = q.kind == M2Kind.multi ? draft.multi(q.id).join(', ') : draft.single(q.id);
    if (base.isEmpty) return 'Not answered';
    final other = draft.otherDetails[q.id];
    return other != null && other.isNotEmpty ? '$base (Other: $other)' : base;
  }

  Component _bottomNavigation(AssessmentDraft draft, AssessmentViewModel vm) =>
      div(classes: 'bottom-actions', [
        button(classes: 'secondary-btn',
          onClick: draft.page == 0 ? null : () => vm.changePage(draft.page - 1),
          [text('← Back')]),
        span(classes: 'help', [text('Draft stays only in this browser session.')]),
        if (draft.page < 4)
          button(classes: 'primary-btn',
            onClick: () => vm.changePage(draft.page + 1), [text('Continue →')])
        else
          button(classes: 'secondary-btn',
            onClick: () => vm.changePage(0), [text('Edit answers')]),
      ]);

  Component _sidePanel(AssessmentDraft draft) => aside(classes: 'side', [
    div(classes: 'sidebar-card', [
      h3([text('Why we ask this')]),
      p([text('Your original M2 responses define the proposed café and planning assumptions. We do not invent missing answers.')]),
    ]),
    div(classes: 'sidebar-card', [
      h3([text('Structured + your own words')]),
      p([text('Multiple-choice answers provide consistent fields; M2-04 and an optional concern note preserve entrepreneur-authored text.')]),
    ]),
    div(classes: 'sidebar-card', [
      h3([text('What happens after review?')]),
      p([text('The existing BDJ and Business Understanding workflow may later enrich context using authorized facts and identify overlooked concerns. This UI does not execute those engines.')]),
    ]),
    div(classes: 'sidebar-card', [
      h3([text('Authorization boundary')]),
      p([text('M2 CAND-02 is unapproved; A10 report claims remain unadmitted. No financial viability scoring or customer demand measurement.')]),
    ]),
  ]);
}
