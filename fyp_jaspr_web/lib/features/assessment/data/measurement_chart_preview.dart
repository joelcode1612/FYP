/// Typed view of the RP-04 measurement-chart fixture.
///
/// This is a **data adapter**, not a renderer. It parses the compile-time
/// constant emitted by `backend/scripts/build_measurement_chart_preview.py` and
/// hands the result to the existing `ChartSpecView`, exactly as the Q01 preview
/// does. No second chart renderer exists.
///
/// The payload is a real `chart-spec/1` built by the production adapter
/// `from_ee01` from a persisted EE-01 measurement snapshot. Its render state is
/// `WITHHELD_NOT_AUTHORIZED` and its admission block is `HELD`, so it carries no
/// count, no percentage and no finding. It exists so the report can show the
/// *measured* funnel and the *open gates* for a real measurement, instead of an
/// empty placeholder — never so that a number can be quoted as demand.
library;

import 'dart:convert';

import 'package:sitewise_jaspr_web/features/assessment/data/chart_spec.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/measurement_chart_fixture.dart';

/// A fixture that cannot honestly be shown as a diagnostic readback.
class MeasurementChartException implements Exception {
  const MeasurementChartException(this.code);

  final String code;

  @override
  String toString() => 'MeasurementChartException($code)';
}

/// Where the measurement came from, and how far the funnel actually got.
class MeasurementChartProvenance {
  const MeasurementChartProvenance({
    required this.testRunId,
    required this.campaignId,
    required this.assessmentId,
    required this.slot,
    required this.rule,
    required this.policyVersion,
    required this.evidenceContextHash,
    required this.qualified,
    required this.shown,
    required this.answered,
    required this.substantive,
    required this.gates,
  });

  final String testRunId;
  final String campaignId;
  final String assessmentId;
  final String slot;
  final String rule;
  final String policyVersion;
  final String evidenceContextHash;
  final int qualified;
  final int shown;
  final int answered;
  final int substantive;
  final List<String> gates;

  factory MeasurementChartProvenance.fromJson(Map<String, dynamic> json) {
    int asInt(String key) {
      final value = json[key];
      if (value is int) return value;
      throw MeasurementChartException('E_PROVENANCE_${key.toUpperCase()}_INVALID');
    }

    String asString(String key) {
      final value = json[key];
      if (value is String && value.isNotEmpty) return value;
      throw MeasurementChartException('E_PROVENANCE_${key.toUpperCase()}_MISSING');
    }

    return MeasurementChartProvenance(
      testRunId: asString('test_run_id'),
      campaignId: asString('campaign_id'),
      assessmentId: asString('assessment_id'),
      slot: asString('slot'),
      rule: asString('rule'),
      policyVersion: asString('policy_version'),
      evidenceContextHash: asString('evidence_context_hash'),
      qualified: asInt('qualified'),
      shown: asInt('shown'),
      answered: asInt('answered'),
      substantive: asInt('substantive'),
      gates: (json['gates'] as List<dynamic>? ?? const []).cast<String>(),
    );
  }
}

/// The measured-but-withheld chart, ready for the report to render.
class MeasurementChartPreview {
  const MeasurementChartPreview({
    required this.chart,
    required this.provenance,
  });

  final ChartSpecModel chart;
  final MeasurementChartProvenance provenance;

  /// The funnel as a sentence. Every number is copied from the persisted
  /// measurement; none is derived here.
  String get funnelSentence =>
      '${provenance.qualified} qualified · ${provenance.shown} shown · '
      '${provenance.answered} answered · ${provenance.substantive} substantive. '
      'The percentage denominator is V = ${provenance.substantive}.';

  static MeasurementChartPreview? _cached;

  static MeasurementChartPreview fromFixture() {
    return _cached ??= MeasurementChartPreview.fromPayloads(
      (jsonDecode(measurementChartPayloadJson) as Map).cast<String, dynamic>(),
      (jsonDecode(measurementChartProvenanceJson) as Map).cast<String, dynamic>(),
    );
  }

  /// Parse a payload/provenance pair, enforcing every refusal.
  ///
  /// Public so the refusals can be exercised directly by tests with a mutated
  /// payload; production callers use [fromFixture].
  factory MeasurementChartPreview.fromPayloads(
    Map<String, dynamic> payload,
    Map<String, dynamic> provenanceJson,
  ) {
    final chart = ChartSpecModel.fromJson(payload);

    // Defence in depth. The generator already refuses these, but the report is
    // the last place a fabricated finding could appear, so the adapter refuses
    // them again rather than trusting its input.
    if (chart.isReportAdmissible) {
      throw const MeasurementChartException('E_FIXTURE_IS_REPORT_ADMISSIBLE');
    }
    if (!chart.admission.isHeld) {
      throw const MeasurementChartException('E_FIXTURE_HAS_ADMISSION');
    }
    if (chart.admission.gates.isEmpty) {
      throw const MeasurementChartException('E_FIXTURE_HELD_WITHOUT_GATE');
    }
    if (chart.hasPercentages) {
      throw const MeasurementChartException('E_FIXTURE_DISCLOSES_PERCENTAGES');
    }
    if (chart.options.any((option) => option.percentageText != null)) {
      throw const MeasurementChartException('E_FIXTURE_EMITS_PERCENTAGE');
    }

    final provenance = MeasurementChartProvenance.fromJson(provenanceJson);
    if (provenance.campaignId != chart.campaignId) {
      throw const MeasurementChartException('E_PROVENANCE_CAMPAIGN_MISMATCH');
    }
    if (provenance.evidenceContextHash != chart.evidenceContextHash) {
      throw const MeasurementChartException('E_PROVENANCE_CONTEXT_MISMATCH');
    }

    return MeasurementChartPreview(chart: chart, provenance: provenance);
  }

  /// The fixture, or `null` when it cannot be parsed honestly.
  ///
  /// A malformed fixture must degrade to "no measurement section" rather than
  /// break the report. The refusals are still enforced; they are swallowed into
  /// `null` at this one boundary, exactly as [Q01SyntheticPreview] does.
  static MeasurementChartPreview? tryFromFixture() {
    try {
      return fromFixture();
    } on Object {
      return null;
    }
  }
}
