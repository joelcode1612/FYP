import 'dart:convert';
import 'dart:math';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart' show M2Draft, AppFailure, NetworkFailure, ResponseFormatFailure;

import '../data/app_locator.dart';
import 'research_workflow_panel.dart' show ResearchCandidatePanel;
import 'ui.dart' show ActionButton;

/// PROJECT1 M2 research workflow surface.
///
/// Every value shown here comes from the authenticated FastAPI M2 router
/// (`/api/v1/m2/...`). Nothing is seeded from fixtures, and no step invents a
/// result when a call fails:
///
/// * questions and saved answers come from `GET /m2/assessments/{id}`
/// * answers are written by `PUT /m2/assessments/{id}/answers/{item_key}`
/// * business description / BDJ is `POST /m2/assessments/{id}/bdj/evaluate`
///   (the DETERMINISTIC candidate ruleset — not a model call)
/// * confirmation is `POST /m2/assessments/{id}/review` then `.../confirm`
/// * the research objective is `POST /m2/confirmations/{id}/research-objectives`
/// * the QJ context is a READ (`GET /m2/research-objectives/{id}/qj-context`);
///   it is not a QJ run.
/// * the research-question candidate is prepared, read, reviewed and revised
///   through `ResearchCandidatePanel` below (`.../qg-candidate`,
///   `/research-questions/{version}`, `.../owner-review`, `.../revision`).
///
/// Activity History is a separate read-only surface and is linked, not
/// duplicated here.
class M2WorkflowPanel extends StatefulComponent {
  /// Optional deep link to one saved M2 assessment.
  final String assessmentId;

  /// DEF-11: when true the panel refuses to adopt any M2 assessment that was not
  /// named explicitly.
  ///
  /// The standalone route (`/entrepreneur/m2-workflow`) legitimately opens the
  /// owner's most recent assessment, because there the panel *is* the whole
  /// page and the entrepreneur is choosing what to work on. Embedded in an
  /// assessment-specific workspace the same fallback is wrong: it silently
  /// shows one assessment's answers under another assessment's heading.
  ///
  /// With this flag set and no [assessmentId], the panel renders an unbound
  /// notice and no editor, so an unlinked assessment cannot save M2 answers.
  final bool requireExplicitId;

  /// True when the panel is one section of the Assessment workspace rather than
  /// a page of its own.
  ///
  /// The governed stages below the questionnaire — candidate BDJ, confirmation
  /// and the research objective / QJ context — are developer-facing surfaces
  /// for later workflow stages. They stay on the standalone route and are hidden
  /// here, so the Assessment tab shows the questionnaire and nothing that looks
  /// like a second, competing workflow. Their services, records and permissions
  /// are untouched.
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
  Map<String, dynamic>? _objective;
  Map<String, dynamic>? _qjContext;
  String _objectiveText = '';

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
      _objective = null;
      _qjContext = null;
      _objectiveText = '';
      _itemIndex = 0;
      _seedEditors(draft);
    });
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
  String _cardMode(Map<String, dynamic> item) {
    if (_applicable(item)) {
      final kind = item['answer_kind'] as String? ?? '';
      final hasInput = kind == 'TEXT' || _options(item).isNotEmpty;
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
    final keepTouched = {..._touched};
    _touched.clear();
    _editorState.clear();
    _editorCodes.clear();
    _editorText.clear();
    for (final raw in draft.items) {
      if ((raw['answer_kind'] as String? ?? '') == 'ACTION') continue;
      final key = raw['item_key'] as String;
      if (preserve.contains(key)) {
        _editorState[key] = keepState[key] ?? 'ANSWERED';
        _editorCodes[key] = keepCodes[key] ?? const <String>[];
        _editorText[key] = keepText[key] ?? '';
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
            'These are deterministic candidate findings, not a model output and '
            'not a scientific verdict.';
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

  Future<void> _createObjective() async {
    final draft = _draft;
    final confirmation = _confirmation;
    if (draft == null || confirmation == null || busy) return;
    if (_objectiveText.trim().isEmpty) {
      setState(() => error = 'Enter the research objective before submitting.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
      notice = '';
    });
    try {
      final result = await AppLocator.m2.createObjective(
        confirmation['id'] as String,
        draft.revision,
        _objectiveText,
      );
      if (!mounted) return;
      setState(() {
        _objective = result;
        _qjContext = null;
        notice =
            'Research objective ${result['id']} persisted against the '
            'confirmation revision.';
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'The research objective was not saved. It is bound to the '
              'confirmation revision and must be current.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _readQjContext() async {
    final draft = _draft;
    final objective = _objective;
    if (draft == null || objective == null || busy) return;
    setState(() {
      busy = true;
      error = null;
      notice = '';
    });
    try {
      final context = await AppLocator.m2.qjContext(
        objective['id'] as String,
        draft.revision,
      );
      if (!mounted) return;
      setState(() {
        _qjContext = context;
        notice =
            'QJ context read. This is the objective\'s judgement input, not a '
            'QJ run: no QJ execution endpoint is registered.';
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'The QJ context could not be read for this objective revision.',
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
        if (mode == 'answerable' && kind == 'TEXT')
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
      if (mode == 'answerable' && _canSkip(item))
        p(classes: 'small asw-muted', [
          ActionButton(
            state == 'NOT_PROVIDED'
                ? 'Skipped for now — tap to answer'
                : 'Skip this question for now',
            variant: 'secondary',
            onClick: () {
              setState(() {
                _editorState[key] =
                    state == 'NOT_PROVIDED' ? 'ANSWERED' : 'NOT_PROVIDED';
                _touched.add(key);
              });
              _scheduleAutoSave();
            },
          ),
        ]),
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
          'POST /api/v1/m2/assessments/{id}/bdj/evaluate runs the deterministic '
          'candidate ruleset. It is not a model call and does not establish '
          'scientific validity.',
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

  Component _objectiveSection() {
    final result = _objective;
    return div(classes: 'stack', [
      h2([Component.text('Confirmed research objective and QJ context')]),
      textarea(
        rows: 3,
        classes: 'm1-textarea',
        attributes: {'aria-label': 'research objective'},
        onInput: (value) => setState(() => _objectiveText = value),
        [Component.text(_objectiveText)],
      ),
      button(
        classes: 'sr-button',
        attributes: {'type': 'button'},
        onClick: busy || _confirmation == null ? null : _createObjective,
        [Component.text('Save research objective')],
      ),
      if (result != null)
        p(classes: 'sr-muted', [
          Component.text(
            // UI-02: the backend nests origin under `source`
            // (confirmation_service.py builds {"source": {"origin": ...}}).
            'Objective ${result['id']} · origin '
            '${result['source'] is Map ? (result['source'] as Map)['origin'] ?? '—' : '—'} · '
            'confirmation ${result['confirmation_id']}',
          ),
        ]),
      button(
        classes: 'sr-button',
        attributes: {'type': 'button'},
        onClick: busy || result == null ? null : _readQjContext,
        [Component.text('Read QJ context')],
      ),
      if (_qjContext != null)
        pre([
          Component.text(
            const JsonEncoder.withIndent('  ').convert(_qjContext),
          ),
        ]),
      div(classes: 'm1-notice', [
        Component.text(
          'Reading the QJ context is not a judgement: QJ is retired from the '
          'active path and this panel never runs it. The next step is the '
          'research-question candidate below, which is generated from your '
          'confirmed business facts.',
        ),
      ]),
      if (result != null && _draft != null)
        ResearchCandidatePanel(
          // Keyed by objective + revision: a new objective or a new assessment
          // revision must not reuse the previous candidate's widget state.
          key: ValueKey(
            'candidate-${result['id']}-${_draft!.revision}',
          ),
          objectiveId: result['id'] as String,
          expectedRevision: _draft!.revision,
          contextId: _contextStatus?['context_id'] as String?,
          objectiveText: result['exact_text'] is String
              ? result['exact_text'] as String
              : _objectiveText,
        ),
    ]);
  }

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
      _editor(),
      if (component.embedded &&
          (_m2StatusLabel() == 'Confirmed' ||
              _m2StatusLabel().startsWith('Required answers complete')))
        _reviewSection(),
      if (!component.embedded) ...[
        _reviewSection(),
        p(classes: 'sr-muted', [Component.text(
          'Business review requires a current confirmed declaration and its separately authorized source workflow.',
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
      ],
    ],
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
  }

  /// Abandon unsaved editor state. Stored answers are untouched.
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
        'Existing M2 assessments are untouched. To work on one directly, use '
        'the standalone M2 research workflow; this page will show the '
        'questionnaire once a verified link exists.',
      ),
    ]),
    a(
      href: '/entrepreneur/m2-workflow',
      classes: 'sr-button',
      [Component.text('Open the standalone M2 research workflow')],
    ),
  ]);
}
