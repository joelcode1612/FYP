/// Entrepreneur core flows for the PROJECT1 UI/UX prototype (V4):
/// WF-03 assessment workspace, WF-04 M2 questionnaire, WF-05 business
/// understanding and confirmation.
///
/// All data is fictional/sample. Confirmation is simulated and persists
/// nothing (V4 §3 WF-05, §5 rules #4/#5/#10).
library;

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'prototype_data.dart';
import 'prototype_ui.dart';

// ---------------------------------------------------------------------------
// WF-03 — Assessment creation and workspace
// ---------------------------------------------------------------------------

class AssessmentPage extends StatefulComponent {
  const AssessmentPage({super.key});

  @override
  State<AssessmentPage> createState() => _AssessmentPageState();
}

class _AssessmentPageState extends State<AssessmentPage> {
  String _name = 'Artisan Brew Corner Lot';
  bool _areaSelected = false;

  @override
  Component build(BuildContext context) {
    return ProtoShell(
      title: 'Café assessment workspace',
      eyebrow: 'WF-03 · Entrepreneur',
      currentRoute: '/prototype/wf-03',
      child: div(classes: 'proto-stack', [
        ProtoCard(
          title: 'Working café name',
          child: div(classes: 'proto-inline', [
            input(
              type: InputType.text,
              attributes: {
                'value': _name,
                'aria-label': 'Working café name',
                'placeholder': 'Working café name',
              },
              events: events<String>(onInput: (v) => setState(() => _name = v)),
            ),
            ProtoBadge('Draft', tone: 'info'),
          ]),
        ),
        div(classes: 'proto-grid proto-grid--3', [
          ProtoStat(
            label: 'M2 answers',
            value: '0 / 21',
            note: 'Not started',
          ),
          ProtoStat(
            label: 'Site / study area',
            value: _areaSelected ? 'Selected' : 'Not selected',
            note: 'Kept separate from M2 answers',
          ),
          ProtoStat(
            label: 'Confirmation',
            value: 'None',
            note: 'Simulated only',
          ),
        ]),
        ProtoCard(
          title: 'Location / study area',
          badge: _areaSelected ? 'SELECTED' : 'NONE',
          badgeTone: _areaSelected ? 'info' : 'neutral',
          child: div(classes: 'proto-stack', [
            ProtoNote(
              'The selected area is represented separately from M2 answers '
              'until the interface is approved. Selecting an area does NOT '
              'produce a geographic demand score.',
              tone: 'warn',
            ),
            div(classes: 'proto-inline', [
              ProtoButton(
                _areaSelected ? 'Clear area' : 'Select a fictional study area',
                variant: 'secondary',
                onClick: () => setState(() => _areaSelected = !_areaSelected),
              ),
              if (_areaSelected)
                ProtoBadge('Fictional District A · district-level', tone: 'info'),
            ]),
          ]),
        ),
        ProtoCard(
          title: 'Draft assessments',
          child: div(classes: 'proto-list', [
            _draft('Artisan Brew Corner Lot', 'In progress · M2 not started', true),
            _draft('Riverside Coffee Bar', 'In progress · M2 8 / 21', false),
            _draft('Campus Kiosk', 'Draft · no area', false),
          ]),
        ),
        div(classes: 'proto-inline', [
          ProtoButton('Continue to M2 questionnaire', href: '/prototype/wf-04'),
          ProtoButton('Create new assessment', variant: 'secondary', onClick: () {}),
        ]),
      ]),
    );
  }

  Component _draft(String name, String meta, bool active) => div(
    classes: active ? 'proto-row proto-row--active' : 'proto-row',
    [
      span(classes: 'proto-row__label', [Component.text(name)]),
      span(classes: 'proto-row__value', [Component.text(meta)]),
      if (active) ProtoBadge('Current', tone: 'info'),
    ],
  );
}

// ---------------------------------------------------------------------------
// WF-04 — Entrepreneur M2 questionnaire
// ---------------------------------------------------------------------------

class M2Page extends StatefulComponent {
  const M2Page({super.key});

  @override
  State<M2Page> createState() => _M2PageState();
}

class _M2PageState extends State<M2Page> {
  final Map<String, String> _answers = {};
  final Map<String, Set<String>> _multi = {};
  bool _showErrors = false;
  bool _submitted = false;

  @override
  void initState() {
    super.initState();
    _resetToSamples();
  }

  void _resetToSamples() {
    _answers.clear();
    _multi.clear();
    for (final item in kM2AnswerItems) {
      if (item.type == 'multi') {
        _multi[item.id] = item.sample
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toSet();
      } else {
        _answers[item.id] = item.sample;
      }
    }
    _showErrors = false;
    _submitted = false;
  }

  bool _answered(M2Item item) {
    if (item.type == 'multi') return (_multi[item.id] ?? {}).isNotEmpty;
    return (_answers[item.id] ?? '').trim().isNotEmpty;
  }

  int get _answeredCount => kM2AnswerItems.where(_answered).length;

  List<M2Item> get _missingRequired =>
      kM2AnswerItems.where((i) => i.required && !_answered(i)).toList();

  @override
  Component build(BuildContext context) {
    final sections = <String>[];
    for (final item in kM2AnswerItems) {
      if (!sections.contains(item.section)) sections.add(item.section);
    }

    return ProtoShell(
      title: 'Entrepreneur M2 questionnaire',
      eyebrow: 'WF-04 · Working design (vDRAFT.0)',
      currentRoute: '/prototype/wf-04',
      child: div(classes: 'proto-stack', [
        ProtoNote(
          'Working design: exact wording, options and routing require '
          'scientific finalization by WS-QNR-FINAL-01. Answers are versioned '
          'sample inputs, not fielded research.',
          tone: 'warn',
        ),
        ProtoCard(
          title: 'Progress',
          child: div(classes: 'proto-stack', [
            ProtoStat(
              label: 'Answered',
              value: '$_answeredCount / ${kM2AnswerItems.length}',
              note: '21 answer fields + 2 review actions',
            ),
            div(classes: 'proto-progress', [
              div(
                classes: 'proto-progress__bar',
                attributes: {'style': 'width:${(_answeredCount / kM2AnswerItems.length * 100).round()}%'},
                [],
              ),
            ]),
            div(classes: 'proto-inline', [
              ProtoButton('Reset to sample inputs', variant: 'secondary', onClick: () {
                setState(_resetToSamples);
              }),
              ProtoButton('Clear all answers (demo)', variant: 'danger', onClick: () {
                setState(() {
                  for (final item in kM2AnswerItems) {
                    if (item.type == 'multi') {
                      _multi[item.id] = {};
                    } else {
                      _answers[item.id] = '';
                    }
                  }
                  _submitted = false;
                });
              }),
            ]),
          ]),
        ),
        for (final section in sections)
          ProtoCard(
            title: section,
            child: div(classes: 'proto-stack', [
              for (final item in kM2AnswerItems.where((i) => i.section == section))
                _item(item),
            ]),
          ),
        ProtoCard(
          title: 'Review & confirmation actions',
          badge: 'SIMULATED',
          badgeTone: 'warn',
          child: div(classes: 'proto-stack', [
            for (final action in kM2Actions)
              div(classes: 'proto-action', [
                ProtoBadge(action.id, tone: 'neutral'),
                span(classes: 'proto-action__text', [Component.text(action.prompt)]),
              ]),
          ]),
        ),
        if (_showErrors && _missingRequired.isNotEmpty)
          ProtoNote(
            'Required answers missing: '
            '${_missingRequired.map((i) => i.id).join(', ')}. '
            'Complete them before continuing. Optional answers are never '
            'treated as zero.',
            tone: 'danger',
          ),
        if (_submitted)
          ProtoNote(
            'A versioned set of M2 answers is available for Business '
            'Understanding (version vDRAFT.0, sample inputs).',
            tone: 'success',
          ),
        div(classes: 'proto-inline', [
          ProtoButton('Continue to Business Understanding', onClick: () {
            setState(() {
              _showErrors = true;
              _submitted = _missingRequired.isEmpty;
            });
          }),
          if (_submitted)
            ProtoButton('Open Business Understanding', href: '/prototype/wf-05'),
        ]),
      ]),
    );
  }

  Component _item(M2Item item) {
    final answered = _answered(item);
    return div(classes: 'proto-item', [
      div(classes: 'proto-item__head', [
        span(classes: 'proto-item__id', [Component.text(item.id)]),
        span(classes: 'proto-item__prompt', [Component.text(item.prompt)]),
        if (item.required)
          ProtoBadge('Required', tone: 'warn')
        else
          ProtoBadge('Optional', tone: 'neutral'),
        if (!answered && !item.required)
          span(classes: 'proto-muted', [Component.text('Not provided')]),
      ]),
      if (item.type == 'text')
        input(
          type: InputType.text,
          attributes: {
            'value': _answers[item.id] ?? '',
            'aria-label': item.prompt,
            'placeholder': 'Type your answer',
          },
          events: events<String>(onInput: (v) => setState(() => _answers[item.id] = v)),
        )
      else if (item.type == 'multi')
        div(classes: 'proto-chips', [
          for (final opt in item.options)
            _chip(
              opt,
              (_multi[item.id] ?? {}).contains(opt),
              () => setState(() {
                final set = _multi.putIfAbsent(item.id, () => {});
                if (set.contains(opt)) {
                  set.remove(opt);
                } else {
                  set.add(opt);
                }
              }),
            ),
        ])
      else
        div(classes: 'proto-chips', [
          for (final opt in item.options)
            _chip(
              opt,
              _answers[item.id] == opt,
              () => setState(() => _answers[item.id] = opt),
            ),
        ]),
    ]);
  }

  Component _chip(String label, bool selected, void Function() onTap) => button(
    classes: selected ? 'proto-chip proto-chip--on' : 'proto-chip',
    events: events(onClick: onTap),
    [Component.text(label)],
  );
}

// ---------------------------------------------------------------------------
// WF-05 — Business understanding and confirmation
// ---------------------------------------------------------------------------

class UnderstandingPage extends StatefulComponent {
  const UnderstandingPage({super.key});

  @override
  State<UnderstandingPage> createState() => _UnderstandingPageState();
}

class _UnderstandingPageState extends State<UnderstandingPage> {
  int? _selected;
  String _primaryCustomer = 'University students';
  bool _acknowledged = false;
  bool _confirmed = false;
  bool _outdated = false;
  bool _contradiction = false;
  bool _authorized = false;

  void _editPrimaryCustomer(String value) {
    setState(() {
      _primaryCustomer = value;
      _outdated = _confirmed || _acknowledged;
      _confirmed = false;
      _acknowledged = false;
    });
  }

  @override
  Component build(BuildContext context) {
    final selected = _selected != null ? kBusinessStatements[_selected!] : null;

    return ProtoShell(
      title: 'Business understanding and confirmation',
      eyebrow: 'WF-05 · Entrepreneur',
      currentRoute: '/prototype/wf-05',
      child: div(classes: 'proto-stack', [
        ProtoNote(
          'Confirmation is simulated. No real persistence, authorization or '
          'confirmation endpoint exists.',
          tone: 'warn',
        ),
        if (_outdated)
          ProtoNote(
            'Your previous confirmation is now OUTDATED because a relevant '
            'answer changed. Re-review before confirming again.',
            tone: 'danger',
          ),
        if (_contradiction)
          ProtoNote(
            'Contradictory answers detected: the concept description mentions '
            '"university students" but the primary customer group is '
            '"Office workers". Resolve this before confirmation.',
            tone: 'danger',
          ),
        ProtoCard(
          title: 'How PROJECT1 understands your café',
          child: div(classes: 'proto-stack', [
            for (var i = 0; i < kBusinessStatements.length; i++)
              button(
                classes: _selected == i
                    ? 'proto-statement proto-statement--on'
                    : 'proto-statement',
                events: events(onClick: () => setState(() => _selected = i)),
                [
                  span(classes: 'proto-statement__text', [
                    Component.text(kBusinessStatements[i].text),
                  ]),
                  span(classes: 'proto-statement__cta', [
                    Component.text('Why?'),
                  ]),
                ],
              ),
            span(classes: 'proto-muted', [
              Component.text('Select a statement to inspect its source answer.'),
            ]),
          ]),
        ),
        if (selected != null)
          ProtoCard(
            title: 'Why does the system say this?',
            badge: 'SOURCE TRACE',
            badgeTone: 'info',
            child: div(classes: 'proto-list', [
              _kv('Statement', selected.text),
              _kv('Source question', selected.sourceIds.join(', ')),
              _kv('Original answer', selected.originalAnswer),
              _kv('Interpreted meaning', selected.meaning),
              _kv('Answer version', 'vDRAFT.0 (sample input)'),
              _kv('Limitations', selected.limitations),
            ]),
          ),
        ProtoCard(
          title: 'Correct the underlying answer',
          child: div(classes: 'proto-stack', [
            span(classes: 'proto-muted', [
              Component.text(
                'Primary customer group (from M2-07). Editing it regenerates '
                'the description and makes any confirmation outdated.',
              ),
            ]),
            div(classes: 'proto-chips', [
              for (final opt in const [
                'University students',
                'Office workers',
                'Local residents',
                'Mixed',
              ])
                button(
                  classes: _primaryCustomer == opt
                      ? 'proto-chip proto-chip--on'
                      : 'proto-chip',
                  events: events(onClick: () => _editPrimaryCustomer(opt)),
                  [Component.text(opt)],
                ),
            ]),
            ProtoButton(
              _contradiction
                  ? 'Remove contradiction (demo)'
                  : 'Introduce contradictory answer (demo)',
              variant: 'secondary',
              onClick: () => setState(() {
                _contradiction = !_contradiction;
                _primaryCustomer = _contradiction ? 'Office workers' : 'University students';
              }),
            ),
          ]),
        ),
        ProtoCard(
          title: 'Review and confirm',
          child: div(classes: 'proto-stack', [
            div(classes: 'proto-action', [
              ProtoBadge('OP-A', tone: 'info'),
              span(classes: 'proto-action__text', [
                Component.text(
                  'Acknowledge my answers — confirms the information entered '
                  'was intentional. Does NOT authorize downstream reliance.',
                ),
              ]),
              ProtoButton('Acknowledge', variant: 'secondary', onClick: () {
                setState(() {
                  _acknowledged = true;
                  _outdated = false;
                });
              }),
            ]),
            div(classes: 'proto-action', [
              ProtoBadge('OP-B', tone: 'warn'),
              span(classes: 'proto-action__text', [
                Component.text(
                  'Confirm my proposed business plan — only for an authorized '
                  'actor. Simulated; proves no demand, viability or ownership.',
                ),
              ]),
              ProtoButton(
                _confirmed ? 'Confirmed (simulated)' : 'Confirm plan',
                variant: _contradiction ? 'disabled' : 'primary',
                onClick: _contradiction
                    ? null
                    : () => setState(() {
                        if (!_authorized) return;
                        _confirmed = true;
                        _outdated = false;
                      }),
              ),
            ]),
            div(classes: 'proto-inline', [
              button(
                classes: _authorized
                    ? 'proto-chip proto-chip--on'
                    : 'proto-chip',
                events: events(onClick: () => setState(() => _authorized = !_authorized)),
                [Component.text('Simulate authorized actor')],
              ),
            ]),
            if (!_authorized)
              ProtoNote(
                'OP-B is unavailable until an authorized actor is simulated. '
                'In production this requires accepted confirmation rules.',
                tone: 'warn',
              ),
            if (_acknowledged)
              ProtoNote('Acknowledged. This is not an authorized plan confirmation.', tone: 'info'),
            if (_confirmed)
              ProtoNote(
                'Business plan confirmed (simulated). It proves no customer '
                'demand, business viability or legal ownership.',
                tone: 'success',
              ),
            if (_contradiction)
              ProtoNote(
                'Confirmation is blocked while contradictory answers remain.',
                tone: 'danger',
              ),
          ]),
        ),
        ProtoButton('Continue to evidence & analysis', href: '/prototype/wf-08'),
      ]),
    );
  }

  Component _kv(String k, String v) => div(classes: 'proto-row', [
    span(classes: 'proto-row__label', [Component.text(k)]),
    span(classes: 'proto-row__value', [Component.text(v)]),
  ]);
}
