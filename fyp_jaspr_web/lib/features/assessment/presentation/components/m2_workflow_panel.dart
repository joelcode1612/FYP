import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart' show M2Draft, AppFailure, NetworkFailure, ResponseFormatFailure;

import 'package:sitewise_jaspr_web/core/di/app_locator.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/components/m2_sample_guidance.dart';
// The four stage panels this file used to import (the BDJ objective proposals,
// the research candidate panel, the Stage 4 question review and the Stage 5
// questionnaire preview) were mounted only by the standalone branches removed
// above. The files themselves are untouched: ``research_workflow_panel.dart``
// keeps its own tests, and the other three are still mounted by the stage pages.
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

  /// Kept for standalone M2 workflow's manual discard-edits action.
  ///
  /// The staged layout below does not render that action, so nothing assigns
  /// this field today. It is retained rather than deleted because the discard
  /// path is expected to return with the staged editor; removing it would also
  /// remove the only record of what the action was for.
  // ignore: unused_field
  bool _discardArmed = false;

  /// Whether the read-only review summary is expanded.
  bool _showReview = false;
  int? _reviewedRevision;


  /// Which instrument item the question card shows. The instrument decides how
  /// many there are; this index is only the position on screen.
  int _itemIndex = 0;

  Map<String, dynamic>? _worksheet;
  /// UI-01: finding decisions persisted for the current revision, by finding id.
  /// Only codes the backend accepts are ever stored here.
  Map<String, String> _decisions = {};
  Map<String, dynamic>? _confirmation;
  Map<String, dynamic>? _contextStatus;

  /// The exact AI-processing terms this release discloses, read from the
  /// server. The client never composes them: it shows what it was given and
  /// echoes it back unchanged, because the server refuses any disagreement.
  Map<String, dynamic>? _aiDisclosure;
  String? _aiDisclosureError;

  /// The owner's AI-processing decision for the next confirmation.
  ///
  /// Starts false, always. The snapshot records an omitted control as
  /// NOT_GRANTED, so a pre-checked box would turn "did nothing" into a grant —
  /// and no consent may ever be inferred from the act of confirming.
  bool _aiConsent = false;

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
      _worksheet = null;
      _decisions = {};
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
    // CP-10 DEF-06 state restoration: worksheet and confirmation are server
    // state and must survive a reload. Without this, 'Save research
    // objective' was permanently dead after any reload while the server
    // honestly refuses a duplicate confirm — the objective was unreachable.
    if (!component.embedded) {
      try {
        final sheet = await AppLocator.m2.worksheet(draft);
        if (!mounted || request != _request) return;
        if (sheet['revision'] == draft.revision) {
          _worksheet = sheet;
        }
      } catch (_) {
        // No worksheet is available; do not fabricate one.
      }
    }
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
    // DD-063: a GEO item is answered from the approved GEO_V1 catalogue, which
    // the server attaches as `effective_geography` when the stored definition
    // declares AUTHORITY_UNVERIFIED. The catalogue's own `area_ref` is the
    // option code and its jurisdiction name is the label; no area is invented.
    // When no catalogue is served the single "not decided" choice remains the
    // only authorized answer, because the backend would refuse anything else.
    if ((item['answer_kind'] as String? ?? '') == 'GEO') {
      final areas = _geography(item)?['areas'];
      final options = <Map<String, dynamic>>[
        for (final area in areas is List ? areas : const [])
          if (area is Map && area['area_ref'] is String)
            {
              'code': area['area_ref'] as String,
              'label': area['jurisdiction'] is String
                  ? area['jurisdiction'] as String
                  : area['area_ref'] as String,
            },
      ];
      if (options.isNotEmpty) {
        return [
          ...options,
          {'code': 'UNDECIDED', 'label': 'Not decided yet'},
        ];
      }
      return const [
        {'code': 'UNDECIDED', 'label': 'Not decided yet'},
      ];
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

  /// The verified geography catalogue for a GEO item, or null when none applies.
  ///
  /// DD-063: the server serves the approved GEO_V1 catalogue as
  /// `effective_geography` when the stored definition declares
  /// AUTHORITY_UNVERIFIED. A stored verified block is used when the server sends
  /// no overlay, so an instrument that ships its own catalogue keeps working.
  Map<String, dynamic>? _geography(Map<String, dynamic> item) {
    final served = item['effective_geography'];
    if (served is Map && served['status'] == 'VERIFIED') {
      return served.cast<String, dynamic>();
    }
    final stored = _rules(item)['geography'];
    if (stored is Map && stored['status'] == 'VERIFIED') {
      return stored.cast<String, dynamic>();
    }
    return null;
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
        } else if (value is Map && (raw['answer_kind'] as String? ?? '') == 'GEO') {
          // DD-063: a stored GEO answer is the structured catalogue entry, while
          // the editor works in area references. Seed the selection from it so a
          // reload shows the area the entrepreneur already chose.
          final ref = value['area_ref'];
          if (ref is String && (allowed.isEmpty || allowed.contains(ref))) {
            codes.add(ref);
          }
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
  /// DEF-UX-01: GEO used to be sent as a bare string like SINGLE, which fell
  /// through to the MULTI branch and sent `["UNDECIDED"]` — rejected by the
  /// backend, because `value == 'UNDECIDED'` is compared to a string. It is now
  /// serialized explicitly: `UNDECIDED` stays the literal string the validator
  /// accepts, and a selected area becomes the exact
  /// `{jurisdiction, area_ref, catalogue_version}` entry from the served GEO_V1
  /// catalogue (DD-063). One serializer, used by both the save and the dirty
  /// check, so the two can never disagree.
  Object? _editorValue(Map<String, dynamic> item, String state) {
    if (state != 'ANSWERED') return null;
    final kind = item['answer_kind'] as String? ?? '';
    final key = item['item_key'] as String;
    final codes = _editorCodes[key] ?? const <String>[];
    if (kind == 'TEXT') return (_editorText[key] ?? '').trim();
    if (kind == 'COMPOSITE') {
      return _compositeValue(item, _editorComposite[key] ?? const <String, dynamic>{});
    }
    if (kind == 'GEO') {
      if (codes.isEmpty) return null;
      final code = codes.first;
      if (code == 'UNDECIDED') return 'UNDECIDED';
      final areas = _geography(item)?['areas'];
      for (final area in areas is List ? areas : const []) {
        if (area is Map && area['area_ref'] == code) {
          return {
            'jurisdiction': area['jurisdiction'],
            'area_ref': area['area_ref'],
            'catalogue_version': area['catalogue_version'],
          };
        }
      }
      // A code with no catalogue entry is not sendable; the backend refuses any
      // area that is not registered, so nothing is invented here.
      return null;
    }
    if (kind == 'SINGLE') {
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
    if (a is Map && b is Map) {
      // DD-063: a GEO value is a structured entry. Dart prints a Map in insertion
      // order, so comparing their toString() would report a false dirty state
      // whenever the server returned the keys in a different order.
      if (a.length != b.length) return false;
      for (final key in a.keys) {
        if (!b.containsKey(key)) return false;
        if (!_sameValue(a[key], b[key])) return false;
      }
      return true;
    }
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
        // A new revision invalidates decisions recorded against the old one.
        _decisions = {};
        _worksheet = null;
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

  Future<void> _evaluate() async {
    final draft = _draft;
    if (draft == null || busy) return;
    setState(() {
      busy = true;
      error = null;
      notice = '';
      _worksheet = null;
    });
    try {
      await AppLocator.m2.evaluate(draft);
      final sheet = await AppLocator.m2.worksheet(draft);
      if (!mounted) return;
      setState(() {
        _worksheet = sheet;
        notice =
            'Candidate BDJ evaluation recorded at revision ${draft.revision}. '
            'These are candidate findings from a governed model-assisted run — '
            'not an approval, not a customer observation and not a scientific '
            'verdict.';
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'The BDJ evaluation did not return a current-revision worksheet. '
              'Every required M2 answer must be saved first.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// Findings on the current worksheet that still lack a persisted
  /// `KEEP_ORIGINAL` decision. Confirmation is refused by the backend while any
  /// remain, so the control stays disabled rather than inviting a 409.
  List<String> get _undecidedFindingIds {
    final sheet = _worksheet;
    if (sheet == null) return const [];
    return [
      for (final f in (sheet['findings'] as List? ?? const []))
        if (f is Map && f['id'] is String && _decisions[f['id']] != 'KEEP_ORIGINAL')
          f['id'] as String,
    ];
  }

  Future<void> _confirm() async {
    final draft = _draft;
    final sheet = _worksheet;
    if (draft == null || sheet == null || busy) return;
    if (_undecidedFindingIds.isNotEmpty) {
      setState(() => error =
          'Each current finding needs a recorded KEEP_ORIGINAL decision before '
          'confirmation. REVIEW_LATER is not confirmation.');
      return;
    }
    final findings = [
      for (final f in (sheet['findings'] as List? ?? const []))
        if (f is Map && f['id'] is String) f['id'] as String,
    ];
    setState(() {
      busy = true;
      error = null;
      notice = '';
    });
    try {
      await AppLocator.m2.review(draft,
          marketplaceAssessmentId: component.marketplaceAssessmentId);
      final result = await AppLocator.m2.confirm(draft, findings);
      if (!mounted) return;
      setState(() {
        _confirmation = result;
        notice =
            'Confirmation recorded. The snapshot states '
            'qj_handoff_authorized = false: confirmation is a research input, '
            'not a QJ authorization.';
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Confirmation was refused. It requires a current review and an '
              'explicit acknowledgement of every candidate finding.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

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
      // The permission is offered next to the confirm action, so its terms are
      // fetched with the review rather than on every panel build.
      await _loadAiDisclosure();
    } catch (failure) {
      if (mounted) setState(() => error = _confirmationError(failure));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// Read the disclosed AI-processing terms before offering the control.
  ///
  /// Read-only. Nothing is granted by reading it, and a failure leaves the
  /// control unavailable rather than showing invented terms.
  Future<void> _loadAiDisclosure() async {
    if (_aiDisclosure != null) return;
    try {
      final terms = await AppLocator.m2.aiProcessingDisclosure();
      if (!mounted) return;
      setState(() {
        _aiDisclosure = terms;
        _aiDisclosureError = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _aiDisclosureError =
            'The AI-processing terms could not be read. The permission cannot '
            'be offered without them, and confirming without it grants nothing.';
      });
    }
  }

  /// The echo the server will compare against its own disclosure.
  ///
  /// Only an affirmative decision produces this map. Omission is the honest
  /// representation of "not granted", so nothing is sent unless the box is
  /// checked *and* the terms were actually displayed.
  Map<String, dynamic>? _aiConsentEcho() {
    final terms = _aiDisclosure;
    if (!_aiConsent || terms == null) return null;
    return {
      'granted': true,
      'disclosure_version': terms['contract_version'],
      'provider': terms['provider'],
      'purpose': terms['purpose'],
      'endpoint': terms['endpoint'],
      'model': terms['model'],
    };
  }

  /// The AI-processing permission, immediately before the confirm action.
  ///
  /// Unchecked on every render and every reload: the decision belongs to the
  /// owner, and a default of "yes" would make silence look like agreement.
  Component _aiConsentControl() {
    final terms = _aiDisclosure;
    return div(classes: 'stack stack--sm', [
      p(classes: 'small asw-muted', [
        Component.text(
          'Confirming the declaration grants nothing downstream. Sending the '
          'confirmed information to an external AI model to derive research '
          'objectives is a separate permission, asked for separately.',
        ),
      ]),
      if (terms == null)
        p(classes: 'small', [
          Component.text(
            _aiDisclosureError ??
                'Reading the AI-processing terms before offering the choice…',
          ),
        ])
      else ...[
        label(classes: 'ops-checkrow', [
          input(
            type: InputType.checkbox,
            checked: _aiConsent,
            events: events(
              onClick: () => setState(() => _aiConsent = !_aiConsent),
            ),
          ),
          span([
            Component.text(
              'I allow ${terms['provider']} to process the confirmed business '
              'information of this assessment with model ${terms['model']} in '
              'order to derive research objectives.',
            ),
          ]),
        ]),
        p(classes: 'small asw-muted', [
          Component.text('Recipient: ${terms['endpoint']}'),
        ]),
        p(classes: 'small asw-muted', [
          Component.text('Purpose: ${terms['purpose']}'),
        ]),
        p(classes: 'small asw-muted', [
          Component.text(
            'Information sent: '
            '${(terms['data_shared'] as List? ?? const []).join(', ')}.',
          ),
        ]),
        p(classes: 'small asw-muted', [
          Component.text(
            'Attempts covered by this permission: ${terms['max_attempts']}. '
            '${terms['note'] ?? ''}',
          ),
        ]),
      ],
    ]);
  }

  Future<void> _confirmDeclarationBeforeBdj() async {
    final draft = _draft;
    if (draft == null || busy || _autoSaveInFlight) return;
    if (_dirtyCount() != 0 || _reviewedRevision != draft.revision) {
      setState(() => error =
          'Unsaved changes remain. Save and verify the current M2 revision before confirming.');
      return;
    }
    // Nothing is unsaved (checked above), so cancelling a pending autosave
    // debounce cannot lose an edit. It does stop one from writing *after* the
    // confirmation and moving the revision out from under it.
    _autoSaveTicket++;
    setState(() {
      busy = true;
      error = null;
      notice = '';
    });
    try {
      // No finding acknowledgements are required to confirm entrepreneur
      // declarations. BDJ findings belong to the NEXT stage.
      // ``aiProcessing`` is omitted unless the owner checked the box, so an
      // untouched control records NOT_GRANTED rather than a silent grant.
      final consent = _aiConsentEcho();
      // The POST's own receipt is the primary evidence. `confirm()` recomputes
      // the snapshot digest locally and refuses a response that does not carry
      // exactly the snapshot it just wrote, so a success here proves the server
      // stored this revision. It is therefore adopted immediately, before any
      // follow-up read: a committed confirmation must never be displayed as
      // unverified merely because a later read has not caught up yet.
      final receipt = await AppLocator.m2.confirm(draft, const <String>[],
          marketplaceAssessmentId: component.marketplaceAssessmentId,
          aiProcessing: consent);
      if (!mounted) return;
      setState(() {
        _confirmation = receipt;
        _showReview = false;
        // The confirmation is recorded; nothing is still in flight from the
        // owner's point of view. Holding `busy` through the reconciliation
        // below would hide the outcome behind "Working…" for up to a second.
        busy = false;
        notice = 'Business declaration confirmed at revision ${draft.revision}. '
            'Confirmation did not run BDJ. Open Stage 3 to continue.';
      });
      component.onDeclarationChanged?.call();
      // Then settle against the server, bounded, exactly as the workspace
      // settles readiness after a write. This is presentation only: it replaces
      // the receipt with the persisted row and moves `_draft` to the revision
      // the server now holds. A read that lands before the write is visible --
      // or before a queued autosave has bumped the revision -- is a timing
      // fact, not a failed confirmation.
      await _settleConfirmedRevision(draft);
    } catch (failure) {
      // A 200 whose snapshot the client cannot verify is NOT success, and it is
      // not repaired by re-reading: the receipt is the only evidence that the
      // bytes stored are the bytes reviewed, so an unverifiable receipt must
      // stay an error (m2_confirmation_first_test.dart pins this). What is
      // fixed here is the opposite case: a receipt that verified is no longer
      // discarded because a subsequent read disagreed.
      if (!mounted) return;
      final code = failure is AppFailure ? failure.backendCode : null;
      // ``M2_ALREADY_CONFIRMED_OR_CHANGED`` is raised by ``mark_confirmed`` when
      // the revision is already confirmed *or* when it moved. Those are not the
      // same situation, and "reload saved declarations" is the wrong advice for
      // the first one: the owner's confirmation already succeeded, so there is
      // nothing left to do but continue. Ask the server which it is, and report
      // that -- never the guess.
      if (code == 'M2_ALREADY_CONFIRMED_OR_CHANGED') {
        final alreadyConfirmed = await _settleConfirmedRevision(draft);
        if (!mounted) return;
        if (alreadyConfirmed) {
          setState(() {
            _showReview = false;
            notice = 'Revision ${draft.revision} is already confirmed, so '
                'nothing further was written. Open Stage 3 to continue.';
          });
          component.onDeclarationChanged?.call();
          return;
        }
        // The revision moved instead: the confirmation is not current, so the
        // original refusal stands and reloading is the right advice.
      }
      setState(() => error = _confirmationError(failure));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// Re-read the confirmation just written and adopt the persisted row.
  ///
  /// Returns true when the server reports a current confirmation at [draft]'s
  /// revision. The retry is bounded and identical in shape to the workspace's
  /// post-write readiness retry: the write is committed by the time the POST
  /// returns, but a read issued immediately afterwards can still race the
  /// transaction's visibility. A failed read is retried; it never unmakes the
  /// confirmation and it never becomes the user's problem to fix by reloading.
  Future<bool> _settleConfirmedRevision(M2Draft draft) async {
    for (var attempt = 0; attempt < 4; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(milliseconds: 150 * attempt));
      }
      if (!mounted) return false;
      try {
        final persisted = await AppLocator.m2.currentConfirmation(draft.id);
        if (!mounted) return false;
        if (persisted == null ||
            persisted['assessment_revision'] != draft.revision) {
          continue;
        }
        M2Draft? current;
        try {
          current = await AppLocator.m2.read(draft.id);
        } catch (_) {
          current = null;
        }
        if (!mounted) return false;
        setState(() {
          _confirmation = persisted;
          if (current != null && current.revision == draft.revision) {
            _draft = current;
          }
        });
        return true;
      } catch (_) {
        // Retry. The confirmation stands; only the read failed.
      }
    }
    return false;
  }

  /// UI-01: persist one permitted finding decision through the existing route.
  ///
  /// The backend accepts exactly two codes. `KEEP_ORIGINAL` means the
  /// declaration stands as written — it is NOT scientific approval, NOT proof
  /// the declaration is correct, and NOT resolution of the uncertainty.
  /// `REVIEW_LATER` is recorded but never satisfies confirmation.
  Future<void> _decide(String findingId, String decision) async {
    final draft = _draft;
    if (draft == null || busy) return;
    setState(() {
      busy = true;
      error = null;
      notice = '';
    });
    try {
      final result =
          await AppLocator.m2.decide(draft, findingId, decision, _uuid4());
      if (!mounted) return;
      final event = result['event'];
      final saved = event is Map && event['decision'] is String
          ? event['decision'] as String
          : decision;
      setState(() {
        _decisions = {..._decisions, findingId: saved};
        notice = saved == 'KEEP_ORIGINAL'
            ? 'Decision recorded: the declaration stands as written. This is not '
                  'scientific approval and does not resolve the uncertainty.'
            : 'Decision recorded: review deferred. REVIEW_LATER does not satisfy '
                  'confirmation.';
      });
    } catch (_) {
      if (mounted) {
        setState(() => error =
            'The finding decision was refused. Reload the current revision and '
            'choose one of the two permitted decisions.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String _uuid4() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
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

  Future<void> _readContextStatus() async {
    final draft = _draft;
    final confirmation = _confirmation;
    if (draft == null || confirmation == null || busy) return;
    setState(() {
      busy = true;
      error = null;
      notice = '';
    });
    try {
      final status = await AppLocator.m2.contextStatus(
        draft.id,
        confirmation['id'] as String,
        draft.revision,
      );
      if (!mounted) return;
      setState(() => _contextStatus = status);
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'The business-context status could not be read. Persisted BCB is '
              'default-off and requires verified tenant/concept/geography/'
              'purpose bindings.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

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

  /// The instrument version the declaration is being written against.
  ///
  /// Sample guidance is written for one instrument, so it is gated on this
  /// value rather than on the page or the assessment.
  String? get _instrumentVersion {
    final instrument = _draft?.data['instrument'];
    if (instrument is! Map) return null;
    final tag = instrument['version_tag'];
    return tag is String ? tag : null;
  }

  /// The option codes currently selected for another item.
  ///
  /// Unsaved edits win over the saved answer: an owner who has just ticked a
  /// category must see that category's product examples immediately, without
  /// waiting for a save round. Composite items keep their values elsewhere, so
  /// this reads both shapes.
  List<String> _selectedCodesOf(String itemKey) {
    final live = _editorCodes[itemKey];
    if (live != null && live.isNotEmpty) return live;
    final answer = _draft?.answers[itemKey];
    if (answer is! Map) return const <String>[];
    final value = answer['value_json'] ?? answer['value'];
    if (value is List) return [for (final v in value) '$v'];
    return const <String>[];
  }

  /// A clearly labelled example block, rendered outside the editable control.
  ///
  /// It is an `aside` so it is not mistaken for part of the form, and it
  /// carries no `for`, no input and no handler: nothing here can become a
  /// stored answer.
  Component _sampleGuidance(M2SampleGuidance guidance) => aside(
        classes: 'asw-sample',
        attributes: {'aria-label': 'Example guidance'},
        [
          p(classes: 'asw-sample__label', [
            Component.text(guidance.heading),
          ]),
          for (final line in guidance.lines)
            p(classes: 'asw-sample__text', [Component.text(line)]),
          p(classes: 'asw-sample__note', [
            Component.text(
              'Synthetic example from a sample café scenario. It is not your '
              'declaration, not customer evidence, and it is never saved.',
            ),
          ]),
        ],
      );

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
    // A single-choice field stores one String; a multi-choice field stores a
    // List. Reading only the List form left every composite radio group
    // unselected when the item was reopened, so a saved `CONFIRMED` review or a
    // saved `PRICED` decision looked unanswered — and the example keyed to that
    // choice contradicted the control beside it.
    final selected = value is List
        ? [for (final v in value) '$v']
        : (value == null ? const <String>[] : ['$value']);

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
      // Guidance sits outside the control, so it stays readable while the owner
      // types and can never be mistaken for the value. It is shown only when an
      // example matches the decision and selections currently in force.
      if (m2SampleGuidance(
            instrumentVersion: _instrumentVersion,
            itemKey: key,
            fieldName: name,
            values: values,
            selectedCodes: _selectedCodesOf,
          )
          case final guidance?)
        _sampleGuidance(guidance),
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

  /// Candidate BDJ evaluation panel.
  ///
  /// **Not mounted.** No render path references this builder, so the "Run
  /// candidate BDJ evaluation" button never reaches the DOM and
  /// `POST …/bdj/evaluate` is never sent from the application (DD-039). The
  /// findings model call is deliberately not reactivated until its necessity
  /// under `PROJECT1_BDJ_CONTRACT=objective` is established. The copy below was
  /// corrected because it described the route as deterministic when it runs the
  /// governed model-assisted path.
  // ignore: unused_element
  Component _bdj() {
    final sheet = _worksheet;
    final findings = [
      for (final f in (sheet?['findings'] as List? ?? const []))
        if (f is Map) f.cast<String, dynamic>(),
    ];
    return div(classes: 'stack', [
      h2([Component.text('Business description and candidate BDJ')]),
      p(classes: 'sr-muted', [
        Component.text(
          'POST /api/v1/m2/assessments/{id}/bdj/evaluate runs the governed '
          'model-assisted BDJ path: it dispatches a TokenHarbour model call '
          'under the adopted ruleset and requires a real-data authorization. '
          'It does not establish scientific validity.',
        ),
      ]),
      button(
        classes: 'sr-button sr-button--primary',
        attributes: {'type': 'button'},
        onClick: busy || _draft == null ? null : _evaluate,
        [Component.text('Run candidate BDJ evaluation')],
      ),
      if (sheet == null)
        p(classes: 'sr-muted', [
          Component.text('No evaluation has been read for this revision.'),
        ])
      else ...[
        p(classes: 'sr-muted', [
          Component.text(
            'Worksheet at revision ${sheet['revision']} · findings '
            '${findings.length}',
          ),
        ]),
        for (final f in findings) _findingCard(f),
        if (findings.isEmpty)
          p(classes: 'sr-muted', [
            Component.text(
              'The ruleset recorded no candidate issue. That is not a viability '
              'or completeness judgement.',
            ),
          ]),
      ],
    ]);
  }

  /// UI-01: one finding with its real source references and the two decisions
  /// the backend actually accepts. No other code is offered.
  Component _findingCard(Map<String, dynamic> f) {
    final id = f['id'] as String? ?? '';
    final decided = _decisions[id];
    final draft = _draft;
    final byId = <String, String>{};
    final answerOf = <String, Map>{};
    if (draft != null) {
      draft.answers.forEach((key, value) {
        if (value is Map) {
          answerOf[key] = value;
          final rid = value['id'];
          if (rid is String) byId[rid] = key;
        }
      });
    }
    final refs = f['source_answer_ids'] is List
        ? f['source_answer_ids'] as List
        : const [];
    final items = [for (final r in refs) byId['$r'] ?? '—'];
    final values = [
      for (final r in refs)
        if (byId['$r'] != null)
          '${byId['$r']} = ${jsonEncode(answerOf[byId['$r']]?['value_json'] ?? answerOf[byId['$r']]?['value'])}',
    ];
    return div(classes: 'stack', [
      p([
        Component.text(
          '${f['rule_id'] ?? 'rule'} · ${f['issue_type'] ?? ''} · finding $id',
        ),
      ]),
      p(classes: 'sr-muted', [
        Component.text('Source items: ${items.join(', ')}'),
      ]),
      p(classes: 'sr-muted', [
        Component.text(
          'Declared values: ${values.isEmpty ? '—' : values.join(' · ')}',
        ),
      ]),
      p([Component.text('${f['explanation'] ?? ''}')]),
      p(classes: 'sr-muted', [
        Component.text(
          'Not proven: ${f['not_proven'] ?? '—'} · Next: '
          '${f['next_action'] ?? '—'} · state ${f['review_state'] ?? '—'}',
        ),
      ]),
      p(classes: 'sr-muted', [
        Component.text(
          decided == null
              ? 'No decision recorded for this revision.'
              : 'Recorded decision: $decided',
        ),
      ]),
      div(classes: 'stack', [
        button(
          classes: 'sr-button',
          attributes: {'type': 'button'},
          onClick: busy || decided != null || id.isEmpty
              ? null
              : () => _decide(id, 'KEEP_ORIGINAL'),
          [Component.text('Keep original declaration')],
        ),
        button(
          classes: 'sr-button',
          attributes: {'type': 'button'},
          onClick: busy || decided != null || id.isEmpty
              ? null
              : () => _decide(id, 'REVIEW_LATER'),
          [Component.text('Review later')],
        ),
      ]),
      p(classes: 'sr-muted', [
        Component.text(
          '"Keep original" means the declaration stands as written. It is not '
          'approval, not proof the declaration is correct, and not resolution of '
          'the uncertainty.',
        ),
      ]),
    ]);
  }

  /// What still blocks confirmation, in the entrepreneur's terms.
  ///
  /// Mirrors the server's rule (`effective_required` on applicable items) but
  /// never decides confirmation itself — the backend still validates.
  List<Map<String, dynamic>> _unresolvedRequired() {
    final draft = _draft;
    if (draft == null) return const [];
    return [
      for (final item in draft.items)
        if (item['effective_required'] == true &&
            (draft.answers[item['item_key']]?['answer_state']) != 'ANSWERED')
          item,
    ];
  }

  // ignore: unused_element
  Component _confirmationSection() {
    final result = _confirmation;
    final unresolved = _unresolvedRequired();
    return div(classes: 'stack', [
      h2([Component.text('Confirmation and business context')]),
      if (unresolved.isEmpty)
        p(classes: 'small asw-muted', [
          Component.text('Every required question has an answer.'),
        ])
      else
        div(classes: 'm1-notice', [
          p([
            Component.text(
              '${unresolved.length} required question(s) still need an answer '
              'before this can be confirmed:',
            ),
          ]),
          for (final item in unresolved)
            p(classes: 'small asw-muted', [
              Component.text(
                '${item['item_key']} — ${item['title'] ?? item['question_text'] ?? ''}',
              ),
            ]),
        ]),
      button(
        classes: 'sr-button',
        attributes: {'type': 'button'},
        onClick: busy || _worksheet == null || _undecidedFindingIds.isNotEmpty
            ? null
            : _confirm,
        [Component.text('Record review + confirmation')],
      ),
      if (_worksheet != null && _undecidedFindingIds.isNotEmpty)
        div(classes: 'm1-notice', [
          Component.text(
            '${_undecidedFindingIds.length} current finding(s) still need a '
            'recorded KEEP_ORIGINAL decision. Confirmation stays disabled until '
            'the backend prerequisites are met.',
          ),
        ]),
      if (result != null)
        p(classes: 'sr-muted', [
          Component.text(
            'Confirmation ${result['id']} · revision '
            '${result['assessment_revision']} · snapshot digest '
            '${result['snapshot_digest']} · qj_handoff_authorized = '
            '${result['snapshot_json'] is Map ? (result['snapshot_json'] as Map)['qj_handoff_authorized'] : '—'}',
          ),
        ]),
      button(
        classes: 'sr-button',
        attributes: {'type': 'button'},
        onClick: busy || result == null ? null : _readContextStatus,
        [Component.text('Read business-context status')],
      ),
      if (_contextStatus != null)
        p(classes: 'sr-muted', [
          Component.text(
            'BCB status ${_contextStatus!['status']} · attempts '
            '${_contextStatus!['attempt_count']} · source current '
            '${_contextStatus!['source_is_current']} · last code '
            '${_contextStatus!['last_code'] ?? 'none'}',
          ),
        ]),
    ]);
  }

  @override
  Component build(BuildContext context) => section(classes: 'stack stack--md', [
    // No page heading, stepper or per-stage body here. This panel is only ever
    // mounted embedded inside a stage page that already carries the heading and
    // the stepper, so the standalone branch was unreachable: every production
    // and test mount site passes ``embedded: true``. The four bodies it used to
    // render (Stage 3 objectives, Stage 4, Stage 5 and the stepper) were removed
    // with it rather than left as dead code (D-M08).
    _statusLine(),
    if (_unbound) _unboundNotice(),
    if (!_unbound && _draft == null) _chooser(),
    if (_draft != null) ...[
      p(classes: 'small asw-muted', [
        Component.text(
          'M2 status: ${_m2StatusLabel()}'
          '${_savedRevision == null ? '' : ' · saved at revision $_savedRevision'}',
        ),
      ]),
      _saveBar(),
      _editor(),
      if (_m2StatusLabel() == 'Confirmed' ||
          _m2StatusLabel().startsWith('Required answers complete'))
        _reviewSection(),
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
            _aiConsentControl(),
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
        _worksheet = null;
        _decisions = {};
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

  /// Abandon unsaved editor state. Stored answers are untouched.
  // ignore: unused_element
  void _discardEdits() {
    final draft = _draft;
    if (draft == null) return;
    setState(() {
      _seedEditors(draft);
      _discardArmed = false;
      error = null;
      notice = 'Unsaved edits discarded. Stored answers are unchanged.';
    });
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
