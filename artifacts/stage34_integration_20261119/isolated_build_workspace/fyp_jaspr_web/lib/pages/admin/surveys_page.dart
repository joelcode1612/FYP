import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/admin_ops_kit.dart';
import '../../components/dashboard_kit.dart';
import '../../components/ui.dart';
import '../../layouts/app_layout.dart';

/// Community surveys — the participant-facing screening and questionnaire
/// surface, previewed from the administrator side.
///
/// ## What is real, and what is deliberately not
///
/// There is **no survey-response endpoint and no responses table** on this
/// backend. A submission that said "recorded" while writing nothing would be
/// exactly the kind of false success this build refuses to ship — so the form
/// runs its full validation (consent + eligibility + both answers), then, on
/// submit, states in place that **nothing was sent or stored** and why.
///
/// The screening copy is the design's sample study, marked as such. No
/// participant, answer or count is invented anywhere on this screen.
///
/// Layout mirrors the preview's two-column study panel + form, rebuilt on
/// the shared `.panel` frame so the shell, theme and focus styles carry over.
@client
class AdminSurveysPage extends StatefulComponent {
  const AdminSurveysPage({super.key});

  @override
  State<AdminSurveysPage> createState() => _SurveysState();
}

class _SurveysState extends State<AdminSurveysPage> {
  bool _eligible = false;
  bool _consent = false;
  String? _stage;
  String? _priority;

  /// The submit outcome — always the plain truth that nothing was written.
  bool _submitted = false;

  bool get _valid =>
      _eligible && _consent && _stage != null && _priority != null;

  void _reset() => setState(() {
    _eligible = false;
    _consent = false;
    _stage = null;
    _priority = null;
    _submitted = false;
  });

  Component _chipQuestion({
    required String question,
    required String prompt,
    required List<String> options,
    required String? value,
    required void Function(String) onSelect,
  }) => div([
    h3(classes: 'ops-question', [Component.text(question)]),
    ChipRow(
      options: options,
      selected: value ?? '',
      ariaLabel: prompt,
      onSelect: onSelect,
    ),
  ]);

  Component _form() {
    if (_submitted) {
      return div(classes: 'stack ops-fade', [
        div(classes: 'ops-card', [
          span(classes: 'ops-tile ops-tile--lg', [const Icon('mail_lock')]),
          h3(classes: 'ops-card__title', [
            Component.text('No response was sent'),
          ]),
          p(classes: 'ops-card__meta', [
            Component.text(
              'This build has no survey-response endpoint and no table to '
              'store answers in, so pressing submit transmitted nothing and '
              'saved nothing — on this page or anywhere else. Your answers '
              'exist only as the controls you selected and vanish on '
              'reload.',
            ),
          ]),
        ]),
        const ActionNotice(
          'Blocked by the backend gap: participant responses cannot be '
          'collected until a submission API and storage exist (a schema '
          'change that requires explicit approval).',
          tone: 'warn',
        ),
        ActionButton('Start over', variant: 'secondary', onClick: _reset),
      ]);
    }

    return div(classes: 'stack', [
      h3(classes: 'ops-subhead', [Component.text('Screening & consent')]),
      p(classes: 'ops-qrow__meta', [
        Component.text(
          'Confirm eligibility before answering this sample survey.',
        ),
      ]),
      div([
        label(classes: 'ops-checkrow', [
          input(
            type: InputType.checkbox,
            checked: _eligible,
            events: events(
              onClick: () => setState(() => _eligible = !_eligible),
            ),
          ),
          span([
            Component.text(
              'I operate or plan to operate an F&B business in the study '
              'area.',
            ),
          ]),
        ]),
        label(classes: 'ops-checkrow', [
          input(
            type: InputType.checkbox,
            checked: _consent,
            events: events(onClick: () => setState(() => _consent = !_consent)),
          ),
          span([
            Component.text(
              'I consent to this demonstration questionnaire. (Consent would '
              'be recorded server-side in production — it is not, here.)',
            ),
          ]),
        ]),
      ]),
      hr(classes: 'ops-rule'),
      _chipQuestion(
        question: '1. What stage is your F&B business in?',
        prompt: 'Business stage',
        options: const ['Planning', 'Operating', 'Exploring'],
        value: _stage,
        onSelect: (value) => setState(() => _stage = value),
      ),
      _chipQuestion(
        question: '2. Which location factor matters most?',
        prompt: 'Location priority',
        options: const ['Rental cost', 'Customer demand', 'Accessibility'],
        value: _priority,
        onSelect: (value) => setState(() => _priority = value),
      ),
      div(classes: 'ops-card__actions', [
        ActionButton(
          'Submit response',
          icon: 'arrow_forward',
          onClick: _valid ? () => setState(() => _submitted = true) : null,
        ),
      ]),
      if (!_valid)
        p(classes: 'ops-qrow__meta', [
          Component.text(
            'Confirm eligibility, give consent, and answer both questions to '
            'enable the submit action.',
          ),
        ]),
    ]);
  }

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.admin,
      currentRoute: '/admin/surveys',
      title: 'Community surveys',
      eyebrow: 'Operations',
      subtitle:
          'The shared participant screening and questionnaire surface — '
          'answering how the study would be presented before any response '
          'capture exists.',
      child: div(classes: 'stack ops-fade', [
        Callout(
          'Survey participation is not provisioned: there is no responses '
          'table and no submission endpoint, so this screen interacts but '
          'never transmits. Submitting reports that plainly instead of '
          'pretending to store an answer.',
          tone: 'warning',
          icon: 'construction',
        ),
        div(classes: 'ops-split', [
          section(classes: 'panel', [
            div(classes: 'panel__body', [
              div(classes: 'stack', [
                div(classes: 'ops-tile ops-tile--lg', [const Icon('favorite')]),
                span(classes: 'eyebrow', [
                  Component.text('Shared research · sample content'),
                ]),
                h3(classes: 'ops-card__title', [
                  Component.text('F&B location experience study'),
                ]),
                p(classes: 'ops-hero__body', [
                  Component.text(
                    'A community questionnaire for entrepreneurs and local '
                    'F&B operators, used to preview how participant '
                    'screening reads before a real study is launched.',
                  ),
                ]),
                const ActionNotice(
                  'Left: what participants would see. Right: the screening '
                  'flow with its validation. Neither side talks to a server.',
                  tone: 'info',
                ),
              ]),
            ]),
          ]),
          section(classes: 'panel', [
            div(classes: 'panel__head', [
              span(classes: 'panel__title', [
                Component.text('Screening & consent'),
              ]),
            ]),
            div(classes: 'panel__body', [_form()]),
          ]),
        ]),
      ]),
    );
  }
}
