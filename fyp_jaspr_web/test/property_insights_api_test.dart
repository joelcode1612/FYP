import 'dart:convert';
import 'dart:io';

import 'package:jaspr/dom.dart';
import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/components/property_detail/location_fit_score.dart';
import 'package:sitewise_jaspr_web/components/property_detail/shap_contribution_chart.dart';
import 'package:sitewise_jaspr_web/data/property_insights_api.dart';

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
      ShapContributionChart(
        insights: insights,
        showAll: false,
        showTechnical: false,
        onToggleAll: () {},
        onToggleTechnical: () {},
      ),
    ]));

    expect(find.text('98'), findsOneComponent);
    expect(find.text('Stored score · verified by live inference'), findsOneComponent);
    expect(find.text('Why this location received this score'), findsOneComponent);
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
    expect(find.text('Stored score · verified by live inference'), findsOneComponent);
    expect(find.text('pu_model · baseline_47'), findsOneComponent);
    expect(find.text('PU_model.joblib · SHA-256 5c00c574cfe4'), findsOneComponent);
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
