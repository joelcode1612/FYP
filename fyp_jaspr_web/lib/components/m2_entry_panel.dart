import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';
import '../data/app_locator.dart';
import 'ui.dart';
import '../pages/entrepreneur/confirmed_business_review_page.dart'
    show BusinessContextActions;

/// Persisted initial M2 entry. The property workspace and M2 identifiers are
/// separate; the owner explicitly chooses an M2 record, never a confirmation.
@client
class M2EntryPanel extends StatefulComponent {
  final String assessmentId;
  const M2EntryPanel({super.key, this.assessmentId = ''});
  @override
  State<M2EntryPanel> createState() => _M2EntryState();
}

class _M2EntryState extends State<M2EntryPanel> {
  bool busy = true, dirty = false;
  String? error, notice;
  List<Map<String, dynamic>> instruments = [], assessments = [];
  M2Draft? draft;
  Map<String, dynamic>? worksheet, confirmation;
  int index = 0;
  String text = '', state = 'ANSWERED';
  String geoArea = '';
  final selected = <String>{};
  @override
  void initState() {
    super.initState();
    Future.microtask(_catalogue);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (!mounted) return;
    setState(() {
      busy = true;
      error = null;
      notice = null;
    });
    try {
      await action();
    } on AppFailure catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'The M2 source or operation is unavailable. Reload your saved assessments before retrying. Your stored answers are retained.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _catalogue() => _run(() async {
    final i = await AppLocator.m2.instruments(),
        a = await AppLocator.m2.assessments();
    if (!mounted) return;
    instruments = i;
    assessments = a;
    if (component.assessmentId.isNotEmpty) await _open(component.assessmentId);
  });
  void _loadSelection() {
    dirty = false;
    selected.clear();
    text = '';
    geoArea = '';
    state = 'ANSWERED';
    if (draft == null || questions.isEmpty) return;
    if (index >= questions.length) index = 0;
    final answer =
        draft!.answers[questions[index]['item_key']] as Map<String, dynamic>?;
    if (answer == null) {
      final derived = questions[index]['derived_value'];
      if (derived is String) selected.add(derived);
      return;
    }
    state = answer['answer_state'] as String;
    final value = answer['value_json'];
    if (value is String) {
      text = value;
      selected.add(value);
    }
    if (value is List) selected.addAll(value.cast<String>());
    if (value is Map) {
      selected.add(value['jurisdiction'] as String);
      geoArea = value['area_ref'] as String;
    }
  }

  List<Map<String, dynamic>> get questions =>
      draft?.items
          .where(
            (q) =>
                q['lifecycle'] == 'ACTIVE' &&
                q['answer_kind'] != 'ACTION' &&
                q['applicable'] != false,
          )
          .toList() ??
      [];
  Future<void> _open(String id) async {
    final d = await AppLocator.m2.read(id);
    if (!mounted) return;
    draft = d;
    worksheet = null;
    confirmation = null;
    index = 0;
    _loadSelection();
  }

  Future<void> _save() => _run(_saveCurrent);
  Future<void> _saveCurrent() async {
    final q = questions[index], d = draft!;
    Object? value = state != 'ANSWERED'
        ? null
        : q['answer_kind'] == 'TEXT'
        ? text
        : q['answer_kind'] == 'MULTI'
        ? selected.toList()
        : selected.firstOrNull;
    if (state == 'ANSWERED' &&
        q['answer_kind'] == 'GEO' &&
        value != 'UNDECIDED') {
      final geo = (q['option_values'] as Map)['rules']['geography'] as Map;
      if (geo['status'] != 'VERIFIED' || geoArea.isEmpty) {
        throw const ValidationFailure(
          'Select an area from the approved GEO catalogue when available. No area reference will be invented.',
        );
      }
      value = {
        'jurisdiction': selected.first,
        'area_ref': geoArea,
        'catalogue_version': geo['catalogue_version'],
      };
    }
    final saved = await AppLocator.m2.save(
      d,
      q['item_key'] as String,
      state,
      value,
    );
    if (!mounted) return;
    draft = saved;
    worksheet = null;
    confirmation = null;
    notice = 'Answer saved at revision ${saved.revision}.';
    _loadSelection();
  }

  void _edited() {
    dirty = true;
    worksheet = null;
    confirmation = null;
  }

  Future<void> _selectQuestion(int next) => _run(() async {
    if (dirty) await _saveCurrent();
    if (!mounted) return;
    index = next;
    _loadSelection();
  });
  Future<void> _evaluate() => _run(() async {
    // Persist and read back pending input before pinning the submitted revision.
    // Saving and question navigation never invoke BDJ.
    if (dirty) await _saveCurrent();
    if (!mounted) return;
    final d = draft!;
    final missing = questions
        .where((q) {
          if (q['effective_required'] != true &&
              q['requiredness'] != 'REQUIRED') {
            return false;
          }
          if (q['derived_value'] != null &&
              !d.answers.containsKey(q['item_key'])) {
            return false;
          }
          final answer = d.answers[q['item_key']] as Map<String, dynamic>?;
          return answer == null ||
              !(q['allowed_states'] as List).contains(answer['answer_state']) ||
              [
                'NOT_PROVIDED',
                'SKIPPED_OPTIONAL',
              ].contains(answer['answer_state']);
        })
        .map((q) => q['item_key'])
        .join(', ');
    if (missing.isNotEmpty) {
      throw ValidationFailure(
        'Complete the required answers before submitting for BDJ review: $missing',
      );
    }
    final result = await AppLocator.m2.evaluate(d);
    if (result['assessment_id'] != d.id || result['revision'] != d.revision) {
      throw const FormatException('Stale BDJ source.');
    }
    if (mounted) worksheet = result;
  });
  @override
  Component build(BuildContext context) {
    final d = draft;
    // PROJECT1 V1.5 Step 2 mock UI. Presentation only: no route, stage,
    // assessment record, M2 source binding or API contract is introduced.
    return section(
      classes: 'asw-m2-workspace stack stack--md sw2-step2'
          '${d != null ? ' has-draft' : ''}',
      [
      div(classes: 'sw2-workflow', [
        div(classes: 'sw2-workflow__title', [
          Icon('layers', size: 'sm'),
          Component.text('Assessment Workflow'),
        ]),
        nav(classes: 'sw2-workflow__steps', attributes: {
          'aria-label': 'Assessment workflow steps',
        }, [
          div(classes: 'sw2-workflow__step is-active', [
            span(classes: 'sw2-workflow__num', [Component.text('1')]),
            span([Component.text('Step 1 — Business & M2')]),
          ]),
          span(classes: 'sw2-workflow__line', [Component.text('')]),
          div(classes: 'sw2-workflow__step', [
            span(classes: 'sw2-workflow__num', [Component.text('2')]),
            span([Component.text('Step 2 — M3 & Operations')]),
          ]),
          span(classes: 'sw2-workflow__line', [Component.text('')]),
          div(classes: 'sw2-workflow__step', [
            span(classes: 'sw2-workflow__num', [Component.text('3')]),
            span([Component.text('Step 3 — Review & Submit')]),
          ]),
        ]),
      ]),
      h2([Component.text('Café planning questionnaire')]),
      p([
        Component.text(
          'Choose your M2 record by ID. The list belongs to your account and is independent of the selected property.',
        ),
      ]),
      if (busy)
        p(
          attributes: {'role': 'status'},
          [Component.text('Loading saved M2 records…')],
        ),
      if (error != null)
        p(attributes: {'role': 'alert'}, [Component.text(error!)]),
      if (notice != null)
        p(attributes: {'role': 'status'}, [Component.text(notice!)]),
      div(classes: 'row row--sm', [
        ActionButton(
          'Reload saved assessments',
          variant: 'secondary',
          onClick: busy ? null : _catalogue,
        ),
        if (d != null)
          ActionButton(
            'Reload current assessment',
            variant: 'ghost',
            onClick: busy ? null : () => _run(() => _open(d.id)),
          ),
      ]),
      if (assessments.isNotEmpty)
        select(
          disabled: busy,
          attributes: {'aria-label': 'Saved M2 assessment'},
          events: events<List<String>>(
            onInput: (values) {
              if (values.isNotEmpty && values.first.isNotEmpty) {
                _run(() => _open(values.first));
              }
            },
          ),
          [
            option(value: '', [
              Component.text('Choose a saved M2 assessment…'),
            ]),
            for (final a in assessments)
              option(
                value: a['id'] as String,
                attributes: a['id'] == d?.id ? const {'selected': ''} : null,
                [Component.text('${a['id']} · revision ${a['revision']}')],
              ),
          ],
        ),
      if (assessments.length == 50)
        p([
          Component.text(
            'Showing the 50 most recent saved assessments. An existing direct M2 link can open an older assessment.',
          ),
        ]),
      for (final instrument in instruments)
        ActionButton(
          'Start M2 ${instrument['code']} · ${instrument['version_tag']}',
          onClick: busy
              ? null
              : () => _run(() async {
                  final created = await AppLocator.m2.create(
                    instrument['id'] as String,
                  );
                  if (!mounted) return;
                  draft = created;
                  worksheet = null;
                  confirmation = null;
                  index = 0;
                  _loadSelection();
                  assessments = await AppLocator.m2.assessments();
                }),
        ),
      if (!busy && error == null && instruments.isEmpty)
        p(
          attributes: {'role': 'status'},
          [
            Component.text(
              'No authorized M2 instrument is registered. Instrument approval and registration are required; entrepreneur confirmation is not an entry requirement.',
            ),
          ],
        ),
      if (d != null && questions.isNotEmpty)
        div(classes: 'asw-m2-layout', [
          nav(classes: 'asw-m2-nav', [
            div(classes: 'asw-m2-nav__heading', [
              Icon('list', size: 'sm'),
              strong([Component.text('M2 Questions (${questions.length})')]),
            ]),
            for (var i = 0; i < questions.length; i++)
              button(
                classes:
                    'asw-m2-nav__section${i == index ? ' is-current' : ''}',
                attributes: {
                  'type': 'button',
                  'data-m2-item': questions[i]['item_key'] as String,
                },
                onClick: busy ? null : () => _selectQuestion(i),
                [Component.text(questions[i]['item_key'] as String)],
              ),
          ]),
          div(classes: 'asw-m2-main', [_question(d)]),
          aside(classes: 'asw-m2-aside', [
            div(classes: 'panel', [
              h3([Component.text('Saved answers')]),
              p([
                Component.text('Assessment ${d.id} · revision ${d.revision}'),
              ]),
              p([
                Component.text(
                  'Instrument ${d.data['instrument']['version_tag']}',
                ),
              ]),
              for (final e in d.answers.entries)
                p([
                  Component.text(
                    '${e.key}: ${e.value['answer_state']} · ${e.value['value_json'] ?? 'No substantive value'}',
                  ),
                ]),
            ]),
            ActionButton(
              'Submit answers for BDJ review',
              onClick: busy ? null : _evaluate,
            ),
          ]),
        ]),
      if (worksheet != null)
        div(classes: 'rw-workspace rw-stack', [
          h3([Component.text('Business description review')]),
          p([Component.text(worksheet!['claims_boundary'] as String)]),
          if (worksheet!['item_rules_coverage'] is String)
            p([Component.text(worksheet!['item_rules_coverage'] as String)]),
          if ((worksheet!['findings'] as List).isEmpty)
            p([
              Component.text(
                'No candidate findings from the checked rules. This is not a business viability judgment.',
              ),
            ]),
          for (final finding in worksheet!['findings'] as List)
            div(classes: 'rw-card', [
              p(classes: 'rw-muted', [
                Component.text(
                  'Finding ${finding['id']} · M2 revision ${d!.revision}',
                ),
              ]),
              p([
                Component.text(
                  '${finding['rule_id']}: ${finding['explanation']}',
                ),
              ]),
              p([
                Component.text(
                  'Source answer revisions: ${finding['source_answer_ids']}',
                ),
              ]),
              ActionButton(
                'Keep my original answer',
                onClick: busy
                    ? null
                    : () => _run(() async {
                        await AppLocator.m2.decide(
                          draft!,
                          finding['id'] as String,
                          'KEEP_ORIGINAL',
                          _requestId(),
                        );
                        worksheet = await AppLocator.m2.worksheet(draft!);
                      }),
              ),
              ActionButton(
                'Review this finding later',
                variant: 'secondary',
                onClick: busy
                    ? null
                    : () => _run(() async {
                        await AppLocator.m2.decide(
                          draft!,
                          finding['id'] as String,
                          'REVIEW_LATER',
                          _requestId(),
                        );
                        worksheet = await AppLocator.m2.worksheet(draft!);
                        notice =
                            'Review deferred. This does not confirm or resolve the finding.';
                      }),
              ),
            ]),
          ActionButton(
            _actionText('M2-20', 'Record that I reviewed this revision'),
            onClick: busy
                ? null
                : () => _run(() async {
                    await AppLocator.m2.review(draft!);
                    notice = 'Review recorded for revision ${draft!.revision}.';
                  }),
          ),
          ActionButton(
            _actionText('M2-21', 'Confirm this business information'),
            onClick: busy
                ? null
                : () => _run(() async {
                    confirmation = await AppLocator.m2.confirm(
                      draft!,
                      (worksheet!['findings'] as List)
                          .map((f) => f['id'] as String)
                          .toList(),
                    );
                    draft = await AppLocator.m2.read(draft!.id);
                    notice = 'Your confirmation snapshot was saved.';
                  }),
          ),
        ]),
      if (confirmation != null)
        BusinessContextActions(
          key: ValueKey('context-${confirmation!['id']}'),
          assessmentId: d!.id,
          confirmationId: confirmation!['id'] as String,
          revision: d.revision,
          findingIds: [
            for (final finding in worksheet?['findings'] as List? ?? [])
              finding['id'] as String,
          ],
          researchIntent: d.answers['M2V1-11']?['answer_state'] == 'ANSWERED',
        ),
      if (confirmation != null)
        a(
          href:
              '/entrepreneur/m2-review?assessment=${d!.id}&confirmation=${confirmation!['id']}&revision=${d.revision}',
          [Component.text('Open the saved confirmed business review')],
        ),
      if (d != null)
        a(href: '/entrepreneur/activity-history?assessment=${d.id}', [
          Component.text('View saved M2 activity'),
        ]),
    ]);
  }

  Component _question(M2Draft d) {
    final q = questions[index], kind = q['answer_kind'];
    final data = q['option_values'];
    final options = (q['effective_options'] ?? data) as List;
    final labels = q['option_labels'] as Map? ?? const {};
    final required = q['effective_required'] == true ||
        q['requiredness'] == 'REQUIRED';
    // PROJECT1 V1.5 mock UI: banner + prompt + required/version metadata +
    // answer-state row. The item key, item version, requiredness, allowed
    // states and option codes all come from the existing M2 source.
    return div(classes: 'panel asw-m2-question-card', [
      div(classes: 'asw-m2-question-banner', [
        span(classes: 'asw-m2-question-code', [
          Component.text(q['item_key'] as String),
        ]),
      ]),
      div(classes: 'asw-m2-question-card__body', [
        h3(classes: 'asw-q__prompt', [
          Component.text(q['question_text'] as String),
        ]),
        div(classes: 'asw-m2-question-meta', [
          span(classes: 'asw-m2-required', [
            Component.text(required ? '* Required' : 'Optional / conditional'),
          ]),
          span(classes: 'asw-m2-item-version', [
            Icon('fingerprint', size: 'sm'),
            Component.text('Item version: ${q['id']}'),
          ]),
        ]),
        if (q['derived_value'] != null)
          p([
            Component.text(
              'Derived from your saved selections for review: ${labels[q['derived_value']] ?? q['derived_value']}.',
            ),
          ]),
        div(classes: 'asw-m2-state', [
          for (final responseState in q['allowed_states'] as List)
            label([
              input(
                type: InputType.radio,
                name: 'm2-state',
                value: responseState as String,
                checked: state == responseState,
                disabled: busy,
                onChange: (_) => setState(() {
                  state = responseState;
                  _edited();
                }),
              ),
              Component.text(responseState),
            ]),
        ]),
        if (kind == 'TEXT')
          textarea(
            [Component.text(text)],
            key: ValueKey('m2-editor-${d.id}-${q['id']}-${d.revision}'),
            disabled: busy || state != 'ANSWERED',
            attributes: {'data-m2-answer': q['item_key'] as String},
            onInput: (value) => setState(() {
              text = value;
              _edited();
            }),
          ),
        if (kind == 'SINGLE' || kind == 'MULTI' || kind == 'GEO')
          div(classes: 'asw-m2-options', [
            for (final code in options)
              label(
                classes: 'checkpill${selected.contains(code) ? ' is-on' : ''}',
                [
                  input(
                    type: kind == 'MULTI'
                        ? InputType.checkbox
                        : InputType.radio,
                    name: 'm2-option',
                    value: code as String,
                    checked: selected.contains(code),
                    disabled: busy || state != 'ANSWERED',
                    onChange: (_) => setState(() {
                      if (kind != 'MULTI') {
                        selected.clear();
                        geoArea = '';
                      }
                      if (!selected.add(code)) selected.remove(code);
                      _edited();
                    }),
                  ),
                  Component.text('${labels[code] ?? code}'),
                ],
              ),
          ]),
        if (kind == 'GEO' &&
            selected.isNotEmpty &&
            !selected.contains('UNDECIDED'))
          if ((data as Map)['rules']['geography']['status'] != 'VERIFIED')
            p(
              attributes: {'role': 'status'},
              [
                Component.text(
                  'The approved versioned GEO area catalogue is unavailable. No exact premises location or substitute area will be inferred.',
                ),
              ],
            )
          else
            select(
              attributes: {'aria-label': 'Authorized study area'},
              disabled: busy,
              events: events<List<String>>(
                onInput: (values) => setState(() {
                  geoArea = values.firstOrNull ?? '';
                  _edited();
                }),
              ),
              [
                option(value: '', [
                  Component.text('Choose an authorized area'),
                ]),
                for (final area in data['rules']['geography']['areas'] as List)
                  if (area['jurisdiction'] == selected.first)
                    option(
                      value: area['area_ref'] as String,
                      attributes: geoArea == area['area_ref']
                          ? const {'selected': ''}
                          : null,
                      [Component.text(area['area_ref'] as String)],
                    ),
              ],
            ),
      ]),
      div(classes: 'asw-m2-question-footer', [
        ActionButton(
          'Save answer',
          icon: 'save',
          onClick: busy ? null : _save,
        ),
        if (index + 1 < questions.length)
          ActionButton(
            'Next question →',
            variant: 'secondary',
            onClick: busy ? null : () => _selectQuestion(index + 1),
          ),
      ]),
    ]);
  }

  String _actionText(String key, String fallback) =>
      draft?.items
          .where(
            (q) =>
                q['item_key'] == key &&
                q['answer_kind'] == 'ACTION' &&
                q['option_values'] is Map,
          )
          .map((q) => q['question_text'] as String)
          .firstOrNull ??
      fallback;

  String _requestId() => m2RequestId();
}
