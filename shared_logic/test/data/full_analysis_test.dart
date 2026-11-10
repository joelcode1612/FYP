import 'package:shared_logic/shared_logic.dart';
import 'package:test/test.dart';

/// Full Analysis read models: the backend provides every value, Dart only
/// parses, joins and validates. These pin the contracts the page depends on —
/// null never becomes zero, an inconsistent SHAP payload is withheld, the
/// explanation's own values win over re-measured coverage, and target verdicts
/// map fail-closed.
void main() {
  group('PuPrediction.fromJson', () {
    test('maps the research score and keeps the research-only meaning', () {
      final p = PuPrediction.fromJson({
        'property_id': 'EP-1',
        'available': true,
        'score': 0.42,
        'model_version': 'baseline_47',
        'score_meaning': 'research_positive_label_association',
        'feature_count': 47,
        'available_features': 47,
        'missing_features': <String>[],
        'flags': <String>[],
      });
      expect(p.available, isTrue);
      expect(p.positiveLabelAssociation, 0.42);
      expect(p.associationPercent, closeTo(42, 1e-9));
      expect(p.featureCount, 47);
    });

    test('a missing score stays null, never zero', () {
      final p = PuPrediction.fromJson({
        'property_id': 'EP-1',
        'available': false,
        'score': null,
        'reason':
            'Required model features are missing; no score was generated.',
        'missing_features': ['pop_500m'],
      });
      expect(p.available, isFalse);
      expect(p.positiveLabelAssociation, isNull);
      expect(p.associationPercent, isNull);
      expect(p.missingFeatures, ['pop_500m']);
    });
  });

  group('PuFeatureCoverage.fromJson', () {
    test('preserves a null measurement distinctly from a measured zero', () {
      final c = PuFeatureCoverage.fromJson({
        'property_id': 'EP-1',
        'feature_count': 2,
        'available_features': 1,
        'values': {'pop_500m': 0.0, 'pop_1000m': null},
        'value_sources': {
          'pop_500m': 'sitewise_analytics.subject_features.pop_500m',
        },
        'missing_features': ['pop_1000m'],
        'analysis_status': 'COMPLETED',
        'flags': <String>[],
      });
      expect(c.values['pop_500m'], 0.0);
      expect(c.values['pop_1000m'], isNull);
      expect(c.valueSources['pop_500m'], contains('subject_features'));
      expect(c.ready, isFalse);
      expect(c.analysisStatus, 'COMPLETED');
    });
  });

  group('ResearchModelMetadata.fromJson', () {
    test('parses the canonical feature taxonomy', () {
      final m = ResearchModelMetadata.fromJson({
        'available': true,
        'model': 'pu_model',
        'feature_set': 'baseline_47',
        'feature_count': 2,
        'features': [
          {
            'name': 'pop_500m',
            'category': 'population',
            'category_label': 'Population',
          },
          {
            'name': 'worldpop_walk_reachable_10min',
            'category': 'accessibility',
            'category_label': 'Accessibility and transportation',
          },
        ],
      });
      expect(m.available, isTrue);
      expect(m.features, hasLength(2));
      expect(m.features[1].category, 'accessibility');
    });

    test(
      'an unavailable artifact is a successful envelope, not a parse error',
      () {
        final m = ResearchModelMetadata.fromJson({
          'available': false,
          'reason': 'No trained model artifact found.',
          'research_only': true,
        });
        expect(m.available, isFalse);
        expect(m.features, isEmpty);
        expect(m.reason, isNotNull);
      },
    );
  });

  group('ResearchExplanation additivity', () {
    Map<String, dynamic> payload({double output = 0.6}) => {
      'property_id': 'EP-1',
      'assessment_id': 'a-1',
      'available': true,
      'base_value': 0.5,
      'output': output,
      'reconstructed': 0.6,
      'additivity_ok': true,
      'contributions': {'pop_500m': 0.1},
      'values': {'pop_500m': 1234.0},
      'groups': <Map<String, dynamic>>[],
      'research_only': true,
    };

    test('a reconstructing payload is additive', () {
      final e = ResearchExplanation.fromJson(payload());
      expect(e.isAdditive, isTrue);
      expect(e.netContribution, closeTo(0.1, 1e-12));
    });

    test('a payload that does not reconstruct the output is withheld', () {
      final e = ResearchExplanation.fromJson(payload(output: 0.9));
      expect(e.isAdditive, isFalse);
    });

    test(
      'a false backend flag is respected even if the numbers happen to add',
      () {
        final json = payload();
        json['additivity_ok'] = false;
        expect(ResearchExplanation.fromJson(json).isAdditive, isFalse);
      },
    );
  });

  group('BusinessTargetEvaluation', () {
    test('maps verdicts to display statuses fail-closed', () {
      final e = BusinessTargetEvaluation.fromJson({
        'checks': [
          {
            'key': 'affordability',
            'label': 'Affordability',
            'verdict': 'match',
            'detail': 'ok',
            'data': {'asking_rm': 5000, 'ceiling_rm': 7000},
          },
          {
            'key': 'floor_area',
            'label': 'Floor area',
            'verdict': 'mismatch',
            'detail': 'small',
          },
          {
            'key': 'accessibility',
            'label': 'Access',
            'verdict': 'unknown',
            'detail': 'unverified',
          },
          {
            'key': 'competition_context',
            'label': 'Competitors',
            'verdict': 'informational',
            'detail': 'context',
          },
          {
            'key': 'mystery',
            'label': 'Mystery',
            'verdict': 'something_new',
            'detail': '?',
          },
        ],
        'matched': 1,
        'mismatched': 1,
        'unknown': 1,
      });
      expect(e.checks[0].status, BusinessTargetStatus.achieved);
      expect(e.checks[0].data['asking_rm'], 5000);
      expect(e.checks[1].status, BusinessTargetStatus.notAchieved);
      expect(e.checks[2].status, BusinessTargetStatus.requiresVerification);
      expect(e.checks[3].status, BusinessTargetStatus.context);
      expect(e.checks[4].status, BusinessTargetStatus.requiresVerification);
      expect(e.hasChecks, isTrue);
    });
  });

  group('FullAnalysis joins', () {
    ResearchModelMetadata metadata() => ResearchModelMetadata.fromJson({
      'available': true,
      'features': [
        {
          'name': 'pop_500m',
          'category': 'population',
          'category_label': 'Population',
        },
        {
          'name': 'pop_1000m',
          'category': 'population',
          'category_label': 'Population',
        },
        {
          'name': 'office_pois_500m',
          'category': 'demand_generators',
          'category_label': 'Demand generators',
        },
        {
          'name': 'nearest_transit_walk_m',
          'category': 'accessibility',
          'category_label': 'Accessibility and transportation',
        },
        {
          'name': 'parking_facilities_500m',
          'category': 'parking',
          'category_label': 'Parking',
        },
        {
          'name': 'fnb_competitors_500m',
          'category': 'competitors',
          'category_label': 'Competitors',
        },
      ],
    });

    ResearchExplanation explanation() => ResearchExplanation.fromJson({
      'property_id': 'EP-1',
      'assessment_id': 'a-1',
      'available': true,
      'base_value': 0.5,
      'output': 0.58,
      'reconstructed': 0.58,
      'additivity_ok': true,
      'contributions': {
        'pop_500m': 0.06,
        'pop_1000m': 0.04,
        'fnb_competitors_500m': -0.02,
      },
      'values': {
        'pop_500m': 100.0,
        'pop_1000m': null,
        'fnb_competitors_500m': 8.0,
      },
      'value_sources': {'pop_500m': 'stored.source'},
      'groups': [
        {
          'key': 'population',
          'label': 'Population',
          'contribution': 0.1,
          'feature_count': 2,
          'features': ['pop_500m', 'pop_1000m'],
        },
        {
          'key': 'competitors',
          'label': 'Competitors',
          'contribution': -0.02,
          'feature_count': 1,
          'features': ['fnb_competitors_500m'],
        },
      ],
      'research_only': true,
    });

    PuFeatureCoverage coverage() => PuFeatureCoverage.fromJson({
      'property_id': 'EP-1',
      'feature_count': 6,
      'available_features': 6,
      'values': {
        'pop_500m': 999.0,
        'pop_1000m': 200.0,
        'office_pois_500m': 3.0,
      },
      'value_sources': {'pop_500m': 'coverage.source'},
      'missing_features': <String>[],
      'flags': <String>[],
    });

    test('explanation values win over re-measured coverage values', () {
      final a = FullAnalysis(
        propertyId: 'EP-1',
        model: metadata(),
        coverage: coverage(),
        explanation: explanation(),
      );
      final pop500 = a.measurements.firstWhere((m) => m.name == 'pop_500m');
      expect(
        pop500.value,
        100.0,
        reason: 'must pair the stored input with its contribution',
      );
      expect(pop500.valueSource, 'stored.source');
      expect(pop500.shap, 0.06);
      expect(a.hasValidShap, isTrue);
    });

    test('a missing stored value stays null even if coverage measured it', () {
      final a = FullAnalysis(
        propertyId: 'EP-1',
        model: metadata(),
        coverage: coverage(),
        explanation: explanation(),
      );
      final pop1000 = a.measurements.firstWhere((m) => m.name == 'pop_1000m');
      expect(
        pop1000.value,
        isNull,
        reason: 'not recorded in the explanation, not zero or 200',
      );
    });

    test('without an explanation, coverage values show but no SHAP does', () {
      final a = FullAnalysis(
        propertyId: 'EP-1',
        model: metadata(),
        coverage: coverage(),
      );
      final pop500 = a.measurements.firstWhere((m) => m.name == 'pop_500m');
      expect(pop500.value, 999.0);
      expect(pop500.shap, isNull);
      expect(a.hasValidShap, isFalse);
      expect(a.categories.every((c) => c.contribution == null), isTrue);
    });

    test('categories follow the canonical order with measured counts', () {
      final a = FullAnalysis(
        propertyId: 'EP-1',
        model: metadata(),
        explanation: explanation(),
      );
      final keys = a.categories.map((c) => c.key).toList();
      expect(keys, [
        'population',
        'demand_generators',
        'accessibility',
        'parking',
        'competitors',
      ]);
      final population = a.categories.first;
      expect(population.featureCount, 2);
      expect(population.measuredCount, 1);
      expect(population.contribution, 0.1);
      expect(population.strongestInfluence?.name, 'pop_500m');
    });

    test('falls back to explanation groups when metadata is unavailable', () {
      final a = FullAnalysis(propertyId: 'EP-1', explanation: explanation());
      expect(a.featureSpecs, hasLength(3));
      expect(a.measurements.every((m) => m.category != 'other'), isTrue);
    });

    test('no taxonomy source means no invented feature rows', () {
      final a = FullAnalysis(propertyId: 'EP-1', coverage: coverage());
      expect(a.featureSpecs, isEmpty);
      expect(a.measurements, isEmpty);
      expect(a.categories, isEmpty);
    });

    test('an inconsistent explanation is not treated as valid SHAP', () {
      final broken = ResearchExplanation.fromJson({
        'property_id': 'EP-1',
        'assessment_id': 'a-1',
        'available': true,
        'base_value': 0.5,
        'output': 0.99,
        'reconstructed': 0.6,
        'additivity_ok': true,
        'contributions': {'pop_500m': 0.1},
        'groups': [
          {
            'key': 'population',
            'label': 'Population',
            'contribution': 0.1,
            'feature_count': 1,
            'features': ['pop_500m'],
          },
        ],
      });
      final a = FullAnalysis(propertyId: 'EP-1', explanation: broken);
      expect(a.hasValidShap, isFalse);
      expect(a.categories.first.contribution, isNull);
    });
  });

  group('ApiPuPredictionRepository', () {
    test(
      'requests the read-only research routes and parses payloads',
      () async {
        final client = _RouteFakeApiClient({
          '/api/v1/ml/model': {
            'available': true,
            'model': 'pu_model',
            'features': <Map<String, dynamic>>[],
          },
          '/api/v1/ml/properties/EP-1/prediction': {
            'property_id': 'EP-1',
            'available': true,
            'score': 0.5,
          },
          '/api/v1/ml/properties/EP-1/coverage': {
            'property_id': 'EP-1',
            'feature_count': 47,
            'available_features': 47,
            'values': <String, dynamic>{},
          },
        });
        final repo = ApiPuPredictionRepository(client);
        expect((await repo.modelMetadata()).model, 'pu_model');
        expect(
          (await repo.getPropertyPrediction('EP-1')).positiveLabelAssociation,
          0.5,
        );
        expect((await repo.getPropertyCoverage('EP-1')).featureCount, 47);
        expect(client.calls, [
          '/api/v1/ml/model',
          '/api/v1/ml/properties/EP-1/prediction',
          '/api/v1/ml/properties/EP-1/coverage',
        ]);
      },
    );

    test(
      'propagates a transport failure rather than inventing a score',
      () async {
        final repo = ApiPuPredictionRepository(
          _RouteFakeApiClient({}, error: StateError('503')),
        );
        await expectLater(
          repo.getPropertyPrediction('EP-1'),
          throwsA(isA<StateError>()),
        );
      },
    );
  });
}

/// Replays a canned payload per exact path; records the call order. Write verbs
/// are unimplemented so an accidental mutation fails loudly.
class _RouteFakeApiClient implements ApiClient {
  final Map<String, Map<String, dynamic>> routes;
  final Object? error;
  final List<String> calls = [];

  _RouteFakeApiClient(this.routes, {this.error});

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    calls.add(path);
    if (error != null) throw error!;
    return routes[path] ?? <String, dynamic>{};
  }

  @override
  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> patch(String path, Map<String, dynamic> body) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> delete(String path) =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> uploadMultipart(
    String path, {
    required Map<String, String> fields,
    required String fileField,
    required String filename,
    required List<int> bytes,
    required String contentType,
  }) => throw UnimplementedError();

  @override
  Future<List<int>> downloadBinary(String path) => throw UnimplementedError();
}
