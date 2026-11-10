/// Read-only models for the Full Analysis page (web decision-support).
///
/// Every number here comes from the backend: the trained PU artifact's
/// metadata, the resolved feature measurements, or the persisted validated
/// SHAP explanation. Dart formats and visualizes; it never scores, imputes or
/// invents a measurement. A null value means "not recorded", never zero.
///
/// The Flutter mobile data-collection workflow does not consume these models.
library;

import 'commercial_property.dart';
import 'pu_feature_coverage.dart';
import 'pu_prediction.dart';

/// The category order the evidence surface presents, mirroring the backend's
/// `CATEGORY_ORDER`. Features outside it fall into an explicit `other` bucket
/// rather than vanishing from the totals.
const fullAnalysisCategoryOrder = <String>[
  'population',
  'demand_generators',
  'accessibility',
  'parking',
  'competitors',
];

/// Additivity tolerance, mirroring the backend's `_ADDITIVITY_TOLERANCE`.
/// float64 permutation SHAP over <=47 features accumulates well below this; a
/// larger gap means the explanation does not describe the score.
const shapAdditivityTolerance = 1e-6;

/// One model feature as the artifact defines it: exact name plus the backend's
/// category. This is the source of truth for the five-category grouping, so
/// the UI never keeps a second copy of the category rules.
final class ModelFeatureSpec {
  final String name;
  final String category;
  final String categoryLabel;

  const ModelFeatureSpec({
    required this.name,
    required this.category,
    required this.categoryLabel,
  });

  factory ModelFeatureSpec.fromJson(Map<String, dynamic> json) =>
      ModelFeatureSpec(
        name: json['name'] as String,
        category: json['category'] as String? ?? 'other',
        categoryLabel:
            json['category_label'] as String? ??
            json['category'] as String? ??
            'Other',
      );
}

/// `GET /api/v1/ml/model` — the selected artifact's metadata and taxonomy.
final class ResearchModelMetadata {
  final bool available;
  final String? reason;
  final String? model;
  final String? artifact;
  final String? featureSet;
  final int? featureCount;
  final String? modelKind;
  final String? scoreMeaning;
  final String? experimentTag;
  final bool researchOnly;
  final bool calibratedProbability;
  final List<ModelFeatureSpec> features;

  const ResearchModelMetadata({
    required this.available,
    this.reason,
    this.model,
    this.artifact,
    this.featureSet,
    this.featureCount,
    this.modelKind,
    this.scoreMeaning,
    this.experimentTag,
    this.researchOnly = true,
    this.calibratedProbability = false,
    this.features = const [],
  });

  factory ResearchModelMetadata.fromJson(Map<String, dynamic> json) =>
      ResearchModelMetadata(
        available: json['available'] == true,
        reason: json['reason'] as String?,
        model: json['model'] as String?,
        artifact: json['artifact'] as String?,
        featureSet: json['feature_set'] as String?,
        featureCount: (json['feature_count'] as num?)?.toInt(),
        modelKind: json['model_kind'] as String?,
        scoreMeaning: json['score_meaning'] as String?,
        experimentTag: json['experiment_tag'] as String?,
        researchOnly: json['research_only'] != false,
        calibratedProbability: json['calibrated_probability'] == true,
        features: [
          for (final row in (json['features'] as List? ?? const []))
            ModelFeatureSpec.fromJson((row as Map).cast<String, dynamic>()),
        ],
      );
}

/// One signed per-feature SHAP contribution.
final class ShapContribution {
  final String feature;
  final double contribution;

  const ShapContribution({required this.feature, required this.contribution});

  factory ShapContribution.fromJson(Map<String, dynamic> json) =>
      ShapContribution(
        feature: json['feature'] as String,
        contribution: (json['contribution'] as num).toDouble(),
      );
}

/// A signed category total from the explanation's `groups`, in the evidence
/// surface's order. [contribution] is the backend's own rounded sum.
final class CategoryContribution {
  final String key;
  final String label;
  final double contribution;
  final int featureCount;
  final List<String> features;

  const CategoryContribution({
    required this.key,
    required this.label,
    required this.contribution,
    required this.featureCount,
    required this.features,
  });

  factory CategoryContribution.fromJson(Map<String, dynamic> json) =>
      CategoryContribution(
        key: json['key'] as String,
        label: json['label'] as String? ?? json['key'] as String,
        contribution: (json['contribution'] as num?)?.toDouble() ?? 0,
        featureCount: (json['feature_count'] as num?)?.toInt() ?? 0,
        features: [
          for (final name in (json['features'] as List? ?? const [])) '$name',
        ],
      );
}

/// The persisted, validated SHAP explanation for one assessment
/// (`GET /api/v1/assessments/{id}/explanation`). Reading it never computes
/// SHAP and never advances a stage.
final class ResearchExplanation {
  final String propertyId;
  final String assessmentId;
  final bool available;
  final String? model;
  final String? modelVersion;
  final String? featureSet;
  final int? featureCount;
  final String? explainer;
  final String scoreMeaning;
  final bool researchOnly;
  final double baseValue;
  final double output;
  final double reconstructed;
  final bool additivityOk;
  final int? backgroundSize;

  /// Exact per-feature signed contributions, keyed by model feature name.
  final Map<String, double> contributions;

  /// The exact resolved values the contributions were computed from. Paired
  /// with [contributions] so a consumer never shows re-measured data beside
  /// an old explanation.
  final Map<String, double?> values;

  final List<CategoryContribution> groups;
  final List<ShapContribution> strongestPositive;
  final List<ShapContribution> strongestNegative;
  final List<String> missingFeatures;
  final List<String> flags;
  final Map<String, String> valueSources;

  const ResearchExplanation({
    required this.propertyId,
    required this.assessmentId,
    required this.available,
    this.model,
    this.modelVersion,
    this.featureSet,
    this.featureCount,
    this.explainer,
    required this.scoreMeaning,
    this.researchOnly = true,
    required this.baseValue,
    required this.output,
    required this.reconstructed,
    required this.additivityOk,
    this.backgroundSize,
    this.contributions = const {},
    this.values = const {},
    this.groups = const [],
    this.strongestPositive = const [],
    this.strongestNegative = const [],
    this.missingFeatures = const [],
    this.flags = const [],
    this.valueSources = const {},
  });

  /// Net SHAP contribution: baseline + this = output (when additive).
  double get netContribution =>
      contributions.values.fold(0.0, (sum, value) => sum + value);

  /// Re-validates additivity client-side as well as trusting the backend flag.
  /// A payload that does not reconstruct the output must never be shown as a
  /// verified explanation, even if it claims `additivity_ok`.
  bool get isAdditive =>
      additivityOk &&
      available &&
      (baseValue + netContribution - output).abs() <= shapAdditivityTolerance;

  factory ResearchExplanation.fromJson(
    Map<String, dynamic> json,
  ) => ResearchExplanation(
    propertyId: json['property_id'] as String? ?? '',
    assessmentId: json['assessment_id'] as String? ?? '',
    available: json['available'] == true,
    model: json['model'] as String?,
    modelVersion: json['model_version'] as String?,
    featureSet: json['feature_set'] as String?,
    featureCount: (json['feature_count'] as num?)?.toInt(),
    explainer: json['explainer'] as String?,
    scoreMeaning:
        json['score_meaning'] as String? ??
        'research_positive_label_association_NOT_business_success_probability',
    researchOnly: json['research_only'] != false,
    baseValue: (json['base_value'] as num?)?.toDouble() ?? 0,
    output: (json['output'] as num?)?.toDouble() ?? 0,
    reconstructed: (json['reconstructed'] as num?)?.toDouble() ?? 0,
    additivityOk: json['additivity_ok'] == true,
    backgroundSize: (json['background_size'] as num?)?.toInt(),
    contributions: {
      for (final entry
          in ((json['contributions'] as Map?)?.cast<String, dynamic>() ??
                  const {})
              .entries)
        entry.key: (entry.value as num).toDouble(),
    },
    values: {
      for (final entry
          in ((json['values'] as Map?)?.cast<String, dynamic>() ?? const {})
              .entries)
        entry.key: (entry.value as num?)?.toDouble(),
    },
    groups: [
      for (final row in (json['groups'] as List? ?? const []))
        CategoryContribution.fromJson((row as Map).cast<String, dynamic>()),
    ],
    strongestPositive: [
      for (final row in (json['strongest_positive'] as List? ?? const []))
        ShapContribution.fromJson((row as Map).cast<String, dynamic>()),
    ],
    strongestNegative: [
      for (final row in (json['strongest_negative'] as List? ?? const []))
        ShapContribution.fromJson((row as Map).cast<String, dynamic>()),
    ],
    missingFeatures: [
      for (final name in (json['missing_features'] as List? ?? const []))
        '$name',
    ],
    flags: [for (final flag in (json['flags'] as List? ?? const [])) '$flag'],
    valueSources: {
      for (final entry
          in ((json['value_sources'] as Map?)?.cast<String, dynamic>() ??
                  const {})
              .entries)
        entry.key: '${entry.value}',
    },
  );
}

/// The display status of one business-target check. The backend's verdict is
/// authoritative; this only maps it to the page's vocabulary. An unrecognized
/// verdict fails closed to [requiresVerification], never to achieved.
enum BusinessTargetStatus {
  achieved,
  notAchieved,
  requiresVerification,
  context,
}

/// One deterministic target check from the report's `requirement_matching`.
final class BusinessTargetCheck {
  final String key;
  final String label;

  /// The backend's raw verdict: `match` | `mismatch` | `unknown` |
  /// `informational`.
  final String verdict;

  /// The backend's own reason sentence, shown verbatim.
  final String detail;

  /// Measured/target figures (`asking_rm`, `ceiling_rm`, `listing_sqft`,
  /// `minimum_sqft`, `measured`, ...). Empty when the check had no inputs.
  final Map<String, dynamic> data;

  const BusinessTargetCheck({
    required this.key,
    required this.label,
    required this.verdict,
    required this.detail,
    this.data = const {},
  });

  BusinessTargetStatus get status => switch (verdict) {
    'match' => BusinessTargetStatus.achieved,
    'mismatch' => BusinessTargetStatus.notAchieved,
    'informational' => BusinessTargetStatus.context,
    _ => BusinessTargetStatus.requiresVerification,
  };

  factory BusinessTargetCheck.fromJson(Map<String, dynamic> json) =>
      BusinessTargetCheck(
        key: json['key'] as String? ?? '',
        label: json['label'] as String? ?? '',
        verdict: json['verdict'] as String? ?? 'unknown',
        detail: json['detail'] as String? ?? '',
        data: (json['data'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
}

/// The read-only business-target result set for one assessment, evaluated by
/// the backend's deterministic `requirement_matching` — never an LLM guess.
final class BusinessTargetEvaluation {
  final List<BusinessTargetCheck> checks;
  final int matched;
  final int mismatched;
  final int unknown;
  final String? note;

  const BusinessTargetEvaluation({
    this.checks = const [],
    this.matched = 0,
    this.mismatched = 0,
    this.unknown = 0,
    this.note,
  });

  bool get hasChecks => checks.isNotEmpty;

  factory BusinessTargetEvaluation.fromJson(Map<String, dynamic> json) =>
      BusinessTargetEvaluation(
        checks: [
          for (final row in (json['checks'] as List? ?? const []))
            BusinessTargetCheck.fromJson((row as Map).cast<String, dynamic>()),
        ],
        matched: (json['matched'] as num?)?.toInt() ?? 0,
        mismatched: (json['mismatched'] as num?)?.toInt() ?? 0,
        unknown: (json['unknown'] as num?)?.toInt() ?? 0,
        note: json['note'] as String?,
      );
}

/// One feature row for the category panels and the technical table: the exact
/// model feature, its measured value (null = not recorded), its provenance and
/// its signed SHAP contribution (null when no validated explanation exists).
final class FeatureMeasurement {
  final String name;
  final String category;
  final String categoryLabel;
  final double? value;
  final String? valueSource;
  final double? shap;

  const FeatureMeasurement({
    required this.name,
    required this.category,
    required this.categoryLabel,
    this.value,
    this.valueSource,
    this.shap,
  });

  bool get hasValue => value != null;
  bool get hasShap => shap != null;
}

/// Data-quality limits the page must surface, never hide: backend quality
/// flags, unresolved model features and the analysis row's own status.
final class EvidenceLimitations {
  final List<String> flags;
  final List<String> missingFeatures;
  final String? analysisStatus;

  const EvidenceLimitations({
    this.flags = const [],
    this.missingFeatures = const [],
    this.analysisStatus,
  });

  bool get isEmpty =>
      flags.isEmpty && missingFeatures.isEmpty && analysisStatus == null;

  factory EvidenceLimitations.fromJson(Map<String, dynamic> json) =>
      EvidenceLimitations(
        flags: [
          for (final flag in (json['flags'] as List? ?? const [])) '$flag',
        ],
        missingFeatures: [
          for (final name in (json['missing_features'] as List? ?? const []))
            '$name',
        ],
        analysisStatus: json['analysis_status'] as String?,
      );
}

/// One geospatial category card: its features, how many are measured, and the
/// signed aggregate SHAP contribution when a validated explanation exists.
final class GeospatialCategorySummary {
  final String key;
  final String label;
  final List<FeatureMeasurement> features;

  /// Backend category total, null when no validated explanation is available.
  final double? contribution;

  const GeospatialCategorySummary({
    required this.key,
    required this.label,
    required this.features,
    this.contribution,
  });

  int get featureCount => features.length;
  int get measuredCount => features.where((f) => f.hasValue).length;

  /// The category's strongest model influence by absolute contribution, null
  /// when no feature carries a SHAP value.
  FeatureMeasurement? get strongestInfluence {
    FeatureMeasurement? best;
    for (final feature in features) {
      final shap = feature.shap;
      if (shap == null) continue;
      if (best == null || shap.abs() > best.shap!.abs()) best = feature;
    }
    return best;
  }
}

/// The assembled Full Analysis response. Each piece is independently nullable
/// so a missing model, explanation or assessment renders an honest unavailable
/// state instead of failing the whole page. The deterministic joins below are
/// shared logic so the web page only formats and visualizes.
final class FullAnalysis {
  final String propertyId;
  final CommercialProperty? property;
  final ResearchModelMetadata? model;
  final PuPrediction? score;
  final PuFeatureCoverage? coverage;
  final ResearchExplanation? explanation;
  final BusinessTargetEvaluation? targets;

  /// The persisted assessment this analysis is scoped to, null when the
  /// entrepreneur has not started one for the property.
  final String? assessmentId;

  /// Whether Stage 2 answers exist. False means the target section shows the
  /// "complete your business preferences" state, not an empty evaluation.
  final bool hasRequirements;

  const FullAnalysis({
    required this.propertyId,
    this.property,
    this.model,
    this.score,
    this.coverage,
    this.explanation,
    this.targets,
    this.assessmentId,
    this.hasRequirements = false,
  });

  /// A SHAP explanation may only drive the waterfall/drivers/table when it
  /// reconstructs the model output. An inconsistent payload is withheld.
  bool get hasValidShap => explanation != null && explanation!.isAdditive;

  /// The canonical feature taxonomy. The artifact metadata is the source of
  /// truth; a persisted explanation's groups are the fallback so an old
  /// explanation still renders when the metadata read fails. With neither,
  /// there is no honest feature list and the panels stay unavailable.
  List<ModelFeatureSpec> get featureSpecs {
    final metadata = model;
    if (metadata != null &&
        metadata.available &&
        metadata.features.isNotEmpty) {
      return metadata.features;
    }
    final stored = explanation;
    if (stored != null && stored.groups.isNotEmpty) {
      return [
        for (final group in stored.groups)
          for (final name in group.features)
            ModelFeatureSpec(
              name: name,
              category: group.key,
              categoryLabel: group.label,
            ),
      ];
    }
    return const [];
  }

  /// Every model feature joined with its measurement and contribution.
  ///
  /// When a validated explanation exists, ITS values are used — they are the
  /// exact inputs the contributions were computed from. Coverage values are
  /// only shown when there is no explanation (and then no SHAP is shown), so
  /// re-measured data is never paired with an old contribution.
  List<FeatureMeasurement> get measurements {
    final stored = explanation;
    final useStoredValues = stored != null;
    final values = useStoredValues
        ? stored.values
        : (coverage?.values ?? const {});
    final sources = useStoredValues
        ? stored.valueSources
        : (coverage?.valueSources ?? const {});
    return [
      for (final spec in featureSpecs)
        FeatureMeasurement(
          name: spec.name,
          category: spec.category,
          categoryLabel: spec.categoryLabel,
          value: values[spec.name],
          valueSource: sources[spec.name],
          shap: stored?.contributions[spec.name],
        ),
    ];
  }

  /// The five category cards (plus an explicit `other` bucket if the artifact
  /// ever grows an uncategorized feature), in the evidence surface's order.
  List<GeospatialCategorySummary> get categories {
    final rows = measurements;
    final groups = {
      for (final group
          in (explanation?.groups ?? const <CategoryContribution>[]))
        group.key: group,
    };
    final keys = <String>[
      ...fullAnalysisCategoryOrder,
      for (final row in rows)
        if (!fullAnalysisCategoryOrder.contains(row.category) &&
            row.category != 'other')
          row.category,
      if (rows.any((row) => row.category == 'other')) 'other',
    ];
    final seen = <String>{};
    final summaries = <GeospatialCategorySummary>[];
    for (final key in keys) {
      if (!seen.add(key)) continue;
      final members = [
        for (final row in rows)
          if (row.category == key) row,
      ];
      if (members.isEmpty) continue;
      final group = groups[key];
      summaries.add(
        GeospatialCategorySummary(
          key: key,
          label: group?.label ?? members.first.categoryLabel,
          features: members,
          contribution: hasValidShap ? group?.contribution : null,
        ),
      );
    }
    return summaries;
  }

  /// Merged data-quality limits from coverage and the stored explanation.
  EvidenceLimitations get limitations {
    final flags = <String>{...?coverage?.qualityFlags, ...?explanation?.flags};
    final missing =
        explanation?.missingFeatures ??
        coverage?.missingFeatures ??
        const <String>[];
    return EvidenceLimitations(
      flags: flags.toList()..sort(),
      missingFeatures: missing,
      analysisStatus: coverage?.analysisStatus,
    );
  }
}
