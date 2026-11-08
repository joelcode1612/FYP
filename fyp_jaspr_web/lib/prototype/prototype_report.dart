/// Evidence, geography, report and customer-journey flows for the PROJECT1
/// UI/UX prototype (V4): WF-07, WF-08, WF-09, WF-10.
///
/// All customer figures and locations are fictional and marked as such. No
/// suitability score is issued (V4 §5 rules #6/#7/#8, §7 acceptance).
library;

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'prototype_data.dart';
import 'prototype_ui.dart';

// ---------------------------------------------------------------------------
// WF-07 — Geographic exploration
// ---------------------------------------------------------------------------
// Replaced by `lib/geo/geo_page.dart` (`GeoMapPage`) under directive
// `PROJECT1-JASPR-GEO-SAFE-INCREMENT-20261030-V3` (GEO-DEV-C01). The previous
// CSS-grid placeholder and its `_GeoPageState` were removed; the route
// `/prototype/wf-07` now renders the synthetic three-coordinate demonstrator.
// The real BC-05 teammate rental-selection feature is NOT modified here.
// ---------------------------------------------------------------------------
// WF-08 — Evidence and analysis
// ---------------------------------------------------------------------------

class EvidencePage extends StatelessComponent {
  const EvidencePage({super.key});

  @override
  Component build(BuildContext context) {
    return ProtoShell(
      title: 'Evidence and analysis',
      eyebrow: 'WF-08 · Entrepreneur',
      currentRoute: '/prototype/wf-08',
      child: div(classes: 'proto-stack', [
        ProtoNote(
          'This screen distinguishes what you plan, what external sources show, '
          'what customers report, and what remains unknown. It never invents '
          'benchmarks, demand estimates or suitability scores.',
          tone: 'info',
        ),
        div(classes: 'proto-grid proto-grid--2', [
          for (final c in kEvidenceCategories)
            ProtoCard(
              title: c.title,
              badge: c.status,
              badgeTone: c.status.contains('NOT') ? 'warn' : 'info',
              child: Component.text(c.detail),
            ),
        ]),
        ProtoCard(
          title: 'Example customer finding (FICTIONAL)',
          badge: 'FICTIONAL',
          badgeTone: 'warn',
          child: div(classes: 'proto-stack', [
            ProtoStat(
              label: 'Stated first-visit interest',
              value: '61%',
              note: 'n = 26 / 42 · denominator = 42 valid responses · vDRAFT.0',
            ),
            span(classes: 'proto-muted', [
              Component.text(
                'Every customer percentage is shown with its respondent count, '
                'valid denominator and questionnaire version. This is '
                'illustrative, not real research.',
              ),
            ]),
          ]),
        ),
        ProtoCard(
          title: 'Example unavailable finding',
          badge: 'NOT AVAILABLE',
          badgeTone: 'danger',
          child: div(classes: 'proto-stack', [
            span(classes: 'proto-muted', [
              Component.text(
                'Customer demand — NOT MEASURED. No approved customer responses '
                'exist yet (0 respondents). This is not the same as 0% demand.',
              ),
            ]),
          ]),
        ),
        ProtoButton('Open the R01–R12 report', href: '/prototype/wf-09'),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// WF-09 — Future customer-enriched Demand Suitability Report (R01–R12)
// ---------------------------------------------------------------------------

class ReportPageProto extends StatelessComponent {
  const ReportPageProto({super.key});

  String _tone(String status) {
    if (status == 'FICTIONAL') return 'warn';
    if (status == 'NOT_AVAILABLE') return 'danger';
    if (status == 'CONTEXT_ONLY') return 'info';
    return 'neutral';
  }

  @override
  Component build(BuildContext context) {
    return ProtoShell(
      title: 'Demand Suitability Report (R01–R12)',
      eyebrow: 'WF-09 · Future customer-enriched report',
      currentRoute: '/prototype/wf-09',
      child: div(classes: 'proto-stack', [
        ProtoNote(
          'FUTURE REPORT DEMONSTRATION. Customer figures are fictional and '
          'clearly marked. No suitability score or High/Medium/Low verdict is '
          'issued. This is not the postponed Early Report review.',
          tone: 'warn',
        ),
        ProtoCard(
          title: 'Structure preserved: R01–R12',
          badge: 'V4 WF-09',
          badgeTone: 'info',
          child: Component.text(
            'The report preserves the twelve controlled sections. Sections '
            'without supported findings explain why instead of showing a '
            'misleading zero.',
          ),
        ),
        for (final s in kReportSections)
          ProtoCard(
            title: '${s.id} · ${s.title}',
            badge: s.status,
            badgeTone: _tone(s.status),
            child: Component.text(s.body),
          ),
        ProtoCard(
          title: 'Reading the numbers',
          child: div(classes: 'proto-list', [
            _line('Stated interest', 'A customer saying they would likely visit is not a guaranteed visit.'),
            _line('Revenue', 'No revenue is projected. The report never converts interest into revenue.'),
            _line('Suitability', 'Not scored. Only BELOW_THRESHOLD, ON_TRACK, ABOVE_THRESHOLD, NO_BENCHMARK are permitted, and none is issued here.'),
            _line('Missing evidence', 'Shown as an explanation, never as zero.'),
          ]),
        ),
        ProtoButton('Review the audit trail', href: '/prototype/wf-12'),
      ]),
    );
  }

  Component _line(String k, String v) => div(classes: 'proto-row', [
    span(classes: 'proto-row__label', [Component.text(k)]),
    span(classes: 'proto-row__value', [Component.text(v)]),
  ]);
}

// ---------------------------------------------------------------------------
// WF-10 — Customer questionnaire journey
// ---------------------------------------------------------------------------

class CustomerPage extends StatefulComponent {
  const CustomerPage({super.key});

  @override
  State<CustomerPage> createState() => _CustomerPageState();
}

class _CustomerPageState extends State<CustomerPage> {
  final Map<String, String> _single = {};
  final Map<String, Set<String>> _multi = {};
  int _index = 0;
  bool _done = false;

  bool get _screenedOut => _single['Q01'] == 'No';

  List<CustomerQuestion> get _visible {
    final coffee = (_multi['Q03'] ?? {}).contains('Coffee');
    final pastries = (_multi['Q03'] ?? {}).contains('Pastries');
    return kCustomerQuestions.where((q) {
      if (q.id == 'Q07') return coffee;
      if (q.id == 'Q08') return pastries;
      return true;
    }).toList();
  }

  @override
  Component build(BuildContext context) {
    if (_screenedOut) {
      return ProtoShell(
        title: 'Customer questionnaire',
        eyebrow: 'WF-10 · Potential Customer',
        currentRoute: '/prototype/wf-10',
        child: div(classes: 'proto-stack', [
          ProtoNote(
            'Screened out — not eligible for this survey. A "No" screening '
            'answer is not treated as a negative response.',
            tone: 'warn',
          ),
          ProtoButton('Restart demonstration', onClick: () {
            setState(() {
              _single.clear();
              _multi.clear();
              _index = 0;
              _done = false;
            });
          }),
        ]),
      );
    }

    final visible = _visible;
    final q = visible[_index.clamp(0, visible.length - 1)];

    return ProtoShell(
      title: 'Customer questionnaire journey',
      eyebrow: 'WF-10 · Potential Customer',
      currentRoute: '/prototype/wf-10',
      child: div(classes: 'proto-stack', [
        ProtoNote(
          'Demonstration only. No respondents are recruited and no response is '
          'collected for real research. Questionnaire version is not '
          'fielding-approved.',
          tone: 'warn',
        ),
        ProtoCard(
          title: 'Progress',
          child: div(classes: 'proto-stack', [
            ProtoStat(
              label: 'Question',
              value: '${_index + 1} / ${visible.length}',
              note: 'Group: ${q.group}',
            ),
            div(classes: 'proto-progress', [
              div(
                classes: 'proto-progress__bar',
                attributes: {'style': 'width:${((_index + 1) / visible.length * 100).round()}%'},
                [],
              ),
            ]),
          ]),
        ),
        ProtoCard(
          title: q.id,
          badge: q.screening ? 'SCREENING' : 'ROUTED',
          badgeTone: q.screening ? 'info' : 'neutral',
          child: div(classes: 'proto-stack', [
            span(classes: 'proto-question', [Component.text(q.prompt)]),
            div(classes: 'proto-chips', [
              for (final opt in q.options)
                button(
                  classes: _selected(q, opt) ? 'proto-chip proto-chip--on' : 'proto-chip',
                  events: events(onClick: () => _pick(q, opt)),
                  [Component.text(opt)],
                ),
            ]),
            if (q.id == 'Q07' || q.id == 'Q08')
              span(classes: 'proto-muted', [
                Component.text(
                  'This question appears only because an earlier routing '
                  'answer made it applicable.',
                ),
              ]),
          ]),
        ),
        ProtoNote(
          'Uncertainty ("Not sure") and non-applicable answers are recorded '
          'as-is and are never converted to negative responses.',
          tone: 'info',
        ),
        div(classes: 'proto-inline', [
          if (_index > 0)
            ProtoButton('Back', variant: 'secondary', onClick: () {
              setState(() => _index -= 1);
            }),
          ProtoButton(
            _index >= visible.length - 1 ? 'Finish demonstration' : 'Next',
            onClick: () {
              setState(() {
                if (_index >= visible.length - 1) {
                  _done = true;
                } else {
                  _index += 1;
                }
              });
            },
          ),
        ]),
        if (_done)
          ProtoNote(
            'Demonstration complete. This is a simulated submission, not a '
            'real research response.',
            tone: 'success',
          ),
      ]),
    );
  }

  bool _selected(CustomerQuestion q, String opt) {
    if (q.multi) return (_multi[q.id] ?? {}).contains(opt);
    return _single[q.id] == opt;
  }

  void _pick(CustomerQuestion q, String opt) {
    setState(() {
      if (q.multi) {
        final set = _multi.putIfAbsent(q.id, () => {});
        if (set.contains(opt)) {
          set.remove(opt);
        } else {
          set.add(opt);
        }
      } else {
        _single[q.id] = opt;
      }
      // Re-clamp the index if routing removes a question.
      final len = _visible.length;
      if (_index >= len) _index = len - 1;
    });
  }
}
