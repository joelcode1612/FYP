import 'package:test/test.dart';
import 'package:shared_logic/shared_logic.dart';

/// The Location Intelligence measurement block must render exactly what the
/// backend measured: a measured zero stays a zero, an unavailable feature stays
/// null, and one missing category never removes the others.
void main() {
  Map<String, dynamic> payload({
    Map<String, dynamic>? values,
    Map<String, dynamic>? states,
    Map<String, dynamic>? categories,
    Map<String, dynamic>? district,
  }) => {
    'geospatial_features': null,
    'competitor_counts': const <String, dynamic>{},
    'location_measurements': {
      'available': (values ?? const {}).isNotEmpty,
      'calculated_features': (values ?? const {}).length,
      'feature_count': 64,
      'calculation_status': 'current',
      'has_coordinates': true,
      'feature_values': values ?? const <String, dynamic>{},
      'feature_states': states ?? const <String, dynamic>{},
      'feature_sources': const <String, dynamic>{},
      'feature_methods': const <String, dynamic>{},
      'categories': categories ?? const <String, dynamic>{},
      'district_context': district ?? const <String, dynamic>{},
    },
  };

  LocationMeasurement rowOf(LocationAnalysis a, String key) => a.measurementGroups
      .expand((group) => group.rows)
      .firstWhere((row) => row.key == key);

  test('absent measurement block renders nothing', () {
    final analysis = LocationAnalysisRules.analyse('316', {
      'geospatial_features': null,
      'competitor_counts': const <String, dynamic>{},
    });
    expect(analysis.hasMeasurementReport, isFalse);
    expect(analysis.measurementGroups, isEmpty);
    expect(analysis.hasMeasuredValues, isFalse);
  });

  test('measured zero is preserved and is not the same as unavailable', () {
    final analysis = LocationAnalysisRules.analyse(
      '316',
      payload(
        values: {'hospitals_count_500m': 0.0, 'pop_500m': 1071.6},
        states: {
          'hospitals_count_500m': 'validated',
          'pop_500m': 'validated',
          'pop_1000m': 'unavailable',
        },
        categories: {
          'population': {'status': 'current', 'calculated': 1, 'total': 4},
        },
      ),
    );

    final zero = rowOf(analysis, 'hospitals_count_500m');
    expect(zero.measured, isTrue);
    expect(zero.value, 0.0);
    expect(zero.display, '0');

    final absent = rowOf(analysis, 'pop_1000m');
    expect(absent.measured, isFalse);
    expect(absent.value, isNull);
    expect(absent.display, 'Not measured');
  });

  test('unvalidated measurements are shown and flagged, not hidden', () {
    final analysis = LocationAnalysisRules.analyse(
      '316',
      payload(
        values: {'fnb_competitors_500m': 1.0, 'pop_500m': 900.0},
        states: {
          'fnb_competitors_500m': 'calculated_unvalidated',
          'pop_500m': 'validated',
        },
      ),
    );
    final competitor = rowOf(analysis, 'fnb_competitors_500m');
    expect(competitor.measured, isTrue);
    expect(competitor.informationalOnly, isTrue);
    expect(rowOf(analysis, 'pop_500m').informationalOnly, isFalse);
    expect(analysis.hasMeasuredValues, isTrue);
  });

  test('one unavailable category does not hide the others', () {
    final analysis = LocationAnalysisRules.analyse(
      '316',
      payload(
        values: {'pop_500m': 500.0},
        states: {'pop_500m': 'validated'},
        categories: {
          'population': {'status': 'current', 'calculated': 1, 'total': 4},
          'transit': {
            'status': 'failed',
            'calculated': 0,
            'total': 5,
            'reason': 'Routing source timed out',
          },
        },
      ),
    );
    final population = analysis.measurementGroups
        .firstWhere((group) => group.key == 'population');
    final transit = analysis.measurementGroups
        .firstWhere((group) => group.key == 'transit');

    expect(population.available, isTrue);
    expect(population.measuredCount, 1);
    expect(population.total, 4);

    expect(transit.available, isFalse);
    expect(transit.status, 'failed');
    expect(transit.reason, 'Routing source timed out');
    expect(transit.rows.length, 5);
    expect(transit.rows.every((row) => !row.measured), isTrue);
  });

  test('district income is labelled district-level and never property-level', () {
    final analysis = LocationAnalysisRules.analyse(
      '316',
      payload(
        values: {'pop_500m': 500.0},
        district: {
          'district': 'Klang',
          'state': 'Selangor',
          'income_median': 8837.0,
          'gini': 0.299,
          'poverty': 1.0,
        },
      ),
    );
    final group = analysis.measurementGroups
        .firstWhere((group) => group.key == 'socioeconomic');
    expect(group.title, 'Household and income');
    final median = group.rows
        .firstWhere((row) => row.key == 'district_income_median');
    expect(median.value, 8837.0);
    expect(median.unit, 'RM/month');
    expect(median.label, contains('district'));
    expect(median.source, contains('Klang'));
  });

  test('every displayed feature name exists in the backend contract list', () {
    // Guards against a rename on one side only: the label table must describe
    // exactly the 64 backend feature names, no more and no less.
    final displayed = <String>{
      for (final entry in LocationAnalysisRules.measurementRows.entries)
        for (final (key, _, _) in entry.value) key,
    };
    expect(displayed.length, 64);
    expect(displayed, contains('road_length_density_500m_km_km2'));
    expect(displayed, contains('worldpop_walk_reachable_10min'));
    expect(displayed, contains('drive_isochrone_area_10min_km2'));
    expect(
      displayed,
      isNot(contains('district_income_median')),
      reason: 'district figures are not model features',
    );
  });
}
