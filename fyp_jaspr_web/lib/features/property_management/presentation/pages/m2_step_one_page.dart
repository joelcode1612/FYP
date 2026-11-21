import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

/// Data-driven M2 screen matching the approved Step-1 visual layout.
/// The authoritative 11-item definition, response options, and applicability
/// must be obtained from the current instrument service, not generated here.
///
/// LOCAL ADAPTATION: the uploaded file marked this `@client`, but its
/// `M2QuestionnaireEditorSnapshot` parameter cannot be serialized by Jaspr's
/// client codegen, and every `@client` shell in this app takes primitive
/// params only. It is therefore a plain StatefulComponent mounted under the
/// primitive-param `@client` `AssessmentWorkspacePage`. It still runs fully
/// client-side. Two more edits were needed to compile against Jaspr 0.23.5:
/// `textarea` has no `value:` parameter (content is its children), and the
/// choice radios/checkboxes need an explicit `input<bool>` type argument.
class M2ChoiceView {
  final String code;
  final String label;
  const M2ChoiceView({required this.code, required this.label});
}

class M2QuestionEditorView {
  final String id;
  final String version;
  final String prompt;
  final String type; // SINGLE_SELECT, MULTI_SELECT, TEXT, or existing custom type
  final bool requiredWhenApplicable;
  final bool applicable;
  final String answerStatus;
  final String validationState;
  final List<M2ChoiceView> options;
  final List<String> selectedCodes;
  final String? textAnswer;

  const M2QuestionEditorView({
    required this.id,
    required this.version,
    required this.prompt,
    required this.type,
    required this.requiredWhenApplicable,
    required this.applicable,
    required this.answerStatus,
    required this.validationState,
    this.options = const [],
    this.selectedCodes = const [],
    this.textAnswer,
  });
}

class M2QuestionnaireEditorSnapshot {
  final String assessmentId;
  final int revision;
  final String instrumentVersion;
  final bool verifiedAssessmentBinding;
  final List<M2QuestionEditorView> questions;

  const M2QuestionnaireEditorSnapshot({
    required this.assessmentId,
    required this.revision,
    required this.instrumentVersion,
    required this.verifiedAssessmentBinding,
    required this.questions,
  });
}

typedef SaveM2Response = Future<void> Function(
  String assessmentId,
  int expectedAssessmentRevision,
  String questionId,
  String questionVersion,
  String answerStatus,
  List<String> optionCodes,
  String? textValue,
);

class M2StepOnePage extends StatefulComponent {
  final M2QuestionnaireEditorSnapshot snapshot;
  final SaveM2Response? onSaveAnswer;
  final Future<void> Function()? onRefresh;
  final Component Function(M2QuestionEditorView)? customQuestionEditor;

  const M2StepOnePage({
    super.key,
    required this.snapshot,
    this.onSaveAnswer,
    this.onRefresh,
    this.customQuestionEditor,
  });

  @override
  State<M2StepOnePage> createState() => _M2StepOneState();
}

class _M2StepOneState extends State<M2StepOnePage> {
  int _activeIndex = 0;
  String? _editingQuestionId;
  int? _editingAssessmentRevision;
  String _answerStatus = 'ANSWERED';
  List<String> _selectedCodes = [];
  String _textAnswer = '';
  bool _saving = false;
  String? _feedback;
  String? _error;

  void _select(int index) {
    final q = component.snapshot.questions[index];
    setState(() {
      _activeIndex = index;
      _editingQuestionId = q.id;
      _editingAssessmentRevision = component.snapshot.revision;
      _answerStatus = q.answerStatus;
      _selectedCodes = [...q.selectedCodes];
      _textAnswer = q.textAnswer ?? '';
      _feedback = null;
      _error = null;
    });
  }

  @override
  void didUpdateComponent(covariant M2StepOnePage previous) {
    super.didUpdateComponent(previous);
    final currentId = _editingQuestionId;
    final valid = currentId != null &&
      component.snapshot.questions.any((q) => q.id == currentId);
    if (previous.snapshot.assessmentId != component.snapshot.assessmentId ||
        !valid) {
      _activeIndex = 0;
      _editingQuestionId = null;
      _editingAssessmentRevision = null;
      _selectedCodes = [];
      _textAnswer = '';
      _answerStatus = 'ANSWERED';
      _feedback = null;
      _error = null;
    }
  }

  void _initialize(M2QuestionEditorView q) {
    if (_editingQuestionId == q.id &&
        _editingAssessmentRevision == component.snapshot.revision) {
      return;
    }
    _editingQuestionId = q.id;
    _editingAssessmentRevision = component.snapshot.revision;
    _answerStatus = q.answerStatus;
    _selectedCodes = [...q.selectedCodes];
    _textAnswer = q.textAnswer ?? '';
  }

  Future<void> _save(M2QuestionEditorView q) async {
    if (_saving || component.onSaveAnswer == null ||
        !component.snapshot.verifiedAssessmentBinding || !q.applicable) {
      return;
    }
    setState(() { _saving = true; _feedback = null; _error = null; });
    try {
      await component.onSaveAnswer!(
        component.snapshot.assessmentId,
        component.snapshot.revision,
        q.id,
        q.version,
        _answerStatus,
        List<String>.unmodifiable(_selectedCodes),
        q.type == 'TEXT' ? _textAnswer : null,
      );
      if (component.onRefresh != null) await component.onRefresh!();
      if (!mounted) return;
      setState(() {
        _saving = false;
        _feedback = 'Save request succeeded. Verify the updated server revision and answer receipt.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Save failed. The server did not confirm a new answer revision.';
      });
    }
  }

  Component _choice(M2QuestionEditorView q, M2ChoiceView option) {
    final multi = q.type == 'MULTI_SELECT';
    final checked = _selectedCodes.contains(option.code);
    return label(classes: 'm1-choice ${checked ? 'm1-choice--selected' : ''}', [
      input<bool>(
        type: multi ? InputType.checkbox : InputType.radio,
        checked: checked,
        disabled: _saving || _answerStatus != 'ANSWERED' || !q.applicable,
        onChange: (_) => setState(() {
          if (multi) {
            if (checked) {
              _selectedCodes.remove(option.code);
            } else {
              _selectedCodes.add(option.code);
            }
          } else {
            _selectedCodes = [option.code];
          }
        }),
        attributes: {'name': 'm2-${q.id}'},
      ),
      span([Component.text(option.label)]),
    ]);
  }

  Component _editor(M2QuestionEditorView q) {
    if (!q.applicable) {
      return div(classes: 'm1-notice', [Component.text(
        'This question is not applicable under the current versioned M2 rules.'
      )]);
    }
    if (q.type == 'SINGLE_SELECT' || q.type == 'MULTI_SELECT') {
      return div(classes: 'm1-options', [
        for (final option in q.options) _choice(q, option),
      ]);
    }
    if (q.type == 'TEXT') {
      // LOCAL ADAPTATION: Jaspr 0.23.5 `textarea` has no `value:` parameter —
      // its content is its children.
      return textarea(
        rows: 5,
        classes: 'm1-textarea',
        onInput: (value) => setState(() => _textAnswer = value),
        attributes: {'aria-label': q.prompt},
        [Component.text(_textAnswer)],
      );
    }
    if (component.customQuestionEditor != null) {
      return component.customQuestionEditor!(q);
    }
    return div(classes: 'm1-notice', [Component.text(
      'This question uses a governed input type (${q.type}), such as GEO. '
      'Attach the existing specialized editor; do not replace it with an '
      'unvalidated free-text field.'
    )]);
  }

  @override
  Component build(BuildContext context) {
    final data = component.snapshot;
    if (data.questions.isEmpty) {
      return section(classes: 'm1-workspace', [
        h2([Component.text('Business & M2')]),
        p([Component.text('No authoritative M2 instrument items were loaded.')]),
      ]);
    }
    final index = _activeIndex.clamp(0, data.questions.length - 1).toInt();
    final question = data.questions[index];
    _initialize(question);
    final editable = data.verifiedAssessmentBinding && question.applicable &&
      (question.type == 'SINGLE_SELECT' || question.type == 'MULTI_SELECT' ||
       question.type == 'TEXT');

    return section(classes: 'm1-workspace', attributes: {
      'data-testid': 'm2-step-one',
    }, [
      div(classes: 'm1-layout', [
        aside(classes: 'm1-navigation', [
          h2([Component.text('M2 Questions (${data.questions.length})')]),
          p(classes: 'm1-muted', [Component.text(data.instrumentVersion)]),
          for (var i = 0; i < data.questions.length; i++)
            button(
              classes: 'm1-nav-item ${i == index ? 'm1-nav-item--selected' : ''}',
              onClick: () => _select(i),
              attributes: {
                'type': 'button',
                'aria-current': i == index ? 'step' : 'false',
              },
              [Component.text(data.questions[i].id)],
            ),
        ]),
        article(classes: 'm1-editor', [
          div(classes: 'm1-id', [Component.text(question.id)]),
          h2([Component.text(question.prompt)]),
          div(classes: 'm1-metadata', [
            span(classes: 'm1-requirement', [Component.text(
              question.requiredWhenApplicable ? 'Required' : 'Optional / conditional'
            )]),
            span([Component.text('Item version ${question.version}')]),
            span([Component.text('Validation ${question.validationState}')]),
          ]),
          div(classes: 'm1-status', [
            label([
              input<bool>(type: InputType.radio,
                checked: _answerStatus == 'ANSWERED',
                onChange: (_) => setState(() => _answerStatus = 'ANSWERED'),
                attributes: {'name': 'm2-answer-state'},
              ),
              Component.text('ANSWERED'),
            ]),
            label([
              input<bool>(type: InputType.radio,
                checked: _answerStatus == 'NOT_PROVIDED',
                onChange: (_) => setState(() => _answerStatus = 'NOT_PROVIDED'),
                attributes: {'name': 'm2-answer-state'},
              ),
              Component.text('NOT_PROVIDED'),
            ]),
          ]),
          _editor(question),
          if (!data.verifiedAssessmentBinding)
            div(classes: 'm1-notice', [Component.text(
              'M2 assessment identity is not verified. Saving is disabled.'
            )]),
          if (_feedback != null)
            p(classes: 'm1-feedback', [Component.text(_feedback!)]),
          if (_error != null)
            p(classes: 'm1-error', [Component.text(_error!)]),
          div(classes: 'm1-footer', [
            button(classes: 'm1-primary',
              disabled: _saving || component.onSaveAnswer == null || !editable,
              onClick: () => _save(question),
              attributes: {'type': 'button', 'data-testid': 'm2-save-answer'},
              [Component.text(_saving ? 'Saving…' : 'Save answer')]),
            button(classes: 'm1-secondary',
              disabled: index + 1 >= data.questions.length,
              onClick: index + 1 >= data.questions.length
                ? null : () => _select(index + 1),
              attributes: {'type': 'button'},
              [Component.text('Next question →')]),
          ]),
        ]),
      ]),
    ]);
  }
}
