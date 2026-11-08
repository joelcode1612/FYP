/// Shared shell and primitives for the PROJECT1 UI/UX prototype (V4).
///
/// This is deliberately separate from `lib/layouts/app_layout.dart`: the
/// existing shell models the Flutter app's entrepreneur/owner/admin roles,
/// while the V4 prototype models three different experiences (Entrepreneur,
/// Customer, Research Administrator) and twelve workflows. Keeping the
/// prototype in its own shell means the existing frontend is not overwritten.
library;

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'prototype_data.dart';

/// One entry in the prototype's workflow navigation.
class ProtoNavItem {
  final String route;
  final String label;

  const ProtoNavItem(this.route, this.label);
}

const List<ProtoNavItem> kPrototypeNav = [
  ProtoNavItem('/prototype', 'Home'),
  ProtoNavItem('/prototype/wf-01', '01 · Access'),
  ProtoNavItem('/prototype/wf-03', '03 · Assessment'),
  ProtoNavItem('/prototype/wf-04', '04 · M2'),
  ProtoNavItem('/prototype/wf-05', '05 · Understanding'),
  ProtoNavItem('/prototype/wf-06', '06 · Research'),
  ProtoNavItem('/prototype/wf-07', '07 · Geography'),
  ProtoNavItem('/prototype/wf-08', '08 · Evidence'),
  ProtoNavItem('/prototype/wf-09', '09 · Report'),
  ProtoNavItem('/prototype/wf-10', '10 · Customer'),
  ProtoNavItem('/prototype/wf-11', '11 · Admin'),
  ProtoNavItem('/prototype/wf-12', '12 · Audit'),
];

/// The prototype chrome: a persistent "fictional demonstration" banner, a
/// workflow nav, a page header and a footer disclaimer.
class ProtoShell extends StatelessComponent {
  final String title;
  final String eyebrow;
  final String currentRoute;
  final Component child;

  const ProtoShell({
    super.key,
    required this.title,
    required this.eyebrow,
    required this.currentRoute,
    required this.child,
  });

  @override
  Component build(BuildContext context) {
    return div(classes: 'proto-shell', [
      div(classes: 'proto-banner', [
        span(classes: 'proto-banner__dot', []),
        Component.text(
          'FICTIONAL DEMONSTRATION · PROJECT1 UI/UX Prototype V4 · '
          'not real research, not a backend, not production',
        ),
      ]),
      header(classes: 'proto-topbar', [
        a(href: '/prototype', classes: 'proto-brand', [
          Component.text('Sitewise'),
          span(classes: 'proto-brand__tag', [Component.text('Prototype V4')]),
        ]),
        nav(classes: 'proto-nav', [
          for (final item in kPrototypeNav)
            a(
              href: item.route,
              classes: item.route == currentRoute
                  ? 'proto-nav__link proto-nav__link--active'
                  : 'proto-nav__link',
              [Component.text(item.label)],
            ),
        ]),
      ]),
      div(classes: 'proto-main', [
        div(classes: 'proto-head', [
          span(classes: 'proto-eyebrow', [Component.text(eyebrow)]),
          h1([Component.text(title)]),
        ]),
        child,
      ]),
      footer(classes: 'proto-foot', [
        Component.text(
          'Prototype behaviour only. Not scientifically validated, not an '
          'implemented backend, not production-ready. Version $kPrototypeVersion.',
        ),
      ]),
    ]);
  }
}

/// A bordered panel with a title and an optional status badge.
class ProtoCard extends StatelessComponent {
  final String title;
  final String? badge;
  final String? badgeTone;
  final Component child;

  const ProtoCard({
    super.key,
    required this.title,
    required this.child,
    this.badge,
    this.badgeTone,
  });

  @override
  Component build(BuildContext context) {
    return section(classes: 'proto-card', [
      div(classes: 'proto-card__head', [
        h2(classes: 'proto-card__title', [Component.text(title)]),
        if (badge != null) ProtoBadge(badge!, tone: badgeTone ?? 'neutral'),
      ]),
      div(classes: 'proto-card__body', [child]),
    ]);
  }
}

/// Small status pill. Tone: neutral | info | warn | danger | success.
class ProtoBadge extends StatelessComponent {
  final String label;
  final String tone;

  const ProtoBadge(this.label, {super.key, this.tone = 'neutral'});

  @override
  Component build(BuildContext context) =>
      span(classes: 'proto-badge proto-badge--$tone', [Component.text(label)]);
}

/// A highlighted explanatory note.
class ProtoNote extends StatelessComponent {
  final String text;
  final String tone;

  const ProtoNote(this.text, {super.key, this.tone = 'info'});

  @override
  Component build(BuildContext context) =>
      div(classes: 'proto-note proto-note--$tone', [
        Component.text(text),
      ]);
}

/// A link-styled or button-styled action.
class ProtoButton extends StatelessComponent {
  final String label;
  final String? href;
  final void Function()? onClick;
  final String variant;

  const ProtoButton(
    this.label, {
    super.key,
    this.href,
    this.onClick,
    this.variant = 'primary',
  });

  @override
  Component build(BuildContext context) {
    final classes = 'proto-btn proto-btn--$variant';
    if (href != null) {
      return a(href: href!, classes: classes, [Component.text(label)]);
    }
    return button(
      classes: classes,
      events: events(onClick: onClick),
      [Component.text(label)],
    );
  }
}

/// A simple labelled metric.
class ProtoStat extends StatelessComponent {
  final String label;
  final String value;
  final String? note;

  const ProtoStat({
    super.key,
    required this.label,
    required this.value,
    this.note,
  });

  @override
  Component build(BuildContext context) => div(classes: 'proto-stat', [
    span(classes: 'proto-stat__label', [Component.text(label)]),
    span(classes: 'proto-stat__value', [Component.text(value)]),
    if (note != null) span(classes: 'proto-stat__note', [Component.text(note!)]),
  ]);
}

// ---------------------------------------------------------------------------
// Home / account access (WF-01, WF-02)
// ---------------------------------------------------------------------------

class PrototypeHome extends StatelessComponent {
  const PrototypeHome({super.key});

  @override
  Component build(BuildContext context) {
    return ProtoShell(
      title: 'PROJECT1 UI/UX prototype',
      eyebrow: 'Overview · WF-01 account access & WF-02 workspace',
      currentRoute: '/prototype',
      child: div(classes: 'proto-stack', [
        ProtoNote(
          'Account access and permissions are simulated. No authentication, '
          'persistence or authorization endpoint exists in this prototype.',
          tone: 'warn',
        ),
        div(classes: 'proto-grid proto-grid--3', [
          _roleCard(
            'Prospective Entrepreneur',
            'Creates a café assessment, completes M2, reviews the business '
                'description, explores evidence and views the report.',
            '/prototype/wf-03',
          ),
          _roleCard(
            'Potential Customer',
            'Answers a separate customer market-validation questionnaire. '
                'Visibly separate from the entrepreneur journey.',
            '/prototype/wf-10',
          ),
          _roleCard(
            'Research Administrator',
            'Reviews questionnaire versions, research readiness, evidence '
                'conditions and audit information.',
            '/prototype/wf-11',
          ),
        ]),
        ProtoCard(
          title: 'The twelve workflows',
          child: div(classes: 'proto-wf-list', [
            _wf('WF-01', 'Account access (simulated)', '/prototype/wf-01'),
            _wf('WF-02', 'Home / workspace navigation', '/prototype'),
            _wf('WF-03', 'Assessment creation & workspace', '/prototype/wf-03'),
            _wf('WF-04', 'Entrepreneur M2 questionnaire', '/prototype/wf-04'),
            _wf('WF-05', 'Business understanding & confirmation', '/prototype/wf-05'),
            _wf('WF-06', 'Market research & survey preparation', '/prototype/wf-06'),
            _wf('WF-07', 'Geographic exploration', '/prototype/wf-07'),
            _wf('WF-08', 'Evidence & analysis', '/prototype/wf-08'),
            _wf('WF-09', 'Future customer-enriched report (R01–R12)', '/prototype/wf-09'),
            _wf('WF-10', 'Customer questionnaire journey', '/prototype/wf-10'),
            _wf('WF-11', 'Research administration', '/prototype/wf-11'),
            _wf('WF-12', 'Audit & workflow handover', '/prototype/wf-12'),
          ]),
        ),
      ]),
    );
  }

  Component _roleCard(String title, String body, String href) => a(
    href: href,
    classes: 'proto-role',
    [
      span(classes: 'proto-role__title', [Component.text(title)]),
      span(classes: 'proto-role__body', [Component.text(body)]),
      span(classes: 'proto-role__cta', [Component.text('Open →')]),
    ],
  );

  Component _wf(String id, String label, String href) => a(
    href: href,
    classes: 'proto-wf',
    [
      span(classes: 'proto-wf__id', [Component.text(id)]),
      span(classes: 'proto-wf__label', [Component.text(label)]),
    ],
  );
}

// ---------------------------------------------------------------------------
// WF-06 — Market research & customer survey preparation
// ---------------------------------------------------------------------------

class ResearchPrepPage extends StatelessComponent {
  const ResearchPrepPage({super.key});

  @override
  Component build(BuildContext context) {
    return ProtoShell(
      title: 'Market research and survey preparation',
      eyebrow: 'WF-06 · Entrepreneur',
      currentRoute: '/prototype/wf-06',
      child: div(classes: 'proto-stack', [
        ProtoNote(
          'This is not the postponed Early Report review. It explains what '
          'customer research is available or still needed.',
          tone: 'info',
        ),
        div(classes: 'proto-grid proto-grid--3', [
          ProtoCard(
            title: 'Available external information',
            badge: 'NOT APPROVED',
            badgeTone: 'warn',
            child: Component.text(
              'No external geographic or market source is approved for use. '
              'District-level context is illustrative only.',
            ),
          ),
          ProtoCard(
            title: 'Existing historical customer evidence',
            badge: 'NONE',
            badgeTone: 'neutral',
            child: Component.text(
              'No historical customer evidence is held for this assessment.',
            ),
          ),
          ProtoCard(
            title: 'A new customer survey',
            badge: 'PROPOSED',
            badgeTone: 'info',
            child: Component.text(
              'A separate customer questionnaire (Q01–Q13) is proposed. It is '
              'not fielding-approved and no respondents are recruited.',
            ),
          ),
        ]),
        ProtoCard(
          title: 'Source availability',
          child: div(classes: 'proto-list', [
            _row('Approved customer responses', 'Not available', 'warn'),
            _row('Approved external market data', 'Not available', 'warn'),
            _row('Entrepreneur-declared information', 'Available (self-declared)', 'info'),
            _row('Approved demand benchmarks', 'Not available', 'warn'),
          ]),
        ),
        ProtoNote(
          'Customer interest has not yet been measured. No data shown here is '
          'verified, accepted or approved for use.',
          tone: 'warn',
        ),
        ProtoButton('Continue to geographic exploration', href: '/prototype/wf-07'),
      ]),
    );
  }

  Component _row(String label, String value, String tone) => div(
    classes: 'proto-row',
    [
      span(classes: 'proto-row__label', [Component.text(label)]),
      ProtoBadge(value, tone: tone),
    ],
  );
}

// ---------------------------------------------------------------------------
// WF-11 — Research administration
// ---------------------------------------------------------------------------

class ResearchAdminPage extends StatelessComponent {
  const ResearchAdminPage({super.key});

  @override
  Component build(BuildContext context) {
    return ProtoShell(
      title: 'Research administration',
      eyebrow: 'WF-11 · Research Administrator',
      currentRoute: '/prototype/wf-11',
      child: div(classes: 'proto-stack', [
        ProtoNote(
          'Simulated administrator actions grant no real scientific, '
          'institutional, security or Owner authorization.',
          tone: 'warn',
        ),
        ProtoCard(
          title: 'Questionnaire versions',
          child: div(classes: 'proto-table', [
            _tableRow('Version', 'Status', 'Fielding', true),
            _tableRow('vDRAFT.0', 'Working design', 'Not approved', false),
            _tableRow('M2 bank', 'EMPTY', 'Not available', false),
            _tableRow('Customer Q01–Q13', 'Under review', 'Not approved', false),
          ]),
        ),
        ProtoCard(
          title: 'Readiness — four distinct checks',
          child: div(classes: 'proto-list', [
            _check('Documentary checks', 'Partly complete', 'info'),
            _check('Scientific approval', 'Not granted', 'warn'),
            _check('Real data collection', 'Not started', 'warn'),
            _check('Production readiness', 'Not started', 'warn'),
          ]),
        ),
        ProtoCard(
          title: 'Outstanding scientific / governance decisions',
          child: div(classes: 'proto-list', [
            _check('M2-DEPMAP-01', 'UNAPPROVED', 'warn'),
            _check('Q-1 confirmation interpretation', 'UNSIGNED', 'warn'),
            _check('Operational question bank', 'EMPTY', 'warn'),
            _check('ER-M2 correction research', 'OPEN', 'warn'),
            _check('WS1 Geography identifiers & source rights', 'OPEN', 'warn'),
          ]),
        ),
        ProtoButton('Review audit trail', href: '/prototype/wf-12'),
      ]),
    );
  }

  Component _tableRow(String a, String b, String c, bool header) => div(
    classes: header ? 'proto-table__row proto-table__row--head' : 'proto-table__row',
    [
      span([Component.text(a)]),
      span([Component.text(b)]),
      span([Component.text(c)]),
    ],
  );

  Component _check(String label, String value, String tone) => div(
    classes: 'proto-row',
    [
      span(classes: 'proto-row__label', [Component.text(label)]),
      ProtoBadge(value, tone: tone),
    ],
  );
}

// ---------------------------------------------------------------------------
// WF-12 — Audit & workflow handover
// ---------------------------------------------------------------------------

class AuditPage extends StatefulComponent {
  const AuditPage({super.key});

  @override
  State<AuditPage> createState() => _AuditPageState();
}

class _AuditPageState extends State<AuditPage> {
  final List<String> _feedback = [];
  String _draft = '';

  @override
  Component build(BuildContext context) {
    return ProtoShell(
      title: 'Audit and workflow handover',
      eyebrow: 'WF-12 · Traceability & feedback',
      currentRoute: '/prototype/wf-12',
      child: div(classes: 'proto-stack', [
        ProtoCard(
          title: 'Version and source trail',
          child: div(classes: 'proto-list', [
            _kv('Prototype version', kPrototypeVersion),
            _kv('M2 working version', 'vDRAFT.0 (sample inputs only)'),
            _kv('Report structure', 'R01–R12 (V4 WF-09)'),
            _kv('Customer questionnaire', 'Q01–Q13 (under scientific review)'),
            _kv('Persistence', 'None — all state is in-memory'),
          ]),
        ),
        ProtoCard(
          title: 'Workflow states',
          child: div(classes: 'proto-list', [
            _state('WF-03 Assessment', 'Demonstrated'),
            _state('WF-04 M2', 'Demonstrated (working set)'),
            _state('WF-05 Understanding', 'Demonstrated (simulated confirmation)'),
            _state('WF-06 Research prep', 'Demonstrated'),
            _state('WF-07 Geography', 'Demonstrated (fictional)'),
            _state('WF-08 Evidence', 'Demonstrated'),
            _state('WF-09 Report', 'Demonstrated (fictional data)'),
            _state('WF-10 Customer journey', 'Demonstrated'),
            _state('WF-11 Research admin', 'Demonstrated'),
            _state('WF-12 Audit', 'This screen'),
          ]),
        ),
        ProtoNote(
          'Unresolved requirements: approved customer responses, approved '
          'external market data, validated demand benchmarks, scientific '
          'sign-off of questionnaires, and real backend confirmation.',
          tone: 'warn',
        ),
        ProtoCard(
          title: 'Design feedback (simulated)',
          child: div(classes: 'proto-stack', [
            div(classes: 'proto-inline', [
              input(
                type: InputType.text,
                attributes: {
                  'placeholder': 'Summarise a design observation…',
                  'aria-label': 'Design feedback',
                  'value': _draft,
                },
                events: events<String>(
                  onInput: (v) => setState(() => _draft = v),
                ),
              ),
              button(
                classes: 'proto-btn proto-btn--primary',
                events: events(onClick: () {
                  final text = _draft.trim();
                  if (text.isEmpty) return;
                  setState(() {
                    _feedback.add(text);
                    _draft = '';
                  });
                }),
                [Component.text('Add note')],
              ),
            ]),
            if (_feedback.isEmpty)
              span(classes: 'proto-muted', [
                Component.text('No feedback recorded in this session.'),
              ])
            else
              ul(classes: 'proto-feedback', [
                for (final f in _feedback) li([Component.text(f)]),
              ]),
            span(classes: 'proto-muted', [
              Component.text(
                'Feedback is in-memory only and is not sent anywhere.',
              ),
            ]),
          ]),
        ),
      ]),
    );
  }

  Component _kv(String k, String v) => div(classes: 'proto-row', [
    span(classes: 'proto-row__label', [Component.text(k)]),
    span(classes: 'proto-row__value', [Component.text(v)]),
  ]);

  Component _state(String k, String v) => div(classes: 'proto-row', [
    span(classes: 'proto-row__label', [Component.text(k)]),
    ProtoBadge(v, tone: 'info'),
  ]);
}
