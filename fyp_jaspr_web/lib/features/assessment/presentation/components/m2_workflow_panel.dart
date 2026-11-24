import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart' show M2Draft, AppFailure, NetworkFailure, ResponseFormatFailure;

import 'package:sitewise_jaspr_web/core/di/app_locator.dart';
import 'bdj_objective_proposal_panel.dart' show BdjObjectiveProposalPanel;
import 'stage_four_question_review.dart' show StageFourQuestionReview;
import 'stage_five_questionnaire_preview.dart' show StageFiveQuestionnairePreview;
import 'package:sitewise_jaspr_web/shared/presentation/components/ui.dart' show ActionButton;

/// PROJECT1 M2 research workflow surface.
///
/// Every value shown here comes from the authenticated FastAPI M2 router
/// (`/api/v1/m2/...`). Nothing is seeded from fixtures, and no step invents a
/// result when a call fails:
///
/// * questions and saved answers come from `GET /m2/assessments/{id}`
/// * answers are written by `PUT /m2/assessments/{id}/answers/{item_key}`
/// * confirmation is `POST /m2/assessments/{id}/review` then `.../confirm`
/// * subsequent research stages use the governed panels for objective proposals,
///   question review and questionnaire preview. Declaration confirmation does
///   not run BDJ or authorize question generation.
///
/// Activity History is a separate read-only surface and is linked, not
/// duplicated here.
class M2WorkflowPanel extends StatefulComponent {
  /// Optional deep link to one saved M2 assessment.
  final String assessmentId;

  /// DEF-11: when true the panel refuses to adopt any M2 assessment that was not
  /// named explicitly.
  ///
  /// Embedded in an assessment-specific workspace the "most recent assessment"
  /// fallback is wrong: it silently shows one assessment's answers under another
  /// assessment's heading.
  ///
  /// With this flag set and no [assessmentId], the panel renders an unbound
  /// notice and no editor, so an unlinked assessment cannot save M2 answers.
  final bool requireExplicitId;

  /// True when the panel is one section of the Assessment workspace.
  ///
  /// The standalone `/entrepreneur/m2-workflow` route was retired: the
  /// Assessment workspace is the only production surface, and it always mounts
  /// this panel embedded. The non-embedded branches below are therefore
  /// unreachable from the application; they are retained only until the owner
  /// decides whether their governed Stage 2/4/5 surfaces have a workspace
  /// equivalent. Nothing was deleted, and their services, records and
  /// permissions are untouched.
  final bool embedded;
  final String? marketplaceAssessmentId;
  final void Function()? onDeclarationChanged;
  final void Function()? onDeclarationEditing;

  const M2WorkflowPanel({
    super.key,
    this.assessmentId = '',
    this.requireExplicitId = false,
    this.embedded = false,
    this.marketplaceAssessmentId,
    this.onDeclarationChanged,
    this.onDeclarationEditing,
  });

  @override
  State<M2WorkflowPanel> createState() => _M2WorkflowState();
}

class _M2WorkflowState extends State<M2WorkflowPanel> {
  bool busy = true;
  String? error;
  String notice = '';

  List<Map<String, dynamic>> _assessments = const [];
  List<Map<String, dynamic>> _instruments = const [];
  M2Draft? _draft;
  String _selected = '';

  /// DEF-11: true when the panel is embedded and was given no verified M2 id.
  /// While set, no editor is rendered and therefore no answer can be saved.
  bool _unbound = false;

  // Per-item editor state: every item keeps its own state / codes / text so
  // switching between questions never loses an unsaved edit.
  final Map<String, String> _editorState = {};
  final Map<String, List<String>> _editorCodes = {};
  final Map<String, String> _editorText = {};

  /// COMPOSITE answers carry one value per declared field, so neither the
  /// single-code nor the single-text map can hold them. Values are stored in the
  /// shape the backend `value_schema` declares: String for ENUM/TEXT/AMOUNT_MYR,
  /// List&lt;String&gt; for MULTI, List&lt;Map&gt; for LIST. The schema, not this
  /// file, decides what exists — there is no second copy of the questionnaire.
  final Map<String, Map<String, dynamic>> _editorComposite = {};

  /// Questions the entrepreneur has actually touched in this session.
  ///
  /// Seeding an editor is not an edit. Without this, every unanswered question
  /// starts life as state ANSWERED while its stored state is empty, so a freshly
  /// opened assessment reported eleven dirty items and Save wrote eleven
  /// revisions of nothing.
  final Set<String> _touched = {};

  /// Set once a save round completes, so the status can name the revision
  /// without putting it in the primary message.
  int? _savedRevision;

  /// Autosave is enabled only for the assessment-embedded questionnaire.
  /// A generation token debounces rapid selections and text edits; requests are
  /// serialized by _saveAllDirty to preserve the M2 optimistic-revision contract.
  int _autoSaveTicket = 0;
  bool _autoSaveInFlight = false;
  bool _autoSaveQueued = false;
  bool _pauseReady = false;

  /// Whether the read-only review summary is expanded.
  bool _showReview = false;
  int? _reviewedRevision;

  /// Which governed stage the standalone page is showing.
  ///
  /// The standalone M2 route used to stack the questionnaire, the declaration
  /// review and the research-objective proposals into one continuous page, so
  /// the proposals read as part of the declaration (Stage 2). They are the
  /// output of a later stage: they only exist once a declaration has been
  /// confirmed, and they are what Stage 3 reviews. Splitting the page by stage
  /// is a presentation change only — no service, record or permission moves.
  String _stage = '2';

  /// Which instrument item the question card shows. The instrument decides how
  /// many there are; this index is only the position on screen.
  int _itemIndex = 0;

  Map<String, dynamic>? _confirmation;
  Map<String, dynamic>? _contextStatus;

  /// The deterministic draft concept for the currently saved revision.
  ///
  /// Read-only by contract: the endpoint behind it creates no confirmation and
  /// no persisted business context, so reading it is not a step towards
  /// confirming and cannot make the M2-21 control legal by accident. It is
  /// labelled with the revision it was built from, and dropped the moment the
  /// draft moves on, so the card can never describe a revision that is no
  /// longer saved.
  Map<String, dynamic>? _conceptPreview;
  String? _conceptPreviewError;
  bool _conceptPreviewLoading = false;
  int _conceptPreviewTicket = 0;

  int _request = 0;

  @override
  void initState() {
    super.initState();
    _selected = component.assessmentId;
    Future.microtask(_bootstrap);
  }

  // --- loading -------------------------------------------------------------

  Future<void> _bootstrap() async {
    final request = ++_request;
    setState(() {
      busy = true;
      error = null;
      notice = '';
    });
    try {
      final rows = await AppLocator.m2.assessments();
      if (!mounted || request != _request) return;
      _assessments = rows;

      // DEF-11: embedded mode never adopts an assessment it was not given.
      // No `rows.first`, no "newest", no owner match — an unverified link is
      // reported as unbound instead of guessed.
      if (component.requireExplicitId && _selected.isEmpty) {
        if (rows.isEmpty) {
          _instruments = await AppLocator.m2.instruments();
          if (!mounted || request != _request) return;
        }
        setState(() => _unbound = true);
        return;
      }

      if (rows.isEmpty) {
        _instruments = await AppLocator.m2.instruments();
        if (!mounted || request != _request) return;
      } else {
        final id = _selected.isNotEmpty ? _selected : rows.first['id'] as String;
        await _openInternal(id, request);
        return;
      }
    } catch (_) {
      if (mounted && request == _request) {
        setState(() {
          error =
              'The M2 service did not return saved assessments or instruments. '
              'No substitute questionnaire was loaded. The M2 router is only '
              'mounted when M2_UPSTREAM_ENABLED is true and its database '
              'target resolves to Dss.';
        });
      }
    } finally {
      if (mounted && request == _request) setState(() => busy = false);
    }
  }

  Future<void> _open(String id) async {
    final request = ++_request;
    setState(() {
      busy = true;
      error = null;
      notice = '';
    });
    try {
      await _openInternal(id, request);
    } catch (_) {
      if (mounted && request == _request) {
        setState(() => error = 'This saved M2 assessment could not be loaded.');
      }
    } finally {
      if (mounted && request == _request) setState(() => busy = false);
    }
  }

  Future<void> _openInternal(String id, int request) async {
    final draft = await AppLocator.m2.read(id);
    if (!mounted || request != _request) return;
    setState(() {
      _selected = id;
      _draft = draft;
      _confirmation = null;
      _contextStatus = null;
      // A preview belongs to one assessment at one revision. Opening another
      // assessment must not leave the previous concept on screen, even for the
      // moment before its own preview arrives.
      _conceptPreview = null;
      _conceptPreviewError = null;
      _itemIndex = 0;
      _seedEditors(draft);
    });
    // The preview describes the saved revision, so it is refreshed whenever a
    // different revision is loaded. It is not awaited: a slow preview must not
    // delay the questionnaire, and the card states plainly while it is loading.
    unawaited(_loadConceptPreview());
    try {
      final conf = await AppLocator.m2.currentConfirmation(draft.id);
      if (!mounted || request != _request) return;
      if (conf != null && conf['assessment_revision'] == draft.revision) {
        _confirmation = conf;
      }
    } catch (_) {
      // No confirmation exists yet for this revision; the confirm button
      // remains the legitimate path. Nothing is fabricated.
    }
    // A confirmation was restored, so a persisted context may already exist for
    // it. Read it now so returning to this page shows the context instead of
    // "no action taken yet in this session". Read-only; no build, no confirm.
    if (mounted && _confirmation != null) {
      await _restoreContextStatus(request);
    }
    if (mounted) setState(() {});
  }

  Future<void> _create(String instrumentId) async {
    final request = ++_request;
    setState(() {
      busy = true;
      error = null;
      notice = '';
    });
    try {
      final draft = await AppLocator.m2.create(instrumentId);
      if (!mounted || request != _request) return;
      final rows = await AppLocator.m2.assessments();
      if (!mounted || request != _request) return;
      setState(() {
        _assessments = rows;
        _draft = draft;
        _selected = draft.id;
          _seedEditors(draft);
        notice =
            'Created M2 assessment ${draft.id} at revision ${draft.revision}.';
      });
    } catch (_) {
      if (mounted && request == _request) {
        setState(
          () => error =
              'A new M2 assessment could not be created. The instrument must be '
              'an authorized, active version and the M2 database target must be '
              'Dss.',
        );
      }
    } finally {
      if (mounted && request == _request) setState(() => busy = false);
    }
  }

  // --- editor --------------------------------------------------------------

  List<Map<String, dynamic>> get _items {
    final draft = _draft;
    if (draft == null) return const [];
    return [
      for (final raw in draft.items)
        if ((raw['answer_kind'] as String? ?? '') != 'ACTION') raw,
    ];
  }

  /// UI-03: the server resolves conditional items (M2V1-05/10/11) and returns
  /// `effective_options` + `option_labels` + `applicable` at item level. The
  /// static `option_values.options` is EMPTY for those items, so reading it
  /// offered nothing (or a stale set) and the PUT was refused with 422
  /// "Answer must match one registered option value." The resolved view is
  /// authoritative; the static list is only a fallback for older payloads.
  List<Map<String, dynamic>> _options(Map<String, dynamic> item) {
    // M2V1-01 is a GEO item whose instrument ships area codes, but the backend
    // only accepts UNDECIDED while rules.geography.status != VERIFIED. Offering
    // JOHOR/PENANG/... would produce a guaranteed 422, so the authorized
    // mechanism is the single "not decided" choice. No location is invented.
    if ((item['answer_kind'] as String? ?? '') == 'GEO') {
      final geo = _rules(item)['geography'];
      final verified = geo is Map && geo['status'] == 'VERIFIED';
      if (!verified) {
        return const [
          {'code': 'UNDECIDED', 'label': 'Not decided yet'},
        ];
      }
    }
    final labels = item['option_labels'];
    final effective = item['effective_options'];
    if (effective is List) {
      return [
        for (final code in effective)
          if (code is String)
            {
              'code': code,
              'label': labels is Map && labels[code] is String
                  ? labels[code] as String
                  : code,
            },
      ];
    }
    final values = item['option_values'];
    if (values is! Map) return const [];
    final options = values['options'];
    if (options is! List) return const [];
    return [
      for (final raw in options)
        if (raw is Map && raw['code'] is String) raw.cast<String, dynamic>(),
    ];
  }

  /// Server authority on whether a conditional item currently accepts an answer.
  bool _applicable(Map<String, dynamic> item) => item['applicable'] != false;

  Map<String, dynamic> _rules(Map<String, dynamic> item) {
    final values = item['option_values'];
    if (values is Map && values['rules'] is Map) {
      return (values['rules'] as Map).cast<String, dynamic>();
    }
    return const {};
  }

  /// The question this one depends on, per the instrument's own rule.
  String? _parentKey(Map<String, dynamic> item) {
    final rules = _rules(item);
    final parent = rules['source_item'] ?? rules['requires_priority'];
    return parent is String ? parent : null;
  }

  /// Why a card looks the way it does.
  ///
  /// `applicable` alone is not enough: it is false both when the parent has not
  /// been answered yet and when the parent's answer genuinely excludes this
  /// question. Those are different situations for the entrepreneur, and an empty
  /// `effective_options` cannot tell them apart either — a conditional item with
  /// no eligible children is not the same as one waiting on its parent.
  // --- COMPOSITE items ------------------------------------------------------
  //
  // The instrument's `option_values.value_schema` is the single source of truth
  // for which fields exist, what type each holds, and which are conditionally
  // required. Nothing here restates a question or an option code.

  /// The declared field contract, or null when the item is not a usable composite.
  Map<String, dynamic>? _compositeSchema(Map<String, dynamic> item) {
    if ((item['answer_kind'] as String? ?? '') != 'COMPOSITE') return null;
    final options = item['option_values'];
    if (options is! Map) return null;
    final schema = options['value_schema'];
    if (schema is! Map) return null;
    final fields = schema['fields'];
    if (fields is! List || fields.isEmpty) return null;
    return {
      'fields': fields,
      'conditional_required': schema['conditional_required'],
    };
  }

  List<Map<String, dynamic>> _compositeFields(Map<String, dynamic> item) {
    final schema = _compositeSchema(item);
    if (schema == null) return const <Map<String, dynamic>>[];
    return [
      for (final field in schema['fields'] as List)
        if (field is Map) Map<String, dynamic>.from(field),
    ];
  }

  Map<String, dynamic>? _compositeRule(Map<String, dynamic> item, String name) {
    final rules = _compositeSchema(item)?['conditional_required'];
    if (rules is! List) return null;
    for (final rule in rules) {
      if (rule is Map && rule['field'] == name && rule['when'] is Map) {
        return Map<String, dynamic>.from(rule);
      }
    }
    return null;
  }

  /// Does a `when` clause hold for the values currently entered?
  bool _compositeConditionMet(Map<String, dynamic> when, Map<String, dynamic> values) {
    final actual = values['${when['field']}'];
    if (when.containsKey('equals')) return '$actual' == '${when['equals']}';
    if (when.containsKey('in')) {
      final allowed = when['in'];
      return allowed is List && allowed.map((e) => '$e').contains('$actual');
    }
    if (when.containsKey('non_empty')) {
      final filled = actual is List
          ? actual.isNotEmpty
          : actual is String && actual.trim().isNotEmpty;
      return filled;
    }
    if (when.containsKey('contains')) {
      final target = '${when['contains']}';
      return actual is List && actual.map((e) => '$e').contains(target);
    }
    return false;
  }

  /// Required either unconditionally, or because a conditional rule fires.
  /// A conditional rule must never make its field universally mandatory.
  bool _compositeFieldRequired(Map<String, dynamic> item,
      Map<String, dynamic> field, Map<String, dynamic> values) {
    if (field['required'] == true) return true;
    final rule = _compositeRule(item, '${field['name']}');
    if (rule == null) return false;
    return _compositeConditionMet(Map<String, dynamic>.from(rule['when'] as Map), values);
  }

  /// A conditionally-gated field is shown once its rule fires, or when it
  /// already holds a saved value — a stored answer is never hidden from view.
  /// The field's label as the form shows it.
  ///
  /// A declared `label` always wins. Otherwise the field name is humanised, with
  /// the one case the name alone would misread: `amount_myr` is money, and
  /// "Amount myr" tells the reader nothing about the unit.
  String _compositeFieldLabel(Map<String, dynamic> field) {
    final declared = field['label'];
    if (declared is String && declared.trim().isNotEmpty) return declared;
    if ('${field['type']}' == 'AMOUNT_MYR') return 'Amount (RM)';
    return _humanise('${field['name']}');
  }

  bool _compositeFilled(String type, Object? value) {
    if (type == 'MULTI' || type == 'LIST') return value is List && value.isNotEmpty;
    return value is String && value.trim().isNotEmpty;
  }

  /// The exact reason this composite cannot be saved yet, or null when valid.
  String? _compositeError(Map<String, dynamic> item, Map<String, dynamic> values) {
    for (final field in _compositeFields(item)) {
      final name = '${field['name']}';
      final type = '${field['type']}';
      // The message must name the field the way the form does, or the reader
      // has to translate an internal key back into a label they can see.
      final fieldLabel = _compositeFieldLabel(field);
      final value = values[name];
      if (!_compositeFilled(type, value)) {
        if (_compositeFieldRequired(item, field, values)) return '$fieldLabel is required.';
        continue;
      }
      if (type == 'AMOUNT_MYR') {
        // Exact decimal text, never a double: the amount is money, and binary
        // floating point cannot represent 0.10 or 12.50 exactly.
        if (!RegExp(r'^\d{1,9}(\.\d{1,2})?$').hasMatch('$value'.trim())) {
          return '$fieldLabel must be an amount in RM with at most two decimals, '
              'for example 12.50.';
        }
      }
      final maxLength = field['max_length'];
      if (type == 'TEXT' && maxLength is int && value is String &&
          value.length > maxLength) {
        return '$fieldLabel must be $maxLength characters or fewer.';
      }
    }
    return null;
  }

  /// Serialise exactly the declared fields, omitting blanks. An absent optional
  /// field stays absent; it is never sent as an empty string.
  Map<String, dynamic> _compositeValue(
      Map<String, dynamic> item, Map<String, dynamic> values) {
    final out = <String, dynamic>{};
    for (final field in _compositeFields(item)) {
      final name = '${field['name']}';
      final type = '${field['type']}';
      final value = values[name];
      if (!_compositeFilled(type, value)) continue;
      if (type == 'MULTI') {
        out[name] = [for (final v in value as List) '$v'];
      } else if (type == 'LIST') {
        out[name] = [
          for (final row in value as List)
            if (row is Map)
              {
                for (final e in row.entries)
                  if ('${e.value}'.trim().isNotEmpty) '${e.key}': e.value,
              },
        ];
      } else if (type == 'AMOUNT_MYR') {
        out[name] = '$value'.trim();
      } else {
        out[name] = value;
      }
    }
    return out;
  }

  void _setComposite(String key, String name, Object? value) {
    setState(() {
      final current = _editorComposite[key] ?? <String, dynamic>{};
      _editorComposite[key] = {...current, name: value};
      _touched.add(key);
    });
    _scheduleAutoSave(textInput: true);
  }

  String _humanise(String code) {
    final text = code.replaceAll('_', ' ').toLowerCase();
    return text.isEmpty ? code : text[0].toUpperCase() + text.substring(1);
  }

  String _cardMode(Map<String, dynamic> item) {
    if (_applicable(item)) {
      final kind = item['answer_kind'] as String? ?? '';
      final hasInput = kind == 'TEXT' || kind == 'COMPOSITE' || _options(item).isNotEmpty;
      return hasInput ? 'answerable' : 'no_input';
    }
    final parent = _parentKey(item);
    if (parent == null) return 'inapplicable';
    final answer = _draft?.answers[parent];
    final parentAnswered = answer != null && answer['answer_state'] == 'ANSWERED';
    return parentAnswered ? 'inapplicable' : 'waiting';
  }

  String _parentTitle(Map<String, dynamic> item) {
    final parent = _parentKey(item);
    if (parent == null) return 'the earlier question';
    for (final other in _draft?.items ?? const <Map<String, dynamic>>[]) {
      if (other['item_key'] == parent) {
        return '$parent — ${other['title'] ?? ''}'.trim();
      }
    }
    return parent;
  }

  String _cardStatusLabel(Map<String, dynamic> item, String mode) {
    final requiredness = item['requiredness'] as String? ?? '';
    switch (mode) {
      case 'waiting':
        return 'Waiting on an earlier answer';
      case 'inapplicable':
        return 'Not applicable';
      case 'no_input':
        return 'No options in this instrument version';
      default:
        if (requiredness == 'OPTIONAL') return 'Optional';
        if (requiredness == 'CONDITIONAL') return 'Required if it applies';
        return 'Required';
    }
  }

  /// A skip is only offered when the backend actually accepts NOT_PROVIDED.
  bool _canSkip(Map<String, dynamic> item) {
    final requiredness = item['requiredness'] as String? ?? '';
    if (requiredness == 'REQUIRED') return false;
    return _allowedStates(item).contains('NOT_PROVIDED');
  }

  List<String> _allowedStates(Map<String, dynamic> item) {
    final raw = item['allowed_states'];
    var states = raw is List
        ? [for (final s in raw) if (s is String) s]
        : <String>['ANSWERED', 'NOT_PROVIDED'];
    if (states.isEmpty) states = ['ANSWERED', 'NOT_PROVIDED'];
    if (!_applicable(item)) {
      // validate_m2_answer rejects ANSWERED on an inapplicable conditional item,
      // so only the two non-substantive states may be offered.
      final allowed = [
        for (final s in states)
          if (s == 'NOT_APPLICABLE' || s == 'NOT_PROVIDED') s,
      ];
      // Never expose ANSWERED here: it can only fail server validation. If the
      // instrument omits both non-substantive states, NOT_PROVIDED is the
      // universally legal fallback.
      return allowed.isEmpty ? const ['NOT_PROVIDED'] : allowed;
    }
    return states;
  }

  bool _editable(Map<String, dynamic> item) {
    if (!_applicable(item)) return false;
    final kind = item['answer_kind'] as String? ?? '';
    if (kind == 'TEXT') return true;
    if (kind == 'COMPOSITE') return _compositeSchema(item) != null;
    if (kind == 'GEO') return _options(item).isNotEmpty;
    if (kind != 'SINGLE' && kind != 'MULTI') return false;
    return _options(item).isNotEmpty;
  }

  /// Whether the item's *state* may be recorded even when its value cannot be
  /// edited. An inapplicable conditional item must still be recordable as
  /// NOT_APPLICABLE, otherwise the assessment can never be completed: the
  /// notice would name a state that no control can set.
  bool _stateRecordable(Map<String, dynamic> item) =>
      _applicable(item) ? _editable(item) : true;

  /// Seeds every item's editor from the server truth. A saved answer seeds
  /// its item's state and value (accepting either `value_json` or `value`,
  /// per UI-11); a dependent selection the current parent answers no longer
  /// allow is dropped instead of silently retained (UI-03).
  void _seedEditors(M2Draft draft, {Set<String> preserve = const <String>{}}) {
    // Saving one question must not throw away edits the entrepreneur has made to
    // another. `preserve` names the items whose editor state is kept verbatim;
    // everything else is re-seeded from the server's authoritative answer.
    final keepState = {..._editorState};
    final keepCodes = {..._editorCodes};
    final keepText = {..._editorText};
    final keepComposite = {
      for (final e in _editorComposite.entries) e.key: {...e.value},
    };
    final keepTouched = {..._touched};
    _touched.clear();
    _editorState.clear();
    _editorCodes.clear();
    _editorText.clear();
    _editorComposite.clear();
    for (final raw in draft.items) {
      if ((raw['answer_kind'] as String? ?? '') == 'ACTION') continue;
      final key = raw['item_key'] as String;
      if (preserve.contains(key)) {
        _editorState[key] = keepState[key] ?? 'ANSWERED';
        _editorCodes[key] = keepCodes[key] ?? const <String>[];
        _editorText[key] = keepText[key] ?? '';
        _editorComposite[key] = keepComposite[key] ?? <String, dynamic>{};
        if (keepTouched.contains(key)) _touched.add(key);
        continue;
      }
      var state = _applicable(raw) ? 'ANSWERED' : 'NOT_APPLICABLE';
      final codes = <String>[];
      var text = '';
      final answer = draft.answers[key];
      if (answer is Map) {
        final saved = answer['answer_state'];
        if (saved is String && saved.isNotEmpty) state = saved;
        final allowed = _options(raw).map((o) => o['code']).toSet();
        final value = answer['value_json'] ?? answer['value'];
        if (value is List) {
          for (final v in value) {
            if (allowed.isEmpty || allowed.contains('$v')) codes.add('$v');
          }
        } else if (value is String && value.isNotEmpty) {
          text = value;
          if (allowed.isEmpty || allowed.contains(value)) codes.add(value);
        }
      }
      _editorState[key] = state;
      _editorCodes[key] = codes;
      _editorText[key] = text;
      if ((raw['answer_kind'] as String? ?? '') == 'COMPOSITE') {
        // Seeded verbatim from the server: an unseen field keeps whatever the
        // backend stored rather than being silently dropped.
        final stored = answer is Map
            ? (answer['value_json'] ?? answer['value'])
            : null;
        _editorComposite[key] = stored is Map
            ? {for (final e in stored.entries) '${e.key}': e.value}
            : <String, dynamic>{};
      }
    }
  }

  /// The exact value the API receives for the current editor state.
  ///
  /// DEF-UX-01: GEO is a bare string, like SINGLE. It used to fall through to
  /// the MULTI branch and send `["UNDECIDED"]`, which the backend rejects
  /// (`value == 'UNDECIDED'` is compared to a string). One serializer, used by
  /// both the save and the dirty check, so the two can never disagree.
  Object? _editorValue(Map<String, dynamic> item, String state) {
    if (state != 'ANSWERED') return null;
    final kind = item['answer_kind'] as String? ?? '';
    final key = item['item_key'] as String;
    final codes = _editorCodes[key] ?? const <String>[];
    if (kind == 'TEXT') return (_editorText[key] ?? '').trim();
    if (kind == 'COMPOSITE') {
      return _compositeValue(item, _editorComposite[key] ?? const <String, dynamic>{});
    }
    if (kind == 'SINGLE' || kind == 'GEO') {
      return codes.isEmpty ? null : codes.first;
    }
    return List<String>.unmodifiable(codes);
  }

  /// Mark an edited response for automatic persistence. The tick is rendered
  /// from server-acknowledged M2 answers, never optimistic local UI state.
  void _scheduleAutoSave({bool textInput = false}) {
    if (!component.embedded) return;
    component.onDeclarationEditing?.call();
    _pauseReady = false;
    final ticket = ++_autoSaveTicket;
    Future<void>.delayed(
      Duration(milliseconds: textInput ? 900 : 450),
      () async {
        if (!mounted || ticket != _autoSaveTicket) return;
        if (busy || _autoSaveInFlight) {
          _autoSaveQueued = true;
          return;
        }
        _autoSaveInFlight = true;
        try {
          await _saveAllDirty();
        } finally {
          _autoSaveInFlight = false;
          if (mounted && _autoSaveQueued) {
            _autoSaveQueued = false;
            _scheduleAutoSave();
          }
        }
      },
    );
  }

  /// Pause is a non-destructive action. Autosaved answers remain in Dss and
  /// the assessment may be reopened later. Never mark M2 confirmed here.
  Future<void> _pauseForNow() async {
    if (busy || _autoSaveInFlight || _draft == null) return;
    ++_autoSaveTicket; // Cancel a pending debounce before flushing.
    if (_dirtyCount() > 0) await _saveAllDirty();
    if (!mounted) return;
    if (_dirtyCount() > 0 || error != null) {
      setState(() {
        _pauseReady = false;
        error ??= 'Some answers could not be saved. Please retry before leaving.';
      });
      return;
    }
    setState(() {
      _pauseReady = true;
      notice = 'Your draft is saved. You can return to it later; this is not '
          'confirmation or permanent discard.';
    });
  }

  /// Does this card hold an edit the server has not accepted yet?
  bool _isDirty(Map<String, dynamic> item) {
    final draft = _draft;
    if (draft == null) return false;
    final key = item['item_key'] as String;
    // Nothing the entrepreneur has not touched can be an unsaved edit.
    if (!_touched.contains(key)) return false;
    final answer = draft.answers[key];
    final savedState =
        answer is Map ? (answer['answer_state'] as String? ?? '') : '';
    final state = _editorState[key] ?? savedState;
    if (state != savedState) return true;
    final saved = answer is Map ? (answer['value_json'] ?? answer['value']) : null;
    return !_sameValue(_editorValue(item, state), saved);
  }

  bool _sameValue(Object? a, Object? b) {
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if ('${a[i]}' != '${b[i]}') return false;
      }
      return true;
    }
    return '${a ?? ''}' == '${b ?? ''}';
  }

  Future<void> _saveAnswer(Map<String, dynamic> item, {String? overrideState}) async {
    final draft = _draft;
    if (draft == null || busy) return;
    if (!_editable(item) && !_stateRecordable(item)) return;
    final key = item['item_key'] as String;
    final state = overrideState ??
        _editorState[key] ??
        (!_applicable(item) ? 'NOT_APPLICABLE' : 'ANSWERED');
    // A composite is validated here as well as in the button, because the
    // autosave path reaches this method without going through the button.
    if (state == 'ANSWERED' &&
        (item['answer_kind'] as String? ?? '') == 'COMPOSITE') {
      final problem =
          _compositeError(item, _editorComposite[key] ?? const <String, dynamic>{});
      if (problem != null) {
        setState(() {
          // The card owns field-level messages, so the key is marked as being
          // edited: otherwise the save button is refused with the sentence
          // appearing only in the panel status line, away from the field.
          _touched.add(key);
          error = problem;
        });
        return;
      }
    }
    // UI-12 / DEF-UX-01: SINGLE and GEO are bare strings; MULTI is a list;
    // TEXT is its trimmed text.
    final Object? value = _editorValue(item, state);
    setState(() {
      busy = true;
      error = null;
      notice = '';
    });
    try {
      // Capture unsaved work in OTHER cards before the draft is replaced.
      final preserved = <String>{
        for (final other in draft.items)
          if ((other['item_key'] as String? ?? '') != key && _isDirty(other))
            other['item_key'] as String,
      };
      final updated = await AppLocator.m2.save(draft, key, state, value,
          marketplaceAssessmentId: component.marketplaceAssessmentId);
      if (!mounted) return;
      setState(() {
        _draft = updated;
        _confirmation = null;
        _reviewedRevision = null;
        _showReview = false;
        _seedEditors(updated, preserve: preserved);
        notice = preserved.isEmpty
            ? 'Saved $key. Server revision is now ${updated.revision}.'
            : 'Saved $key. ${preserved.length} other unsaved edit(s) were kept. '
                  'Server revision is now ${updated.revision}.';
      });
      // A stored answer is a new revision, so the concept the questionnaire
      // produces has changed. Rebuilding it here keeps the preview on the
      // revision the reader is looking at instead of the one they arrived with.
      unawaited(_loadConceptPreview());
      if (_dirtyCount() == 0) component.onDeclarationChanged?.call();
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'The answer was not saved. A stale revision or an invalid value '
              'is rejected by the server; reload the assessment before retrying.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  // --- workflow ------------------------------------------------------------

  /// Embedded Stage 2: entrepreneur confirmation must precede BDJ.
  /// Does not run deterministic or cloud BDJ. The backend must implement the
  /// corrected confirmation-first contract and refuse stale/unauthorized input.
  /// This method does not update legacy marketplace stage timestamps.
  String _confirmationError(Object failure) {
    if (failure is AppFailure) {
      var message = switch (failure.statusCode) {
        401 => 'Your session has expired. Sign in again, then reload saved declarations.',
        403 || 404 => 'This assessment is unavailable to your account. Reopen an assessment you own.',
        409 => 'The saved revision or confirmation state changed. Reload saved declarations before retrying.',
        422 => 'A declaration does not match the current questionnaire conditions. Review and save it again.',
        _ => failure is NetworkFailure
            ? 'The connection failed. The save outcome is unverified; reload saved confirmation before retrying.'
            : failure is ResponseFormatFailure
              ? 'The service response could not be verified. Reload saved confirmation before retrying.'
              : 'The confirmation service is unavailable. Your saved answers are retained; reload before retrying.',
      };
      final code = failure.backendCode;
      if (code != null && RegExp(r'^[A-Za-z0-9_.:-]{1,100}$').hasMatch(code)) message += ' Reference: $code.';
      return message;
    }
    return 'The service response could not be verified. Reload saved confirmation before retrying.';
  }

  Future<void> _reviewDeclarations() async {
    if (_draft == null || busy || _autoSaveInFlight) return;
    _autoSaveTicket++;
    if (_dirtyCount() > 0) await _saveAllDirty();
    if (!mounted || _draft == null || _dirtyCount() > 0 || error != null) return;
    final draft = _draft!;
    setState(() { busy = true; error = null; _showReview = false; });
    try {
      await AppLocator.m2.review(draft,
          marketplaceAssessmentId: component.marketplaceAssessmentId);
      if (!mounted || _draft?.id != draft.id || _draft?.revision != draft.revision) return;
      setState(() { _reviewedRevision = draft.revision; _showReview = true; });
    } catch (failure) {
      if (mounted) setState(() => error = _confirmationError(failure));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _confirmDeclarationBeforeBdj() async {
    final draft = _draft;
    if (draft == null || busy || _autoSaveInFlight) return;
    if (_dirtyCount() != 0 || _reviewedRevision != draft.revision) {
      setState(() => error =
          'Unsaved changes remain. Save and verify the current M2 revision before confirming.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
      notice = '';
    });
    try {
      // No finding acknowledgements are required to confirm entrepreneur
      // declarations. BDJ findings belong to the NEXT stage.
      await AppLocator.m2.confirm(draft, const <String>[],
          marketplaceAssessmentId: component.marketplaceAssessmentId);
      final persisted = await AppLocator.m2.currentConfirmation(draft.id);
      if (!mounted) return;
      if (persisted == null || persisted['assessment_revision'] != draft.revision) {
        throw StateError('The server did not return a current confirmation receipt.');
      }
      final current = await AppLocator.m2.read(draft.id);
      if (!mounted) return;
      if (current.revision != draft.revision) {
        throw StateError('M2 changed while confirmation was being recorded.');
      }
      setState(() {
        _draft = current;
        _confirmation = persisted;
        _showReview = false;
        notice = 'Business declaration confirmed at revision ${draft.revision}. '
            'Confirmation did not run BDJ. Open Stage 3 to continue.';
      });
      component.onDeclarationChanged?.call();
    } catch (failure) {
      if (mounted) {
        setState(() => error = _confirmationError(failure));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// Restore the persisted BCB status when a confirmed assessment is reopened.
  ///
  /// Read-only by construction: this calls the status endpoint and never the
  /// build endpoint, so merely opening the page cannot create a context, bump an
  /// attempt counter or write a revision. The entrepreneur is not asked to
  /// confirm again — a confirmation already exists and is the precondition for
  /// reading, not something the read should produce.
  ///
  /// Failure is silent on purpose: an unavailable optional context status must
  /// not prevent the saved declaration from being displayed.
  Future<void> _restoreContextStatus(int request) async {
    final draft = _draft;
    final confirmation = _confirmation;
    if (draft == null || confirmation == null) return;
    try {
      final status = await AppLocator.m2.contextStatus(
        draft.id,
        confirmation['id'] as String,
        draft.revision,
      );
      if (!mounted || request != _request) return;
      setState(() => _contextStatus = status);
    } catch (_) {
      // No persisted context, or the status surface is unavailable. Leave the
      // field null rather than inventing a state.
    }
  }

  /// One readable sentence for the persisted context, or null when there is
  /// nothing to say. STALE is called out explicitly: a context built from an
  /// earlier revision is not the same thing as a current one, and the raw
  /// `source_is_current` boolean is not a sentence an entrepreneur can act on.
  String? _contextSummary() {
    final status = _contextStatus;
    if (status == null) return null;
    final state = status['status'];
    final contextId = status['context_id'];
    final current = status['source_is_current'] == true;
    final lastCode = status['last_code'];
    switch (state) {
      case 'PERSISTED':
        if (!current) {
          return 'Business context ${contextId ?? ''} is STALE: it was built '
              'from an earlier revision and no longer matches the confirmed '
              'declaration.';
        }
        return 'Business context ${contextId ?? ''} is persisted and current '
            'for this confirmation.';
      case 'HELD':
        return 'Business context is HELD${lastCode == null ? '' : ' ($lastCode)'}'
            '. No context was built.';
      case 'FAILED':
        return 'Business context build FAILED'
            '${lastCode == null ? '' : ' ($lastCode)'}.';
      case 'PENDING':
        return 'Business context build is pending.';
      default:
        return 'Business context status: $state'
            '${lastCode == null ? '' : ' ($lastCode)'}.';
    }
  }

  /// Read the draft concept preview for the saved revision.
  ///
  /// `expected_revision` is the revision the card labels itself with, so the
  /// preview can never be presented against a revision it was not built from:
  /// the server refuses a mismatch with 409 rather than answering with whatever
  /// happens to be current. The request is read-only, which is why it is safe to
  /// run on open and after every successful save instead of behind a control the
  /// entrepreneur has to remember to press.
  Future<void> _loadConceptPreview() async {
    final draft = _draft;
    if (draft == null) return;
    final revision = draft.revision;
    final ticket = ++_conceptPreviewTicket;
    setState(() {
      _conceptPreviewLoading = true;
      _conceptPreviewError = null;
    });
    try {
      final body = await AppLocator.m2.conceptPreview(draft.id, revision);
      if (!mounted || ticket != _conceptPreviewTicket) return;
      // The draft may have advanced — or been replaced by another assessment —
      // while this request was in flight. A preview for a superseded revision
      // is stale by definition, so it is discarded rather than shown under the
      // current revision number.
      if (_draft?.id != draft.id || _draft?.revision != revision) return;
      setState(() {
        _conceptPreview = body;
        _conceptPreviewError = null;
      });
    } catch (failure) {
      if (!mounted || ticket != _conceptPreviewTicket) return;
      if (_draft?.id != draft.id || _draft?.revision != revision) return;
      setState(() {
        _conceptPreview = null;
        _conceptPreviewError = _conceptPreviewFailure(failure);
      });
    } finally {
      if (mounted && ticket == _conceptPreviewTicket) {
        setState(() => _conceptPreviewLoading = false);
      }
    }
  }

  /// Why the preview is absent, in terms the reader can act on.
  ///
  /// The endpoint separates a stale revision from an instrument that is not
  /// available to this account. Collapsing those into one sentence would tell
  /// the entrepreneur to reload when reloading cannot possibly help.
  String _conceptPreviewFailure(Object failure) {
    const tail = 'No confirmation and no business context were created.';
    if (failure is AppFailure) {
      final code = failure.backendCode;
      switch (code) {
        case 'M2_PREVIEW_STALE_REVISION':
          return 'The saved answers changed while the preview was being read, '
              'so it was discarded rather than shown against the wrong '
              'revision. $tail';
        case 'CONCEPT_PREVIEW_UNSUPPORTED_INSTRUMENT':
          return 'This assessment is not on the M2 V2 instrument, and the '
              'deterministic concept preview is defined for M2 V2 only. $tail';
        case 'M2_INSTRUMENT_UNAVAILABLE':
        case 'INSTRUMENT_UNAUTHORIZED':
          return 'The instrument version behind this assessment is not usable '
              'by this account, so no concept could be projected. $tail';
      }
      if (failure.statusCode == 404) {
        return 'This assessment is not readable by the signed-in account, so '
            'no concept was projected. $tail';
      }
      if (failure is NetworkFailure) {
        return 'The concept preview could not be reached. The saved answers are '
            'unaffected. $tail';
      }
      final reason = code ?? failure.statusCode?.toString();
      return 'The concept preview could not be read'
          '${reason == null ? '' : ' ($reason)'}. $tail';
    }
    return 'The concept preview could not be read. $tail';
  }

  /// The question text behind an item key, so a gap names the question the
  /// entrepreneur actually saw rather than an internal code alone.
  String _itemLabel(String key) {
    for (final item in _draft?.items ?? const <Map<String, dynamic>>[]) {
      if (item['item_key'] != key) continue;
      final title = item['title'] ?? item['question_text'];
      return title is String && title.isNotEmpty ? '$key — $title' : key;
    }
    return key;
  }

  List<String> _keyList(Object? raw) => [
    for (final entry in raw is List ? raw : const [])
      if (entry is String) entry,
  ];

  // --- rendering -----------------------------------------------------------

  Component _statusLine() {
    if (busy) {
      return p(classes: 'sr-muted', [Component.text('Working…')]);
    }
    if (error != null) {
      return p(classes: 'm1-error', [Component.text(error!)]);
    }
    if (notice.isNotEmpty) {
      return p(classes: 'm1-feedback', [Component.text(notice)]);
    }
    return p(classes: 'sr-muted', [
      Component.text('No action taken yet in this session.'),
    ]);
  }

  Component _chooser() {
    if (_assessments.isNotEmpty) {
      return div(classes: 'stack', [
        p(classes: 'sr-muted', [
          Component.text(
            'Saved M2 assessments for this account (server list).',
          ),
        ]),
        for (final row in _assessments)
          button(
            classes: 'sr-button${row['id'] == _selected ? ' sr-button--primary' : ''}',
            attributes: {'type': 'button'},
            onClick: busy ? null : () => _open(row['id'] as String),
            [
              Component.text(
                '${row['id']} · revision ${row['revision'] ?? '—'}',
              ),
            ],
          ),
      ]);
    }
    if (_instruments.isEmpty) {
      return p(classes: 'sr-muted', [
        Component.text(
          'No saved M2 assessment and no authorized instrument version was '
          'returned, so there is nothing to open. No questionnaire is created '
          'locally.',
        ),
      ]);
    }
    return div(classes: 'stack', [
      p(classes: 'sr-muted', [
        Component.text(
          'Start an M2 assessment from an authorized instrument version. The '
          'instrument, not this page, defines the questions.',
        ),
      ]),
      for (final row in _instruments)
        button(
          classes: 'sr-button',
          attributes: {'type': 'button'},
          onClick: busy ? null : () => _create(row['id'] as String),
          [
            Component.text(
              '${row['code'] ?? row['id']} · ${row['version_tag'] ?? ''} · '
              '${row['approval_state'] ?? ''}',
            ),
          ],
        ),
    ]);
  }

  Component _editor() {
    final draft = _draft;
    if (draft == null) {
      return p(classes: 'sr-muted', [
        Component.text('Select or create an M2 assessment to load its items.'),
      ]);
    }
    final items = _items;
    if (items.isEmpty) {
      return p(classes: 'sr-muted', [
        Component.text(
          'This instrument version exposes no questionnaire items.',
        ),
      ]);
    }
    // The instrument, not this page, defines the items and their order. What
    // this panel decides is only how they are presented: one question at a
    // time in the same card layout the Stage 2 questionnaire uses, instead of
    // every item stacked as its own editor. Eleven stacked editors made the
    // page read like a debug dump and hid the question that was actually being
    // answered.
    final index = _itemIndex.clamp(0, items.length - 1);
    final savedCount = items
        .where((item) => draft.answers.containsKey(item['item_key']))
        .length;
    // Progress is measured against what confirmation actually requires: an
    // applicable question marked effective_required by the server. Counting
    // inapplicable conditionals as "missing" made a complete draft look
    // unfinished, and counting raw saves flattered an empty one.
    final requiredItems =
        items.where((item) => item['effective_required'] == true).toList();
    final requiredAnswered = requiredItems
        .where((item) =>
            (draft.answers[item['item_key']]?['answer_state']) == 'ANSWERED')
        .length;
    final requiredTotal = requiredItems.length;
    return div(classes: 'asw-qlayout m2q', [
      // Left: the instrument's own item list.
      aside(classes: 'asw-qnav', [
        div(classes: 'asw-qnav__head', [
          h3(classes: 'asw-qnav__title', [
            Component.text('Questions (${items.length})'),
          ]),
          p(
            classes: 'small asw-muted',
            attributes: const {'aria-live': 'polite'},
            [
              Component.text(
                '$requiredAnswered of $requiredTotal required answered · '
                '$savedCount saved',
              ),
            ],
          ),
          div(
            classes: 'asw-qnav__rail',
            attributes: const {'aria-hidden': 'true'},
            [
              div(
                classes: 'asw-qnav__fill',
                styles: Styles(
                  width: Unit.percent(
                    requiredTotal == 0
                        ? 0
                        : requiredAnswered / requiredTotal * 100,
                  ),
                ),
                const [],
              ),
            ],
          ),
        ]),
        nav(
          classes: 'asw-qnav__list',
          attributes: const {'aria-label': 'Choose a questionnaire item'},
          [
            for (final (i, item) in items.indexed)
              button(
                classes: 'asw-qnav__item${i == index ? ' is-current' : ''}',
                attributes: {
                  'type': 'button',
                  if (i == index) 'aria-current': 'step',
                },
                events: events(
                  onClick: () => setState(() => _itemIndex = i),
                ),
                [
                  span(classes: 'asw-qnav__label', [
                    Component.text(item['item_key'] as String? ?? '—'),
                  ]),
                  span(classes: 'asw-qnav__state', [
                    Component.text(
                      _isDirty(item)
                          ? '…'
                          : draft.answers[item['item_key']]?['answer_state'] ==
                                  'ANSWERED'
                              ? '✓'
                              : '',
                    ),
                  ]),
                ],
              ),
          ],
        ),
        div(classes: 'asw-qnav__foot', [
          Component.text(
            'Assessment ${draft.id} · revision ${draft.revision}. The '
            'instrument defines these items and their order.',
          ),
        ]),
      ]),

      // Right: the current item.
      div(classes: 'asw-qcard', [
        _itemEditor(draft, items[index], index, items.length),
      ]),
    ]);
  }

  /// One instrument item in the question-card layout: the item key as the
  /// card's code, the prompt, the server-reported requiredness, the answer
  /// state the instrument allows, the option set and this item's own save
  /// control. Every value still comes from the server; nothing is inferred.
  /// Choices come from the declared `values`, or from the saved answer of the
  /// item named by `values_from` — never from a hardcoded option list.
  List<String> _compositeChoices(Map<String, dynamic> field) {
    final declared = field['values'];
    if (declared is List) return [for (final v in declared) '$v'];
    final source = field['values_from'];
    if (source is String) {
      final answer = _draft?.answers[source];
      final value = answer is Map ? (answer['value_json'] ?? answer['value']) : null;
      if (value is List) return [for (final v in value) '$v'];
    }
    return const <String>[];
  }

  Component _compositeEditor(Map<String, dynamic> item) {
    final key = item['item_key'] as String? ?? '';
    final values = _editorComposite[key] ?? const <String, dynamic>{};
    final state = _editorState[key] ?? 'ANSWERED';
    // Only complain about what the entrepreneur has actually started editing.
    final problem = _touched.contains(key) ? _compositeError(item, values) : null;
    return div(classes: 'asw-composite', [
      // Every declared field is rendered. The schema has one conditional idea —
      // `conditional_required` — and it governs requiredness, not existence:
      // hiding an optional field until its trigger fires made "details" (declared,
      // 4000 characters) impossible to write whenever the review was CONFIRMED.
      for (final field in _compositeFields(item))
        _compositeField(item, field, values, state),
      if (problem != null)
        p(classes: 'small', attributes: {'role': 'alert'}, [
          Component.text(problem),
        ]),
      div(classes: 'row', [
        button(
          classes: 'sr-button sr-button--primary',
          attributes: {'type': 'button', 'id': 'm2-save-$key'},
          onClick: (busy || state != 'ANSWERED' || problem != null)
              ? null
              : () => _saveAnswer(item),
          [Component.text('Save answer')],
        ),
        if (_canSkip(item))
          button(
            classes: 'sr-button',
            attributes: {'type': 'button'},
            onClick: busy
                ? null
                : () => _saveAnswer(item, overrideState: 'NOT_PROVIDED'),
            [Component.text('Not applicable')],
          ),
      ]),
    ]);
  }

  Component _compositeField(Map<String, dynamic> item, Map<String, dynamic> field,
      Map<String, dynamic> values, String state) {
    final key = item['item_key'] as String? ?? '';
    final name = '${field['name']}';
    final type = '${field['type']}';
    final fieldLabel = _compositeFieldLabel(field);
    final required = _compositeFieldRequired(item, field, values);
    final disabled = state != 'ANSWERED';
    final value = values[name];
    final id = 'm2-$key-$name';
    final selected = value is List ? [for (final v in value) '$v'] : const <String>[];

    Component choice(String code, bool multi) => label(
          classes: 'asw-answer${selected.contains(code) ? ' is-on' : ''}',
          [
            input<bool>(
              type: multi ? InputType.checkbox : InputType.radio,
              name: id,
              // Each choice needs its own id: one shared id across a radio or
              // checkbox group is invalid HTML and leaves `for` pointing at
              // nothing, so a label click would not reliably toggle its input.
              attributes: {'id': '$id-${code.toLowerCase()}'},
              checked: selected.contains(code),
              disabled: disabled,
              events: events(
                onChange: (_) {
                  if (multi) {
                    final next = [...selected];
                    if (next.contains(code)) {
                      next.remove(code);
                    } else {
                      next.add(code);
                    }
                    _setComposite(key, name, next);
                  } else {
                    _setComposite(key, name, code);
                  }
                },
              ),
            ),
            Component.text(_humanise(code)),
          ],
        );

    // `for` is only meaningful when the field renders one input carrying that
    // id. A choice group or a list has no single target, and pointing `for` at a
    // non-existent element is worse than having no `for` at all.
    final singleInput = type != 'ENUM' && type != 'MULTI' && type != 'LIST';
    return div(classes: 'asw-composite__field', [
      label(attributes: {if (singleInput) 'for': id}, [
        Component.text(required ? '$fieldLabel *' : fieldLabel),
      ]),
      if (type == 'ENUM' || type == 'MULTI')
        for (final code in _compositeChoices(field)) choice(code, type == 'MULTI')
      else if (type == 'LIST')
        _compositeList(item, field, values, state)
      else if (type == 'AMOUNT_MYR')
        // Money stays a single-line numeric field: a newline is not part of an
        // amount, and the decimal keyboard hint only means something on an input.
        input<String>(
          type: InputType.text,
          value: value is String ? value : '',
          attributes: {
            'id': id,
            'aria-label': fieldLabel,
            'inputmode': 'decimal',
            'placeholder': '0.00',
          },
          events: events<String>(onInput: (v) => _setComposite(key, name, v)),
        )
      else
        // TEXT is arbitrary text. A single-line input silently drops newlines,
        // so a note the entrepreneur wrote on two lines came back as one — the
        // stored value must be what was typed, not what an <input> can hold.
        textarea(
          rows: field['max_length'] is int && (field['max_length'] as int) > 200 ? 4 : 1,
          classes: 'm1-textarea',
          attributes: {'id': id, 'aria-label': fieldLabel},
          events: events<String>(onInput: (v) => _setComposite(key, name, v)),
          [Component.text(value is String ? value : '')],
        ),
    ]);
  }

  Component _compositeList(Map<String, dynamic> item, Map<String, dynamic> field,
      Map<String, dynamic> values, String state) {
    final key = item['item_key'] as String? ?? '';
    final name = '${field['name']}';
    final raw = values[name];
    final rows = raw is List
        ? [
            for (final row in raw)
              if (row is Map) Map<String, dynamic>.from(row),
          ]
        : <Map<String, dynamic>>[];
    final itemFields = field['item_fields'] is List
        ? [
            for (final sub in field['item_fields'] as List)
              if (sub is Map) Map<String, dynamic>.from(sub),
          ]
        : <Map<String, dynamic>>[];
    final disabled = state != 'ANSWERED';

    return div(classes: 'asw-composite__list', [
      for (var i = 0; i < rows.length; i++)
        div(classes: 'asw-composite__row', [
          for (final sub in itemFields)
            label([
              Component.text('${sub['label'] ?? _humanise('${sub['name']}')}'),
              input<String>(
                type: InputType.text,
                value: rows[i]['${sub['name']}'] is String
                    ? rows[i]['${sub['name']}'] as String
                    : '',
                attributes: {'aria-label': '${sub['name']} $i'},
                events: events<String>(
                  onInput: (v) {
                    final next = [for (final row in rows) {...row}];
                    next[i] = {...next[i], '${sub['name']}': v};
                    _setComposite(key, name, next);
                  },
                ),
              ),
            ]),
          button(
            classes: 'sr-button',
            attributes: {'type': 'button'},
            onClick: disabled
                ? null
                : () {
                    final next = [for (final row in rows) {...row}]
                      ..removeAt(i);
                    _setComposite(key, name, next);
                  },
            [Component.text('Remove')],
          ),
        ]),
      button(
        classes: 'sr-button',
        attributes: {'type': 'button'},
        onClick: disabled
            ? null
            : () {
                final next = [
                  for (final row in rows) {...row},
                  <String, dynamic>{},
                ];
                _setComposite(key, name, next);
              },
        [Component.text('Add ${_humanise(name)} entry')],
      ),
    ]);
  }

  Component _itemEditor(
    M2Draft draft,
    Map<String, dynamic> item,
    int index,
    int total,
  ) {
    final key = item['item_key'] as String? ?? '';
    final kind = item['answer_kind'] as String? ?? '';
    final options = _options(item);
    final editable = _editable(item);
    final multi = kind == 'MULTI';
    final state = _editorState[key] ??
        (!_applicable(item) ? 'NOT_APPLICABLE' : 'ANSWERED');
    final codes = _editorCodes[key] ?? const <String>[];
    final saved = draft.answers.containsKey(key) && !_isDirty(item);
    final mode = _cardMode(item);
    return div(attributes: {'id': 'm2-item-$key'}, [
      div(classes: 'asw-qcard__header', [
        span(classes: 'asw-qcard__code', [Component.text(key)]),
        span(classes: 'asw-qcard__position', [
          Component.text('Question ${index + 1} of $total'),
        ]),
        if (_isDirty(item))
          span(classes: 'small asw-muted', [
            Component.text(component.embedded
                ? '· saving automatically…'
                : '· unsaved changes'),
          ]),
      ]),
      h2(classes: 'asw-qcard__prompt', [
        Component.text(item['question_text'] as String? ?? ''),
      ]),
      p(classes: 'asw-qcard__help', [
        Component.text(
          'Requiredness ${item['requiredness'] ?? '—'} · input '
          '${kind.isEmpty ? '—' : kind}${saved ? ' · saved ✓' : ''}',
        ),
      ]),
      div(classes: 'asw-qcard__meta', [
        span(classes: 'asw-qcard__required', [
          Component.text(_cardStatusLabel(item, mode)),
        ]),
        span(classes: 'small asw-muted', [
          Component.text(
            mode == 'answerable'
                ? (multi
                      ? 'Select every answer that applies'
                      : 'Choose one answer')
                : '',
          ),
        ]),
      ]),
      if (mode == 'waiting')
        _infoNotice(
          'Answer ${_parentKey(item) ?? 'the earlier question'} first',
          'This question depends on ${_parentTitle(item)}. Its options appear '
              'once that answer is saved.',
        ),
      if (mode == 'inapplicable')
        _infoNotice(
          'Not applicable',
          'This question does not apply given your answer to '
              '${_parentTitle(item)}. You can move on.',
        ),
      if (mode == 'no_input')
        _infoNotice(
          'No answer set in this instrument version',
          'Nothing can be selected here. This is a property of the instrument, '
              'not a problem with your answer.',
        ),
      if (mode == 'inapplicable' && saved)
        _infoNotice(
          'A previous answer no longer applies',
          'You answered this before ${_parentTitle(item)} changed. It is not '
              'used while the question does not apply, and it has not been '
              'deleted.',
          action: (
            'Mark as not applicable',
            () => _saveAnswer(item, overrideState: 'NOT_APPLICABLE'),
          ),
        ),
      if (mode == 'answerable' && !editable)
        _infoNotice(
          'No answer set in this instrument version',
          'Nothing can be selected here.',
        ),
      div(classes: 'asw-qcard__answers', [
        if (mode == 'answerable' && kind == 'COMPOSITE')
          _compositeEditor(item)
        else if (mode == 'answerable' && kind == 'TEXT')
          textarea(
            rows: 5,
            classes: 'm1-textarea',
            attributes: {'aria-label': key},
            onInput: (value) {
              setState(() {
                _editorText[key] = value;
                _touched.add(key);
              });
              _scheduleAutoSave(textInput: true);
            },
            [Component.text(_editorText[key] ?? '')],
          )
        else if (mode == 'answerable')
          for (final option in options)
            label(
              classes:
                  'asw-answer${codes.contains(option['code']) ? ' is-on' : ''}',
              [
                input<bool>(
                  type: multi ? InputType.checkbox : InputType.radio,
                  name: 'm2-$key',
                  checked: codes.contains(option['code']),
                  disabled: state != 'ANSWERED',
                  events: events(
                    onChange: (_) {
                      setState(() {
                        final code = option['code'] as String;
                        final current = [...(_editorCodes[key] ?? const <String>[])];
                        if (multi) {
                          current.contains(code)
                              ? current.remove(code)
                              : current.add(code);
                        } else {
                          current
                            ..clear()
                            ..add(code);
                        }
                        _editorCodes[key] = current;
                        _touched.add(key);
                        _editorState[key] = 'ANSWERED';
                      });
                      _scheduleAutoSave();
                    },
                  ),
                ),
                span(classes: 'asw-answer__label', [
                  Component.text('${option['label'] ?? option['code']}'),
                ]),
              ],
            ),
      ]),
      // No "skip for now" affordance: an optional item is either answered or
      // left unanswered, and leaving it unanswered is already a valid state the
      // review step reports. An explicit skip button added a second way to say
      // the same thing, and a NOT_PROVIDED toggle that could be flipped back and
      // forth made the saved state harder to read than the answer itself.
      div(classes: 'asw-qcard__footer', [
        div(classes: 'asw-qcard__group', [
          ActionButton(
            'Previous',
            variant: 'secondary',
            onClick: index == 0
                ? null
                : () => setState(() => _itemIndex = index - 1),
          ),
        ]),
        div(classes: 'asw-qcard__group', [
          // One primary action per card: the forward step while there is one,
          // and the save itself on the last item. Two dark buttons side by side
          // read as a choice between two equally weighted actions, which is not
          // what this card offers.
          if (!component.embedded)
            ActionButton(
              busy ? 'Saving…' : 'Save answer',
              variant: index < total - 1 ? 'secondary' : 'primary',
              icon: 'save',
              onClick: busy ? null : () => _saveAnswer(item),
            ),
          if (index < total - 1)
            ActionButton(
              'Next question',
              icon: 'arrow_forward',
              onClick: () => setState(() => _itemIndex = index + 1),
            ),
        ]),
      ]),
      // Kept visible on purpose: this card writes to the real M2 router, and
      // the endpoint is how a reviewer checks that claim.
      if (!component.embedded)
        p(classes: 'small asw-muted m2q__endpoint', [
          Component.text(
            'Writes PUT /api/v1/m2/assessments/{id}/answers/$key',
          ),
        ]),
    ]);
  }

  Component _infoNotice(
    String title,
    String body, {
    (String, void Function())? action,
  }) => div(classes: 'notice', [
    p([Component.text(title)]),
    p(classes: 'small asw-muted', [Component.text(body)]),
    if (action != null)
      ActionButton(action.$1, variant: 'secondary', onClick: action.$2),
  ]);

  @override
  Component build(BuildContext context) => section(classes: 'stack stack--md', [
    if (!component.embedded) ...[
      h2([Component.text('M2 research workflow (live API)')]),
      p(classes: 'sr-muted', [
        Component.text(
          'Each control below calls the registered FastAPI M2 router. Blocked or '
          'unavailable steps say so instead of showing example data.',
        ),
      ]),
    ],
    _statusLine(),
    if (_unbound) _unboundNotice(),
    // The stepper comes before the stage body so a reader always knows which
    // stage they are looking at, and the Stage 2 questionnaire is only rendered
    // while Stage 2 is selected — otherwise the objectives on Stage 3 appear
    // underneath the declaration and read as part of it.
    if (!component.embedded && _draft != null) _stageStepper(),
    if (!_unbound && _draft == null) _chooser(),
    if (_draft != null) ...[
      if (component.embedded) ...[
        p(classes: 'small asw-muted', [
          Component.text(
            'M2 status: ${_m2StatusLabel()}'
            '${_savedRevision == null ? '' : ' · saved at revision $_savedRevision'}',
          ),
        ]),
        _saveBar(),
      ],
      if (component.embedded || _stage == '2') _editor(),
      if (component.embedded &&
          (_m2StatusLabel() == 'Confirmed' ||
              _m2StatusLabel().startsWith('Required answers complete')))
        _reviewSection(),
      if (!component.embedded) ...[
        if (_stage == '2') ...[
          _reviewSection(),
          p(classes: 'sr-muted', [Component.text(
            'Stage 2 records what the business is. The research objectives that '
            'follow from it are reviewed on Stage 3.',
          )]),
          p(classes: 'sr-muted', [
            Component.text(
              'Recorded activity is read-only and lives on the Activity History '
              'surface.',
            ),
          ]),
          a(
            href: '/entrepreneur/activity-history?assessment=$_selected',
            classes: 'sr-button',
            [Component.text('Open Activity History for this assessment')],
          ),
        ] else if (_stage == '4')
          _stageFourBody()
        else if (_stage == '5')
          _stageFiveBody()
        else
          _stageThreeBody(),
      ],
    ],
  ]);

  /// The deterministic draft concept, shown before the M2-21 confirm control.
  ///
  /// This is the pre-confirmation view of what the saved answers currently
  /// amount to. It is deliberately separate from the M2V2-12 review action:
  /// review is a server-side record written against a revision, whereas this
  /// card is a read-only projection of that same revision. Confirming from here
  /// is impossible — the card has no confirm control, and the endpoint it reads
  /// cannot create a confirmation or a business context.
  Component _conceptPreviewCard() {
    final draft = _draft;
    if (draft == null) return div(const []);
    final preview = _conceptPreview;
    final current = preview != null &&
        preview['assessment_id'] == draft.id &&
        preview['assessment_revision'] == draft.revision;
    final text = preview?['preview_text'];
    return div(classes: 'stack stack--sm', [
      h3([Component.text('Draft concept preview')]),
      p(classes: 'small asw-muted', [
        Component.text(
          'A deterministic projection of the answers saved at revision '
          '${draft.revision}, built from the same fields the confirmed '
          'business context uses. Reading it writes nothing.',
        ),
      ]),
      if (_conceptPreviewLoading && preview == null)
        p(classes: 'small asw-muted', [
          Component.text('Building the preview from the saved answers…'),
        ]),
      if (_conceptPreviewError != null)
        div(classes: 'm1-notice', [Component.text(_conceptPreviewError!)]),
      if (current && text is String && text.trim().isNotEmpty) ...[
        div(classes: 'm1-notice', [
          p([Component.text(text.trim())]),
        ]),
        p(classes: 'small asw-muted', [
          Component.text(
            'Revision ${preview['assessment_revision']} · '
            'contract ${preview['contract_version']} · '
            'instrument ${_previewInstrument(preview)} · '
            'confirmed revision ${preview['confirmed_revision'] ?? 'none'}',
          ),
        ]),
      ] else if (current)
        div(classes: 'm1-notice', [
          Component.text(
            'No description can be projected yet: the saved answers do not '
            'supply any of the fields the concept is built from. Answering more '
            'questions will fill it in.',
          ),
        ]),
      if (current) ..._previewGaps(preview),
      div(classes: 'actions-row', [
        ActionButton(
          'Refresh preview',
          variant: 'secondary',
          onClick: busy || _conceptPreviewLoading ? null : _loadConceptPreview,
        ),
        if (_conceptPreviewLoading)
          p(classes: 'small asw-muted', [Component.text('Refreshing…')]),
      ]),
      p(classes: 'small asw-muted', [
        Component.text(
          'This card creates no confirmation and no business context.'
          '${current ? ' Server-reported: creates_confirmation = '
                '${preview['creates_confirmation']}, creates_business_context = '
                '${preview['creates_business_context']}, model_invoked = '
                '${preview['model_invoked']}.' : ''}',
        ),
      ]),
    ]);
  }

  /// Instrument identity, so the preview names the version it was projected
  /// from rather than implying every M2 assessment produces the same concept.
  String _previewInstrument(Map<String, dynamic> preview) {
    final instrument = preview['instrument'];
    if (instrument is! Map) return '—';
    final tag = instrument['version_tag'];
    final approval = instrument['approval_state'];
    if (tag is! String) return '—';
    return approval is String ? '$tag ($approval)' : tag;
  }

  /// Every gap the projection reports, each kind kept separate.
  ///
  /// "Not decided" is a decision the entrepreneur made, so it is never listed as
  /// missing information. "Not applicable" is the instrument's own ruling, not an
  /// omission. Merging the kinds would turn a deliberate answer into a defect.
  List<Component> _previewGaps(Map<String, dynamic> preview) {
    final undecided = _keyList(preview['undecided_inputs']);
    final skipped = _keyList(preview['skipped_inputs']);
    final absent = _keyList(preview['absent_inputs']);
    final notApplicable = _keyList(preview['not_applicable_inputs']);
    final unmapped = _keyList(preview['unmapped_item_keys']);
    if (undecided.isEmpty &&
        skipped.isEmpty &&
        absent.isEmpty &&
        notApplicable.isEmpty &&
        unmapped.isEmpty) {
      return [
        p(classes: 'small asw-muted', [
          Component.text('No gaps reported: every projection input is accounted for.'),
        ]),
      ];
    }
    return [
      if (undecided.isNotEmpty)
        _previewGapGroup(
          'Not decided yet — recorded as undecided, not as missing',
          undecided,
        ),
      if (skipped.isNotEmpty)
        _previewGapGroup('Deliberately not provided', skipped),
      if (absent.isNotEmpty)
        _previewGapGroup('Never answered', absent),
      if (notApplicable.isNotEmpty)
        _previewGapGroup('Not applicable to these answers', notApplicable),
      if (unmapped.isNotEmpty)
        _previewGapGroup('Answered, but outside the concept projection', unmapped),
    ];
  }

  Component _previewGapGroup(String heading, List<String> keys) =>
      div(classes: 'stack stack--xs', [
        p(classes: 'small', [Component.text('$heading (${keys.length})')]),
        for (final key in keys)
          p(classes: 'small asw-muted', [Component.text(_itemLabel(key))]),
      ]);

  /// Review-then-confirm, using the existing M2-20 / M2-21 endpoints.
  ///
  /// The summary is read-only and comes from the saved answers. Confirming is a
  /// separate button and never follows automatically from saving or reviewing.
  /// Two governed stages on the standalone page.
  ///
  /// Stage 2 is the declaration and its confirmation. Stage 3 is the
  /// research-objective review that the confirmation makes possible. The
  /// stepper reports which one is on screen and whether Stage 3 is reachable
  /// yet; it never blocks a read, because the proposal panel already refuses a
  /// proposal whose confirmation is not current.
  ///
  /// Stages 4 and 5 stay enterable even while they are blocked. Entering a
  /// stage is not completing it: the Stage 4 and Stage 5 panels read the server
  /// and name the exact gate that is holding them, which is more useful to a
  /// reader than a disabled tab with no explanation.
  Component _stageStepper() {
    final confirmed = _m2StatusLabel() == 'Confirmed';
    Component pill(String value, String label, String hint, {bool enabled = true}) {
      final active = _stage == value;
      return button(
        classes: 'tab${active ? ' is-active' : ''}'
            '${enabled ? '' : ' is-disabled'}',
        attributes: {
          'type': 'button',
          'aria-pressed': active ? 'true' : 'false',
          'aria-current': active ? 'step' : 'false',
          'title': hint,
          if (!enabled) 'disabled': 'true',
        },
        events: enabled
            ? events(onClick: () => setState(() => _stage = value))
            : null,
        [Component.text(label)],
      );
    }

    return section(classes: 'panel asw-inline', [
      div(classes: 'panel__body stack stack--sm', [
        div(classes: 'asw-stage-switch', [
          pill('2', 'Stage 2 · Business declaration',
              'Answer the M2 instrument and confirm what the business is.'),
          pill(
            '3',
            'Stage 3 · Research objectives',
            confirmed
                ? 'Review the research objectives proposed from this confirmation.'
                : 'Confirm the declaration on Stage 2 first.',
            enabled: confirmed,
          ),
          pill(
            '4',
            'Stage 4 · Question review',
            'Review the question candidates prepared from an admitted objective. '
            'A blocked stage reports the gate that is holding it.',
          ),
          pill(
            '5',
            'Stage 5 · Questionnaire preview',
            'Preview the draft questionnaire assembled from accepted questions. '
            'A preview is not a fielding surface.',
          ),
        ]),
        p(classes: 'sr-muted', [
          Component.text(switch (_stage) {
            '3' => confirmed
                ? 'The declaration is confirmed. Stage 3 lists the research '
                    'objectives proposed from it.'
                : 'Confirm the declaration on Stage 2 to unlock Stage 3.',
            '4' => 'Stage 4 shows the question candidates for an admitted '
                'objective, with your review decision. It prepares no question '
                'of its own.',
            '5' => 'Stage 5 is a draft preview of the questionnaire. It creates '
                'no session, no customer response and no fielding campaign.',
            _ => confirmed
                ? 'The declaration is confirmed.'
                : 'Confirm the declaration on Stage 2 to unlock Stage 3.',
          }),
        ]),
      ]),
    ]);
  }

  /// Stage 3 — the research objectives proposed from the current confirmation.
  ///
  /// The governed panel is reused unchanged: it verifies ownership, a current
  /// confirmation, the persisted BCB context and source integrity before
  /// rendering a single proposal, and it creates no assessment row and rewrites
  /// no link. This method only decides *where* it appears, not what it may say.
  Component _stageThreeBody() {
    if (_selected.isEmpty) {
      return section(classes: 'panel asw-inline', [
        div(classes: 'panel__body', [
          p(classes: 'body', [
            Component.text(
              'Select an M2 assessment on Stage 2 before reviewing research '
              'objectives.',
            ),
          ]),
        ]),
      ]);
    }
    return section(classes: 'stack stack--md', [
      _stageThreeProvenance(),
      BdjObjectiveProposalPanel(m2AssessmentId: _selected),
      p(classes: 'sr-muted', [
        Component.text(
          'Proposals are candidate objectives for review. Approving one records '
          'your decision; it does not authorize question generation, fielding or '
          'any customer contact.',
        ),
      ]),
    ]);
  }

  /// The confirmation and business context the Stage 3 proposals come from.
  ///
  /// Read-only, and deliberately the same two statements Stage 2 prints, so a
  /// reviewer cannot see a proposal on Stage 3 without also seeing which
  /// confirmation produced it. Nothing is fetched here: both values were loaded
  /// with the assessment, and an absent value prints nothing rather than an
  /// invented identity.
  Component _stageThreeProvenance() {
    if (_confirmation == null) return div(const []);
    return section(classes: 'panel asw-inline', [
      div(classes: 'panel__body stack stack--sm', [
        h2([Component.text('Proposals derived from this confirmation')]),
        p([Component.text(
          'Confirmation ${_confirmation!['id']} · revision '
          '${_confirmation!['assessment_revision']}',
        )]),
        if (_contextSummary() != null)
          p(classes: 'small asw-muted', [Component.text(_contextSummary()!)]),
      ]),
    ]);
  }

  /// Stage 4 — question review.
  ///
  /// The revision and context passed down are the ones this page already
  /// verified: the saved draft revision and the persisted BCB context. When
  /// either is missing the stage says so instead of reading with a guessed
  /// identity, because an admission lookup against a stale revision would
  /// return nothing and read as "no proposals".
  Component _stageFourBody() {
    if (_selected.isEmpty) {
      return section(classes: 'panel asw-inline', [
        div(classes: 'panel__body', [
          p(classes: 'body', [
            Component.text(
              'Select an M2 assessment on Stage 2 before reviewing questions.',
            ),
          ]),
        ]),
      ]);
    }
    final draft = _draft;
    final contextId = _contextStatus?['context_id'];
    if (draft == null || contextId is! String || contextId.isEmpty) {
      return section(classes: 'stack stack--md', [
        section(classes: 'panel asw-inline', [
          div(classes: 'panel__body stack stack--sm', [
            h2([Component.text('Question review')]),
            p(classes: 'body', [
              Component.text(
                'Stage 4 reads admissions against a persisted business context. '
                'No current context is available for this confirmation, so there '
                'is no admission to review and no question is shown.',
              ),
            ]),
          ]),
        ]),
      ]);
    }
    return section(classes: 'stack stack--md', [
      StageFourQuestionReview(
        // Keyed by assessment and revision: a new revision must not reuse the
        // previous revision's admission or decision state.
        key: ValueKey('s4-$_selected-${draft.revision}'),
        m2AssessmentId: _selected,
        expectedRevision: draft.revision,
        contextId: contextId,
      ),
      p(classes: 'sr-muted', [
        Component.text(
          'A review decision records your judgement about a candidate question. '
          'It does not accept the question scientifically and does not authorise '
          'fielding.',
        ),
      ]),
    ]);
  }

  /// Stage 5 — questionnaire preview.
  ///
  /// The preview is assembled by the server from accepted question rows. This
  /// method passes only the assessment id: the server decides what is
  /// previewable, so a stale confirmation or an absent admitted objective is
  /// reported as the reason rather than rendered as an empty questionnaire.
  Component _stageFiveBody() {
    if (_selected.isEmpty) {
      return section(classes: 'panel asw-inline', [
        div(classes: 'panel__body', [
          p(classes: 'body', [
            Component.text(
              'Select an M2 assessment on Stage 2 before previewing a '
              'questionnaire.',
            ),
          ]),
        ]),
      ]);
    }
    return section(classes: 'stack stack--md', [
      StageFiveQuestionnairePreview(
        key: ValueKey('s5-$_selected'),
        m2AssessmentId: _selected,
      ),
    ]);
  }

  Component _reviewSection() {
    final draft = _draft;
    if (draft == null) return div(const []);
    final confirmed = _m2StatusLabel() == 'Confirmed';
    return section(classes: 'panel asw-inline', [
      h2([Component.text('Business declaration review')]),
      p([Component.text('Saved M2 revision ${draft.revision}')]),
      if (_confirmation != null)
        p([Component.text('Confirmation ${_confirmation!['id']} · revision ${_confirmation!['assessment_revision']}')]),
      // Persisted business context for the confirmation above, restored when the
      // page opens. Read-only: it reports what already exists and never starts a
      // build. Absent until a context has actually been persisted, so it cannot
      // imply a context that does not exist.
      if (_confirmation != null && _contextSummary() != null)
        p(classes: 'small asw-muted', [Component.text(_contextSummary()!)]),
      div(classes: 'panel__body stack stack--md', [
        if (confirmed)
          p(classes: 'small asw-muted', [
            Component.text(
              'This business declaration is confirmed. Editing an answer will '
              'make the confirmation stale until it is reviewed again.',
            ),
          ])
        else ...[
          p(classes: 'small asw-muted', [
            Component.text(
              'Check the answers below, then confirm. Saving a draft never '
              'confirms the declaration.',
            ),
          ]),
          // Shown before the M2V2-12 review action and before M2-21 confirm:
          // the entrepreneur reads the concept the questionnaire produced and
          // corrects the answers, rather than confirming to find out.
          _conceptPreviewCard(),
          if (_showReview)
            for (final item in draft.items)
              if (item['answer_kind'] != 'ACTION' &&
                  draft.answers.containsKey(item['item_key']))
                p(classes: 'small', [
                  Component.text(
                    '${item['item_key']} · '
                    '${draft.answers[item['item_key']]?['answer_state']} · '
                    '${draft.answers[item['item_key']]?['value_json'] ?? '—'}',
                  ),
                ]),
          ActionButton(
            'Review business declaration',
            variant: 'secondary',
            onClick: busy || _autoSaveInFlight ? null : _reviewDeclarations,
          ),
          if (_showReview)
            ActionButton(
              'Confirm business declaration',
              icon: 'verified',
              onClick: busy || _autoSaveInFlight || _dirtyCount() > 0 || _reviewedRevision != draft.revision
                  ? null
                  : _confirmDeclarationBeforeBdj,
            ),
        ],
      ]),
    ]);
  }

  /// The M2 record's own status, independent of the five marketplace stages.
  String _m2StatusLabel() {
    final draft = _draft;
    if (draft == null) return 'Not started';
    final assessment = (draft.data['assessment'] as Map?) ?? const {};
    final confirmed = assessment['confirmed_revision'];
    if ((confirmed != null && confirmed == draft.revision) || _confirmation?['assessment_revision'] == draft.revision) return 'Confirmed';
    final missing = draft.items
        .where((item) =>
            item['effective_required'] == true &&
            (draft.answers[item['item_key']]?['answer_state']) != 'ANSWERED')
        .length;
    if (missing == 0) return 'Required answers complete — ready for review';
    return 'Draft in progress — $missing required answer(s) outstanding';
  }

  /// The Assessment tab's persistent action area.
  ///
  /// Saving here writes every changed answer through the existing revision API.
  /// It is explicitly **not** confirmation: no review event, no snapshot, no
  /// downstream stage is started.
  Component _saveBar() => div(classes: 'actions-row', [
    // Automatic persistence is the default in the embedded assessment flow.
    // This status never claims success while a request is pending or failed.
    p(classes: 'small asw-muted', [
      Component.text(
        error != null
            ? 'Autosave needs attention — see the error below.'
            : busy || _autoSaveInFlight
                ? 'Saving answers…'
                : _dirtyCount() > 0
                    ? 'Changes waiting to save…'
                    : 'Draft up to date',
      ),
    ]),
    ActionButton(
      'Pause for now',
      icon: 'save',
      variant: 'secondary',
      onClick: busy || _autoSaveInFlight ? null : _pauseForNow,
    ),
    if (_pauseReady)
      a(
        href: '/entrepreneur/assessments',
        classes: 'sr-button',
        [Component.text('Return to assessments')],
      ),
  ]);

  int _dirtyCount() {
    final draft = _draft;
    if (draft == null) return 0;
    return draft.items.where(_isDirty).length;
  }

  /// Persist every changed answer, one revision at a time.
  ///
  /// Deliberately not a batch: the existing contract is one answer per request
  /// with an optimistic revision check, and inventing a multi-answer endpoint
  /// would be a new contract. Failures are reported individually and nothing is
  /// ever rolled back silently — the revision that succeeded stays saved.
  Future<void> _saveAllDirty() async {
    if (_draft == null || busy) return;
    // Item keys sort in dependency order (M2V1-04 before 05, 09 before 10 before
    // 11), so a parent is always written before the child that depends on it.
    final dirtyKeys = [
      for (final item in _draft!.items)
        if (_isDirty(item)) item['item_key'] as String,
    ]..sort();
    if (dirtyKeys.isEmpty) {
      setState(() {
        error = null;
        notice = 'No changes to save.';
      });
      component.onDeclarationChanged?.call();
      return;
    }
    setState(() {
      busy = true;
      error = null;
      notice = '';
    });
    var saved = 0;
    final failed = <String>[];
    final failureMessages = <String>[];
    final skipped = <String>[];
    for (final key in dirtyKeys) {
      Map<String, dynamic>? fresh;
      for (final candidate in _draft!.items) {
        if (candidate['item_key'] == key) {
          fresh = candidate;
          break;
        }
      }
      if (fresh == null) continue;
      final state = _editorState[key] ?? 'ANSWERED';
      // An earlier save in this same round may have changed the parent and made
      // this item inapplicable. Submitting the stale value would be rejected.
      if (state == 'ANSWERED' && !_applicable(fresh)) {
        skipped.add(key);
        continue;
      }
      final value = _editorValue(fresh, state);
      try {
        final updated = await AppLocator.m2.save(_draft!, key, state, value,
            marketplaceAssessmentId: component.marketplaceAssessmentId);
        if (!mounted) return;
        _draft = updated;
        _confirmation = null;
        _reviewedRevision = null;
        _showReview = false;
        saved++;
      } catch (failure) {
        failed.add(key);
        if (failure is AppFailure) {
          final code = failure.backendCode;
          final guidance = code == 'REVISION_CONFLICT'
              ? 'Reload the current assessment revision.' : failure.userMessage;
          failureMessages.add('$guidance${code == null ? '' : ' ($code)'}');
        } else {
          failureMessages.add('The answer could not be verified.');
        }
      }
    }
    if (!mounted) return;
    setState(() {
      if (_draft != null) {
        // An edit made while a network save was in flight must not be lost
        // when the authoritative response re-seeds the editor.
        final changedAfterRequest = {
          for (final item in _draft!.items)
            if (_isDirty(item)) item['item_key'] as String,
        };
        _seedEditors(_draft!, preserve: {
          ...failed,
          ...skipped,
          ...changedAfterRequest,
        });
      }
      busy = false;
      _savedRevision = _draft?.revision;
      if (failed.isEmpty && skipped.isEmpty) {
        notice = 'Assessment draft saved successfully.';
      } else if (failed.isEmpty) {
        notice = 'Assessment draft saved. ${skipped.length} answer(s) no longer '
            'apply and were left unchanged.';
      } else {
        error = 'Draft partially saved: $saved stored, ${failed.length} not '
            'stored (${failed.join(', ')}). Your edits for those questions are '
            'kept. ${failureMessages.toSet().join(' ')}';
      }
    });
    if (_dirtyCount() == 0) component.onDeclarationChanged?.call();
    // Only re-read when something was actually stored: a fully failed round
    // leaves the revision untouched, and refetching would replace a readable
    // preview with a spinner for no new information.
    if (saved > 0) unawaited(_loadConceptPreview());
  }

  /// DEF-11 unbound state.
  ///
  /// Deliberately contains **no** questionnaire and **no** save control. The
  /// directive requires that an assessment without a verified M2 link shows a
  /// clear message rather than an editable instrument — showing one would let
  /// an entrepreneur answer into a record that does not belong to this
  /// assessment.
  Component _unboundNotice() => div(classes: 'bdj-empty', [
    p(classes: 'bdj-empty__title', [
      Component.text('This assessment is not linked to an M2 research assessment'),
    ]),
    p(classes: 'bdj-empty__body', [
      Component.text(
        'No verified link exists between this location assessment and an M2 '
        'business-declaration record, so no questionnaire is shown and no '
        'answer can be saved here. The panel will not borrow another '
        'assessment\'s answers.',
      ),
    ]),
    p(classes: 'bdj-empty__body', [
      Component.text(
        'Existing M2 assessments are untouched. This page will show the '
        'questionnaire once a verified link exists; until then no answer can '
        'be written from here.',
      ),
    ]),
  ]);
}
