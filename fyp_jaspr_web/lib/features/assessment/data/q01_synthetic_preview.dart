/// Typed view of the Q01 synthetic preview fixture.
///
/// This is a **data adapter**, not a renderer: it parses the compile-time
/// constant emitted by `backend/scripts/build_q01_synthetic_preview.py` so the
/// existing report can read the fixture without embedding JSON handling in the
/// page. Rendering is `ChartSpecView`'s job, exactly as for every other chart.
///
/// The fixture is development-only. Nothing here grants measurement authority:
/// the embedded chart is `SYNTHETIC_PREVIEW_ONLY` with a `HELD` admission block,
/// so it draws bars but is never report-admissible.
library;

import 'dart:convert';

import 'package:sitewise_jaspr_web/features/assessment/data/chart_spec.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/q01_synthetic_preview_fixture.dart';

/// One filled sentence from the registry's `valid` template.
class Q01PreviewStatement {
  const Q01PreviewStatement({
    required this.code,
    required this.label,
    required this.count,
    required this.percentage,
    required this.exclusive,
    required this.text,
  });

  final String code;
  final String label;
  final int count;

  /// Decimal string exactly as the backend emitted it, or null when withheld.
  final String? percentage;

  /// True for RARELY / NEVER / NOT_SURE — counted separately, never pooled with
  /// the affiliation categories.
  final bool exclusive;

  /// The registry template filled with this fixture's counts. Not model output.
  final String text;

  factory Q01PreviewStatement.fromJson(Map<String, dynamic> json) =>
      Q01PreviewStatement(
        code: json['code'] as String,
        label: json['label'] as String,
        count: json['count'] as int,
        percentage: json['percentage'] as String?,
        exclusive: json['exclusive'] == true,
        text: json['text'] as String,
      );
}

/// The Q01 synthetic demonstration, ready for the report to render.
class Q01SyntheticPreview {
  const Q01SyntheticPreview({
    required this.chart,
    required this.marker,
    required this.submarker,
    required this.respondents,
    required this.exclusiveOnly,
    required this.affiliationSelections,
    required this.overlapSelections,
    required this.statements,
    required this.exclusiveNote,
    required this.templateId,
    required this.claimScope,
    required this.productionBehaviour,
  });

  final ChartSpecModel chart;

  /// `SYNTHETIC DEMONSTRATION — NOT REPORT EVIDENCE`.
  final String marker;
  final String submarker;

  final int respondents;
  final int exclusiveOnly;
  final int affiliationSelections;
  final int overlapSelections;

  final List<Q01PreviewStatement> statements;
  final String exclusiveNote;
  final String templateId;
  final String claimScope;

  /// What the production explanation path does with Q01 (it withholds).
  final String productionBehaviour;

  List<Q01PreviewStatement> get affiliation =>
      statements.where((s) => !s.exclusive).toList(growable: false);

  List<Q01PreviewStatement> get exclusive =>
      statements.where((s) => s.exclusive).toList(growable: false);

  /// Parse a payload. Refuses anything that is not a synthetic preview, so a
  /// malformed or tampered fixture cannot present itself as a real finding.
  factory Q01SyntheticPreview.fromJson(Map<String, dynamic> json) {
    if (json['schema_version'] != 'q01-synthetic-preview/1') {
      throw const Q01PreviewException('E_Q01_PREVIEW_SCHEMA_UNSUPPORTED');
    }
    final chart = ChartSpecModel.fromJson(
      (json['chart'] as Map).cast<String, dynamic>(),
    );
    if (!chart.isSyntheticPreview) {
      throw const Q01PreviewException('E_Q01_PREVIEW_NOT_SYNTHETIC');
    }
    // No separate "is it report-admissible?" check is needed:
    // `isSyntheticPreview` and `isReportAdmissible` are two different values of
    // the same enum, so they are mutually exclusive by construction. A payload
    // cannot satisfy both, and the assertion above is the whole guard.
    final explanation = (json['explanation'] as Map).cast<String, dynamic>();
    final summary = (json['respondent_summary'] as Map).cast<String, dynamic>();
    return Q01SyntheticPreview(
      chart: chart,
      marker: json['preview_marker'] as String,
      submarker: json['preview_submarker'] as String,
      respondents: summary['respondents'] as int,
      exclusiveOnly: summary['exclusive_only'] as int,
      affiliationSelections: summary['affiliation_selections'] as int,
      overlapSelections: summary['overlap_selections'] as int,
      statements: (explanation['sentences'] as List)
          .map((raw) => Q01PreviewStatement.fromJson(
                (raw as Map).cast<String, dynamic>(),
              ))
          .toList(growable: false),
      exclusiveNote: explanation['exclusive_note'] as String,
      templateId: explanation['template_id'] as String,
      claimScope: explanation['claim_scope'] as String,
      productionBehaviour: explanation['production_path_behaviour'] as String,
    );
  }

  /// The bundled fixture, parsed once.
  static Q01SyntheticPreview? _cached;
  static Q01SyntheticPreview fromFixture() {
    return _cached ??= Q01SyntheticPreview.fromJson(
      (jsonDecode(q01SyntheticPreviewPayloadJson) as Map).cast<String, dynamic>(),
    );
  }

  /// The fixture, or `null` if it cannot be parsed honestly.
  ///
  /// A caller renders this inside the report, so a malformed fixture must
  /// degrade to "no Q01 section" rather than break the whole document. The
  /// refusal reasons are still enforced — they are just swallowed into `null`
  /// at this one boundary.
  static Q01SyntheticPreview? tryFromFixture() {
    try {
      return fromFixture();
    } on Object {
      return null;
    }
  }
}

/// A fixture that cannot honestly be shown as a demonstration.
class Q01PreviewException implements Exception {
  const Q01PreviewException(this.code);

  final String code;

  @override
  String toString() => 'Q01PreviewException($code)';
}
