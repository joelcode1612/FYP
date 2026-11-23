/// Parsed `chart-spec/1` contract.
///
/// This model is a *reader*. It never grants authority and never computes a
/// percentage: the percentage arrives from the backend as a decimal string and
/// is displayed verbatim. When the payload carries no percentage the field stays
/// null, so a missing value can never be rendered as `0%`.
///
/// Parsing is strict. A payload that would let a chart claim more than the
/// backend asserted is rejected with a fixed [ChartSpecException] code instead
/// of being repaired, mirroring the refusals in
/// `backend/src/sitewise/project1/chart_spec.py`.
library;

/// Presentation decision carried by the backend; the renderer must not re-derive it.
enum ChartRenderState {
  renderable('RENDERABLE'),
  notShown('NOT_SHOWN'),
  notEstimable('NOT_ESTIMABLE'),
  withheldNotAuthorized('WITHHELD_NOT_AUTHORIZED'),
  unavailableMissingApprovedStimulus('UNAVAILABLE_MISSING_APPROVED_STIMULUS'),
  unauthorizedClaim('UNAUTHORIZED_CLAIM'),

  /// Development-only presentation of a validated **synthetic** measurement.
  ///
  /// Counts and shares are shown, but the admission block stays `HELD` and
  /// [ChartSpecModel.isReportAdmissible] stays false, so this state can never
  /// reach a report section. It exists so the synthetic Q01 preview can draw
  /// real geometry without pretending the line was admitted.
  syntheticPreviewOnly('SYNTHETIC_PREVIEW_ONLY');

  const ChartRenderState(this.wire);

  final String wire;

  /// States that disclose counts and shares. `RENDERABLE` is the production
  /// case; `syntheticPreviewOnly` is the isolated development case.
  bool get disclosesCounts =>
      this == ChartRenderState.renderable || this == ChartRenderState.syntheticPreviewOnly;

  static ChartRenderState? fromWire(String? value) {
    for (final state in values) {
      if (state.wire == value) return state;
    }
    return null;
  }
}

enum ChartPercentageStatus {
  estimable('ESTIMABLE'),
  notEstimable('NOT_ESTIMABLE'),
  withheldNotAuthorized('WITHHELD_NOT_AUTHORIZED'),
  notShown('NOT_SHOWN'),

  /// A share derived from a synthetic fixture under the development-only
  /// preview state. Deliberately a distinct value from [estimable] so nothing
  /// can mistake a demonstration share for an authorized one.
  syntheticPreviewEstimable('SYNTHETIC_PREVIEW_ESTIMABLE');

  const ChartPercentageStatus(this.wire);

  final String wire;

  /// Whether this status carries an actual percentage value.
  bool get carriesValue =>
      this == ChartPercentageStatus.estimable ||
      this == ChartPercentageStatus.syntheticPreviewEstimable;

  static ChartPercentageStatus? fromWire(String? value) {
    for (final status in values) {
      if (status.wire == value) return status;
    }
    return null;
  }
}

enum ChartResponseKind {
  singleSelect('SINGLE_SELECT'),
  multiSelect('MULTI_SELECT'),
  ordinal('ORDINAL');

  const ChartResponseKind(this.wire);

  final String wire;

  static ChartResponseKind? fromWire(String? value) {
    for (final kind in values) {
      if (kind.wire == value) return kind;
    }
    return null;
  }
}

/// A payload that cannot be rendered without overstating what was measured.
class ChartSpecException implements Exception {
  const ChartSpecException(this.code);

  final String code;

  @override
  String toString() => 'ChartSpecException($code)';
}

const canonicalReportSections = <String>{
  'R01', 'R02', 'R03', 'R04', 'R05', 'R06',
  'R07', 'R08', 'R09', 'R10', 'R11', 'R12',
};

const chartSchemaVersion = 'chart-spec/1';

class ChartMeasurement {
  const ChartMeasurement({
    required this.invited,
    required this.qualified,
    required this.shown,
    required this.answered,
    required this.substantive,
  });

  /// `null` means `UNKNOWN_NOT_ENUMERABLE`, never zero.
  final int? invited;
  final int qualified;
  final int shown;
  final int answered;
  final int substantive;

  factory ChartMeasurement.fromJson(Map<String, dynamic> json) {
    final rawInvited = json['I'];
    final invited = rawInvited is int ? rawInvited : null;
    if (rawInvited is! int && rawInvited != 'UNKNOWN_NOT_ENUMERABLE') {
      throw const ChartSpecException('E_INVITED_UNRECOGNISED');
    }
    final qualified = _int(json['Q'], 'E_Q_INVALID');
    final shown = _int(json['S'], 'E_S_INVALID');
    final answered = _int(json['A'], 'E_A_INVALID');
    final substantive = _int(json['V'], 'E_V_INVALID');
    if (shown > qualified || answered > shown || substantive > answered) {
      throw const ChartSpecException('E_FUNNEL_NON_MONOTONIC');
    }
    return ChartMeasurement(
      invited: invited,
      qualified: qualified,
      shown: shown,
      answered: answered,
      substantive: substantive,
    );
  }
}

class ChartOptionModel {
  const ChartOptionModel({
    required this.code,
    required this.label,
    required this.labelSource,
    required this.ordinalValue,
    required this.count,
    required this.percentageText,
    required this.percentageValue,
    required this.percentageStatus,
  });

  final String code;
  final String? label;
  final String labelSource;
  final int? ordinalValue;
  final int count;

  /// Authoritative display text, copied from the backend decimal string.
  final String? percentageText;

  /// Geometry only. Never displayed; never re-derived from counts.
  final double? percentageValue;
  final ChartPercentageStatus percentageStatus;

  String get displayLabel => label ?? code;

  factory ChartOptionModel.fromJson(Map<String, dynamic> json) {
    final code = json['code'];
    if (code is! String || code.isEmpty) {
      throw const ChartSpecException('E_OPTION_CODE_MISSING');
    }
    final status = ChartPercentageStatus.fromWire(json['percentage_status'] as String?);
    if (status == null) {
      throw const ChartSpecException('E_PERCENTAGE_STATUS_UNKNOWN');
    }
    final count = _int(json['count'], 'E_OPTION_COUNT_INVALID');
    final rawPercentage = json['percentage'];
    String? text;
    double? value;
    if (rawPercentage is String) {
      text = rawPercentage;
      value = double.tryParse(rawPercentage);
      if (value == null) {
        throw const ChartSpecException('E_PERCENTAGE_NOT_DECIMAL');
      }
    } else if (rawPercentage != null) {
      // A JSON number here means a float reached the contract; refuse it rather
      // than accept drift-prone arithmetic.
      throw const ChartSpecException('E_PERCENTAGE_NOT_A_DECIMAL_STRING');
    }
    if (status.carriesValue) {
      if (text == null) throw const ChartSpecException('E_PERCENTAGE_STATUS_MISSING_VALUE');
      if (value! < 0 || value > 100) throw const ChartSpecException('E_PERCENTAGE_OUT_OF_RANGE');
    } else if (text != null) {
      throw const ChartSpecException('E_PERCENTAGE_EMITTED_WITHOUT_AUTHORITY');
    }
    final ordinal = json['ordinal_value'];
    if (ordinal != null && ordinal is! int) {
      throw const ChartSpecException('E_ORDINAL_VALUE_INVALID');
    }
    return ChartOptionModel(
      code: code,
      label: json['label'] as String?,
      labelSource: (json['label_source'] as String?) ?? 'CODE_FALLBACK',
      ordinalValue: ordinal as int?,
      count: count,
      percentageText: text,
      percentageValue: value,
      percentageStatus: status,
    );
  }
}

class ChartDerivedLine {
  const ChartDerivedLine({
    required this.code,
    required this.label,
    required this.numeratorCodes,
    required this.count,
    required this.percentageText,
    required this.percentageValue,
    required this.percentageStatus,
    required this.formula,
    required this.outputLabel,
  });

  final String code;
  final String? label;
  final List<String> numeratorCodes;
  final int count;
  final String? percentageText;
  final double? percentageValue;
  final ChartPercentageStatus percentageStatus;
  final String formula;
  final String outputLabel;

  String get displayLabel => label ?? outputLabel;

  factory ChartDerivedLine.fromJson(Map<String, dynamic> json) {
    final status = ChartPercentageStatus.fromWire(json['percentage_status'] as String?);
    if (status == null) {
      throw const ChartSpecException('E_PERCENTAGE_STATUS_UNKNOWN');
    }
    final raw = json['percentage'];
    String? text;
    double? value;
    if (raw is String) {
      text = raw;
      value = double.tryParse(raw);
      if (value == null) throw const ChartSpecException('E_PERCENTAGE_NOT_DECIMAL');
    } else if (raw != null) {
      throw const ChartSpecException('E_PERCENTAGE_NOT_A_DECIMAL_STRING');
    }
    if (status.carriesValue && text == null) {
      throw const ChartSpecException('E_PERCENTAGE_STATUS_MISSING_VALUE');
    }
    if (!status.carriesValue && text != null) {
      throw const ChartSpecException('E_PERCENTAGE_EMITTED_WITHOUT_AUTHORITY');
    }
    return ChartDerivedLine(
      code: json['code'] as String,
      label: json['label'] as String?,
      numeratorCodes:
          (json['numerator_codes'] as List<dynamic>? ?? const []).cast<String>(),
      count: _int(json['count'], 'E_OPTION_COUNT_INVALID'),
      percentageText: text,
      percentageValue: value,
      percentageStatus: status,
      formula: (json['formula'] as String?) ?? '',
      outputLabel: (json['output_label'] as String?) ?? (json['code'] as String),
    );
  }
}

class ChartAdmissionModel {
  const ChartAdmissionModel({
    required this.status,
    required this.authority,
    required this.gates,
    required this.realReportable,
  });

  final String status;
  final String authority;
  final List<String> gates;
  final bool realReportable;

  bool get isHeld => status == 'HELD';

  factory ChartAdmissionModel.fromJson(Map<String, dynamic> json) {
    final status = json['status'];
    if (status != 'HELD' && status != 'ADMITTED') {
      throw const ChartSpecException('E_ADMISSION_STATUS_UNKNOWN');
    }
    final gates = (json['gates'] as List<dynamic>? ?? const []).cast<String>();
    if (status == 'HELD' && gates.isEmpty) {
      throw const ChartSpecException('E_HELD_WITHOUT_GATE');
    }
    return ChartAdmissionModel(
      status: status as String,
      authority: (json['authority'] as String?) ?? '',
      gates: gates,
      realReportable: json['real_reportable'] == true,
    );
  }
}

class ChartSpecModel {
  const ChartSpecModel({
    required this.schemaVersion,
    required this.chartId,
    required this.chartType,
    required this.sourceProvenance,
    required this.evidenceContextHash,
    required this.campaignId,
    required this.questionId,
    required this.constructId,
    required this.reportSections,
    required this.questionVersion,
    required this.optionBankVersion,
    required this.stimulusHash,
    required this.conceptVersion,
    required this.cohortScope,
    required this.cutoff,
    required this.measurement,
    required this.denominatorScope,
    required this.limitation,
    required this.title,
    required this.questionText,
    required this.responseKind,
    required this.options,
    required this.derivedLines,
    required this.highestOptions,
    required this.limitations,
    required this.renderState,
    required this.admission,
  });

  final String schemaVersion;
  final String chartId;
  final String chartType;
  final String sourceProvenance;

  /// EE-01 readback `context_hash` this chart was built from.
  ///
  /// The explanation service refuses a request whose `context_hash` differs, so
  /// this equality is what binds a chart to its narrative.
  final String evidenceContextHash;
  final String campaignId;
  final String questionId;
  final String constructId;
  final List<String> reportSections;
  final String questionVersion;
  final String optionBankVersion;
  final String stimulusHash;
  final String conceptVersion;
  final String cohortScope;
  final DateTime cutoff;
  final ChartMeasurement measurement;
  final String denominatorScope;
  final String limitation;
  final String title;
  final String questionText;
  final ChartResponseKind responseKind;
  final List<ChartOptionModel> options;
  final List<ChartDerivedLine> derivedLines;
  final List<String> highestOptions;
  final List<String> limitations;
  final ChartRenderState renderState;
  final ChartAdmissionModel admission;

  /// Only a `RENDERABLE` spec may enter a report. Everything else is diagnostic
  /// or withheld and must be shown with its own notice instead of a chart.
  ///
  /// `syntheticPreviewOnly` is deliberately **not** admissible: the whole point
  /// of that state is that it draws bars while remaining a demonstration.
  bool get isReportAdmissible => renderState == ChartRenderState.renderable;

  /// True only for the development-only synthetic demonstration.
  bool get isSyntheticPreview => renderState == ChartRenderState.syntheticPreviewOnly;

  bool get hasPercentages =>
      options.isNotEmpty &&
      options.every((option) => option.percentageStatus == ChartPercentageStatus.estimable);

  /// Largest count in the chart, used only to scale bar lengths.
  int get maxCount =>
      options.isEmpty ? 0 : options.map((option) => option.count).reduce((a, b) => a > b ? a : b);

  factory ChartSpecModel.fromJson(Map<String, dynamic> json) {
    if (json['schema_version'] != chartSchemaVersion) {
      throw const ChartSpecException('E_SCHEMA_VERSION_UNSUPPORTED');
    }
    if (json['chart_type'] != 'HORIZONTAL_BAR') {
      throw const ChartSpecException('E_CHART_TYPE_UNSUPPORTED');
    }
    final sections = (json['report_sections'] as List<dynamic>? ?? const []).cast<String>();
    if (sections.isEmpty) throw const ChartSpecException('E_REPORT_SECTION_MISSING');
    for (final section in sections) {
      if (!canonicalReportSections.contains(section)) {
        throw const ChartSpecException('E_NONCANONICAL_REPORT_SECTION');
      }
    }
    if (sections.toSet().length != sections.length) {
      throw const ChartSpecException('E_DUPLICATE_REPORT_SECTION');
    }
    final renderState = ChartRenderState.fromWire(json['render_state'] as String?);
    if (renderState == null) throw const ChartSpecException('E_RENDER_STATE_UNKNOWN');
    final responseKind = ChartResponseKind.fromWire(json['response_kind'] as String?);
    if (responseKind == null) throw const ChartSpecException('E_RESPONSE_KIND_UNSUPPORTED');

    final measurement =
        ChartMeasurement.fromJson((json['measurement'] as Map).cast<String, dynamic>());
    final options = (json['options'] as List<dynamic>? ?? const [])
        .map((raw) => ChartOptionModel.fromJson((raw as Map).cast<String, dynamic>()))
        .toList(growable: false);
    if (options.isEmpty) throw const ChartSpecException('E_OPTIONS_MISSING');
    final codes = options.map((option) => option.code).toList();
    if (codes.toSet().length != codes.length) {
      throw const ChartSpecException('E_DUPLICATE_OPTION_CODE');
    }
    final derived = (json['derived_lines'] as List<dynamic>? ?? const [])
        .map((raw) => ChartDerivedLine.fromJson((raw as Map).cast<String, dynamic>()))
        .toList(growable: false);

    final V = measurement.substantive;
    var total = 0;
    for (final option in options) {
      if (option.count > V) throw const ChartSpecException('E_OPTION_COUNT_EXCEEDS_V');
      total += option.count;
    }
    if (responseKind != ChartResponseKind.multiSelect) {
      if (total != V) throw const ChartSpecException('E_SINGLE_SELECT_SUM_MISMATCH');
    } else if (total < V) {
      throw const ChartSpecException('E_MULTI_SELECT_SUM_BELOW_V');
    }
    for (final line in derived) {
      if (line.count > V) throw const ChartSpecException('E_DERIVED_COUNT_EXCEEDS_V');
      if (!line.numeratorCodes.every(codes.contains)) {
        throw const ChartSpecException('E_DERIVED_CODE_NOT_AN_OPTION');
      }
      final expected = options
          .where((option) => line.numeratorCodes.contains(option.code))
          .fold<int>(0, (sum, option) => sum + option.count);
      if (line.count != expected) {
        throw const ChartSpecException('E_DERIVED_COUNT_MISMATCH');
      }
    }

    final highest = (json['highest_options'] as List<dynamic>? ?? const []).cast<String>();
    final expectedHighest = _computeHighest(options, V);
    if (highest.length != expectedHighest.length ||
        !highest.toSet().containsAll(expectedHighest)) {
      throw const ChartSpecException('E_HIGHEST_OPTIONS_MISMATCH');
    }

    // A count-disclosing chart must carry a percentage on every option; a held
    // one must carry none. This is the last line of defence against a payload
    // that would show a share without authority.
    final admission =
        ChartAdmissionModel.fromJson((json['admission'] as Map).cast<String, dynamic>());

    // A synthetic demonstration may never ride on a line the payload declared
    // reportable. Without this the development label could carry production
    // authority into the document, which is the one thing the unlock must not do.
    if (renderState == ChartRenderState.syntheticPreviewOnly && admission.realReportable) {
      throw const ChartSpecException('E_SYNTHETIC_PREVIEW_MARKED_REPORTABLE');
    }
    // The mirror rule: an admitted line is not a demonstration.
    if (renderState == ChartRenderState.syntheticPreviewOnly && !admission.isHeld) {
      throw const ChartSpecException('E_SYNTHETIC_PREVIEW_WITH_ADMISSION');
    }

    final expectedStatus = switch (renderState) {
      ChartRenderState.renderable => ChartPercentageStatus.estimable,
      ChartRenderState.syntheticPreviewOnly => ChartPercentageStatus.syntheticPreviewEstimable,
      _ => null,
    };
    final disclosesCounts = renderState.disclosesCounts;
    if (expectedStatus != null) {
      for (final option in options) {
        if (option.percentageStatus != expectedStatus) {
          throw const ChartSpecException('E_RENDERABLE_OPTION_NOT_ESTIMABLE');
        }
      }
      for (final line in derived) {
        if (line.percentageStatus != expectedStatus) {
          throw const ChartSpecException('E_RENDERABLE_OPTION_NOT_ESTIMABLE');
        }
      }
    }
    if (!disclosesCounts && options.any((option) => option.percentageText != null)) {
      throw const ChartSpecException('E_PERCENTAGE_EMITTED_WITHOUT_AUTHORITY');
    }
    if (V == 0 && options.any((option) => option.percentageText != null)) {
      throw const ChartSpecException('E_PERCENTAGE_WITH_ZERO_DENOMINATOR');
    }

    final limitations =
        (json['limitations'] as List<dynamic>? ?? const []).cast<String>();
    if (limitations.isEmpty) throw const ChartSpecException('E_LIMITATION_MISSING');

    final cutoffRaw = json['cutoff'];
    final cutoff = cutoffRaw is String ? DateTime.tryParse(cutoffRaw) : null;
    if (cutoff == null) throw const ChartSpecException('E_CUTOFF_INVALID');

    return ChartSpecModel(
      schemaVersion: chartSchemaVersion,
      chartId: _string(json['chart_id'], 'E_CHART_ID_MISSING'),
      chartType: 'HORIZONTAL_BAR',
      sourceProvenance: _string(json['source_provenance'], 'E_SOURCE_PROVENANCE_MISSING'),
      evidenceContextHash: _hex64(json['evidence_context_hash']),
      campaignId: _string(json['campaign_id'], 'E_CAMPAIGN_ID_MISSING'),
      questionId: _string(json['question_id'], 'E_QUESTION_ID_MISSING'),
      constructId: _string(json['construct_id'], 'E_CONSTRUCT_ID_MISSING'),
      reportSections: sections,
      questionVersion: _string(json['question_version'], 'E_QUESTION_VERSION_MISSING'),
      optionBankVersion: _string(json['option_bank_version'], 'E_OPTION_BANK_VERSION_MISSING'),
      stimulusHash: _string(json['stimulus_hash'], 'E_STIMULUS_HASH_MISSING'),
      conceptVersion: _string(json['concept_version'], 'E_CONCEPT_VERSION_MISSING'),
      cohortScope: _string(json['cohort_scope'], 'E_COHORT_SCOPE_MISSING'),
      cutoff: cutoff.toUtc(),
      measurement: measurement,
      denominatorScope: _string(json['denominator_scope'], 'E_DENOMINATOR_SCOPE_MISSING'),
      limitation: _string(json['limitation'], 'E_LIMITATION_MISSING'),
      title: _string(json['title'], 'E_TITLE_MISSING'),
      questionText: _string(json['question_text'], 'E_QUESTION_TEXT_MISSING'),
      responseKind: responseKind,
      options: options,
      derivedLines: derived,
      highestOptions: highest,
      limitations: limitations,
      renderState: renderState,
      admission: admission,
    );
  }

  static List<String> _computeHighest(List<ChartOptionModel> options, int V) {
    if (V == 0) return const [];
    final ranked = options.where((option) => option.count > 0).toList();
    if (ranked.isEmpty) return const [];
    final top = ranked.map((option) => option.count).reduce((a, b) => a > b ? a : b);
    final codes = ranked.where((option) => option.count == top).map((option) => option.code).toList()
      ..sort();
    return codes;
  }
}

int _int(Object? value, String code) {
  if (value is int) return value;
  throw ChartSpecException(code);
}

String _string(Object? value, String code) {
  if (value is String && value.isNotEmpty) return value;
  throw ChartSpecException(code);
}

final _hex64Pattern = RegExp(r'^[0-9a-f]{64}$');

String _hex64(Object? value) {
  if (value is String && _hex64Pattern.hasMatch(value)) return value;
  throw const ChartSpecException('E_EVIDENCE_CONTEXT_HASH_INVALID');
}
