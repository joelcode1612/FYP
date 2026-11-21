import 'dart:convert';
import 'dart:io';

import 'package:jaspr/dom.dart';
import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/features/listing/presentation/components/property_detail/compact_location_explanation.dart';
import 'package:sitewise_jaspr_web/features/listing/presentation/components/property_detail/location_fit_score.dart';
import 'package:sitewise_jaspr_web/features/listing/data/property_insights_api.dart';

void main() {
  test('keeps a valid PU score when SHAP is unavailable and preserves provenance', () {
    final insights = PropertyInsights.fromJson({
      'property_id': 'MD-01755',
      'model': {
        'key': 'legacy',
        'name': 'pu_model',
        'layer1_model': 'pu_model',
        'version': 'baseline_47',
        'notes': [],
      },
      'score': {
        'available': true,
        'label': 'Location Fit',
        'value': 98,
        'scale': 100,
        'raw': 0.9799711282139384,
        'band': 'research association index',
        'meaning': 'Research association, not a business-success probability.',
        'kind_label': 'Location similarity to operating F&B sites',
        'source': 'stored_catalogue_prediction',
        'source_label': 'Stored score · verified by live inference',
      },
      'explanation': {'available': false},
      'categories': const [],
      'availability': {
        'score': true,
        'explanation': false,
        'factors': false,
        'categories': false,
      },
      'reason': {
        'code': 'shap_unavailable',
        'message': 'The PU score is available, but its explanation could not be computed.',
      },
    });

    expect(insights.score, isNotNull);
    expect(insights.score!.raw, closeTo(0.9799711282139384, 1e-12));
    expect(insights.score!.source, 'stored_catalogue_prediction');
    expect(insights.score!.sourceLabel, 'Stored score · verified by live inference');
    expect(insights.modelVersion, 'baseline_47');
    expect(insights.explanation, isNull);
    expect(insights.reason!.code, 'shap_unavailable');
  });

  test('parses model-input feature coverage for the availability strip', () {
    final insights = PropertyInsights.fromJson({
      'property_id': 'MD-01755',
      'model': {'layer1_model': 'pu_model', 'version': 'baseline_47'},
      'feature_coverage': {
        'available_features': 47,
        'feature_count': 47,
        'missing_features': <String>[],
      },
    });

    expect(insights.featureCoverage, isNotNull);
    expect(insights.featureCoverage!.availableFeatures, 47);
    expect(insights.featureCoverage!.featureCount, 47);
    expect(insights.featureCoverage!.isComplete, isTrue);

    final partial = PropertyInsights.fromJson({
      'property_id': 'MD-01755',
      'feature_coverage': {
        'available_features': 41,
        'feature_count': 47,
        'missing_features': ['frontage_m', 'depth_m'],
      },
    });
    expect(partial.featureCoverage!.availableFeatures, 41);
    expect(partial.featureCoverage!.isComplete, isFalse);
    expect(partial.featureCoverage!.missingFeatures, ['frontage_m', 'depth_m']);

    // No coverage block at all → null, so the UI renders nothing rather
    // than a fabricated count.
    final none = PropertyInsights.fromJson({'property_id': 'MD-01755'});
    expect(none.featureCoverage, isNull);
  });

  testComponents('renders a valid score while showing SHAP unavailable status', (tester) async {
    final insights = PropertyInsights.fromJson({
      'property_id': 'MD-01755',
      'model': {
        'name': 'pu_model',
        'layer1_model': 'pu_model',
        'version': 'baseline_47',
      },
      'score': {
        'available': true,
        'value': 98,
        'scale': 100,
        'raw': 0.9799711282139384,
        'meaning': 'Research association; not a success probability.',
        'kind_label': 'Location similarity',
        'source': 'stored_catalogue_prediction',
        'source_label': 'Stored score · verified by live inference',
      },
      'explanation': {'available': false},
      'reason': {
        'code': 'shap_unavailable',
        'message': 'The PU score is available, but SHAP could not be computed.',
      },
    });
    tester.pumpComponent(div([
      LocationFitScore(insights: insights),
      CompactLocationExplanation(insights: insights),
    ]));

    expect(find.text('98'), findsOneComponent);
    // The entrepreneur-facing copy is deliberately plain-language: the model
    // provenance stays in the parsed payload (asserted in the data test above)
    // rather than being printed in the score card. Assert the copy actually
    // rendered by LocationFitScore + CompactLocationExplanation.
    expect(find.text('Why this area received its score'), findsOneComponent);
    expect(find.text('The PU score is available, but SHAP could not be computed.'), findsOneComponent);
  });

  testComponents('parses and renders the current read-only backend service payload', (tester) async {
    final audit = jsonDecode(
      File('../backend/ml_reference/pu_artifact_verification_2026_11_12.json')
          .readAsStringSync(),
    ) as Map<String, dynamic>;
    final detail = audit['property_detail_insights'] as Map<String, dynamic>;
    final properties = detail['properties'] as Map<String, dynamic>;
    final response = properties['MD-01755'] as Map<String, dynamic>;
    final insights = PropertyInsights.fromJson(response);

    expect(detail['http_authentication_verified'], false);
    expect(insights.score, isNotNull);
    expect(insights.score!.raw, closeTo(0.9799711282139384, 1e-12));
    expect(insights.score!.source, 'stored_catalogue_prediction');
    expect(insights.score!.sourceLabel, 'Stored score · verified by live inference');
    expect(insights.modelName, 'pu_model');
    expect(insights.modelVersion, 'baseline_47');
    expect(insights.modelArtifact, 'PU_model.joblib');
    expect(
      insights.modelArtifactSha256,
      '5c00c574cfe4cbcb76fe1fb21eb32e40cfea3a428ef1c70ea60c893c1e8c2f98',
    );
    expect(insights.explanation, isNotNull);
    expect(insights.explanation!.additivityOk, true);
    expect(insights.explanation!.output, closeTo(insights.score!.raw, 1e-6));

    tester.pumpComponent(LocationFitScore(insights: insights));
    expect(find.text('98'), findsOneComponent);
    // Provenance (model/version/artifact/SHA) is verified on the parsed payload
    // above; the public score card shows only plain-language interpretation and
    // a demoted audit line. The backend's band sentence IS the explanation —
    // the static fallback must not duplicate it next to a non-empty band.
    expect(
      find.text('This location has many characteristics that may suit an F&B business.'),
      findsOneComponent,
    );
    expect(
      find.text(
        'This area has several characteristics similar to locations where '
        'food businesses already operate.',
      ),
      findsNothing,
    );
  });

  test('preserves experimental model-card caveats for display', () {
    final insights = PropertyInsights.fromJson({
      'property_id': 'MD-01755',
      'model': {
        'name': 'sitewise_pu_47_experimental',
        'layer1_model': 'sitewise_pu_47_experimental',
        'version': 'hist_gradient_boosting@PU_47_CANDIDATE_2026_11_11',
        'notes': [
          'Experimental research model: production_ready=false per model card.',
          'LandScan licence provenance is unresolved.',
        ],
      },
      'score': {'available': false},
      'explanation': {'available': false},
      'categories': const [],
    });

    expect(insights.modelVersion, 'hist_gradient_boosting@PU_47_CANDIDATE_2026_11_11');
    expect(insights.modelNotes, hasLength(2));
    expect(insights.modelNotes.first, contains('production_ready=false'));
  });
}
