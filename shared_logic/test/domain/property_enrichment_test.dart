import 'package:shared_logic/src/domain/entities/property_enrichment.dart';
import 'package:test/test.dart';

/// Payload shapes below mirror real `POST /enrich` responses captured from the
/// live backend: phase 1 current, phase 2 unavailable because no raster covers
/// the coordinates.
Map<String, dynamic> _summaryPayload({
  String populationStatus = 'unavailable',
  Map<String, dynamic>? populationMeasurement,
  Map<String, dynamic>? populationProvenance,
  bool running = false,
}) {
  Map<String, dynamic> category(
    String status,
    Map<String, dynamic>? measurement, {
    Map<String, dynamic>? provenance,
  }) => {
    'category': 'x',
    'status': status,
    'measurement': measurement,
    'provenance': provenance,
    'attempt_count': 1,
    'started_at': '2026-11-12T01:00:00+00:00',
    'completed_at': '2026-11-12T01:00:01+00:00',
    'last_error': null,
  };

  return {
    'property_id': 9001,
    'calculation_version': 'property-enrichment-v1',
    'phase1': {
      'total': 4,
      'settled': 4,
      'running': 0,
      'complete': true,
    },
    'phase2': {
      'total': 1,
      'settled': running ? 0 : 1,
      'running': running ? 1 : 0,
      'complete': !running,
    },
    'population_unavailable': populationStatus == 'unavailable',
    'ready_to_submit': !running,
    'categories': {
      'fnb_competitors': category('current', {
        'competitor_count_500m': 9,
        'competitor_count_1km': 30,
      }, provenance: {'source': 'fnb_a.fnb_outlet', 'licence': 'ODbL'}),
      'demand_generators': category('current', {
        'demand_generator_count_500m': 3,
        'demand_generator_count_1km': 6,
      }),
      'roads_transport': category('current', {
        'accessibility_road_km_1km': 21.79,
        'nearest_major_road_m': 68.1,
        'transit_stops_500m': 9,
        'transit_stops_1km': 30,
      }),
      'parking': category('current', {
        'parking_facilities_500m': 6,
        'parking_facilities_1km': 12,
        'nearest_parking_m': 276.8,
      }),
      'population': category(
        running ? 'running' : populationStatus,
        populationMeasurement,
        provenance: populationProvenance ??
            {'reason': 'no_population_raster_coverage'},
      ),
    },
  };
}

void main() {
  group('EnrichmentCategory', () {
    test('wire values match the backend vocabulary exactly', () {
      expect(
        EnrichmentCategory.values.map((c) => c.wire).toList(),
        [
          'fnb_competitors',
          'demand_generators',
          'roads_transport',
          'parking',
          'population',
        ],
      );
    });

    test('phase split is four PostGIS categories and one raster category', () {
      expect(EnrichmentCategory.phaseOne, hasLength(4));
      expect(EnrichmentCategory.phaseTwo, [EnrichmentCategory.population]);
      for (final category in EnrichmentCategory.phaseOne) {
        expect(category.phase, EnrichmentPhase.postgis);
      }
    });

    test('an unknown wire value is not silently mapped', () {
      expect(EnrichmentCategory.fromWire('traffic'), isNull);
      expect(EnrichmentCategory.fromWire(null), isNull);
    });
  });

  group('EnrichmentStatus', () {
    test('only settled states count as finished', () {
      expect(EnrichmentStatus.running.settled, isFalse);
      expect(EnrichmentStatus.pending.settled, isFalse);
      for (final status in [
        EnrichmentStatus.current,
        EnrichmentStatus.unavailable,
        EnrichmentStatus.failed,
        EnrichmentStatus.stale,
      ]) {
        expect(status.settled, isTrue, reason: status.wire);
      }
    });

    test('an unavailable category is retryable and has no measurement', () {
      expect(EnrichmentStatus.unavailable.retryable, isTrue);
      expect(EnrichmentStatus.unavailable.hasMeasurement, isFalse);
      expect(EnrichmentStatus.current.hasMeasurement, isTrue);
      expect(EnrichmentStatus.running.retryable, isFalse);
    });

    test('an unknown status falls back to pending, never to current', () {
      expect(EnrichmentStatus.fromWire('exploded'), EnrichmentStatus.pending);
    });
  });

  group('PropertyEnrichmentSummary', () {
    test('parses the real phase-1 payload', () {
      final summary =
          PropertyEnrichmentSummary.fromJson(_summaryPayload());

      expect(summary.propertyId, 9001);
      expect(summary.calculationVersion, 'property-enrichment-v1');
      expect(summary.phaseOneComplete, isTrue);
      expect(summary.phaseTwoComplete, isTrue);
      expect(summary.categories, hasLength(5));
      expect(
        summary.state(EnrichmentCategory.fnbCompetitors).number(
          'competitor_count_500m',
        ),
        9,
      );
      expect(
        summary.state(EnrichmentCategory.roadsTransport).number(
          'transit_stops_1km',
        ),
        30,
      );
    });

    test('a missing category is reported as pending, not omitted', () {
      final summary = PropertyEnrichmentSummary.fromJson({
        'property_id': 7,
        'categories': const <String, dynamic>{},
      });

      expect(summary.categories, hasLength(5));
      for (final category in EnrichmentCategory.values) {
        expect(summary.state(category).status, EnrichmentStatus.pending);
      }
      expect(summary.progress, 0);
    });

    test('progress counts settled categories', () {
      final summary = PropertyEnrichmentSummary.fromJson(_summaryPayload());
      expect(summary.progress, 1.0);

      final running = PropertyEnrichmentSummary.fromJson(
        _summaryPayload(running: true),
      );
      expect(running.progress, closeTo(4 / 5, 1e-9));
      expect(running.isRunning, isTrue);
    });

    test('an unavailable population is flagged for the submit guard', () {
      final summary = PropertyEnrichmentSummary.fromJson(_summaryPayload());
      expect(summary.populationUnavailable, isTrue);
      expect(summary.population.status, EnrichmentStatus.unavailable);
      expect(
        summary.population.reason,
        'No population raster covers these coordinates.',
      );
      // It is not a measurement, so nothing numeric can be read from it.
      expect(summary.population.number('population_500m'), isNull);
      expect(summary.population.measurement, isNull);
    });

    test('a measured population exposes both radii', () {
      final summary = PropertyEnrichmentSummary.fromJson(_summaryPayload(
        populationStatus: 'current',
        populationMeasurement: {
          'population_500m': 13656.0,
          'population_1km': 24322.0,
        },
        populationProvenance: {
          'source': 'public.landscan_2024',
          'radii_unavailable': <String>[],
        },
      ));

      expect(summary.populationUnavailable, isFalse);
      expect(summary.population.number('population_500m'), 13656.0);
      expect(summary.population.number('population_1km'), 24322.0);
      expect(summary.population.unavailableRadii, isEmpty);
      expect(summary.population.reason, isNull);
    });

    test('a partially covered population names the missing radius', () {
      // Property 93 measured 1 km but the 500 m pixels are nodata.
      final summary = PropertyEnrichmentSummary.fromJson(_summaryPayload(
        populationStatus: 'current',
        populationMeasurement: {
          'population_500m': null,
          'population_1km': 37068.0,
        },
        populationProvenance: {
          'source': 'public.landscan_2024',
          'radii_unavailable': ['500m'],
        },
      ));

      expect(summary.population.number('population_500m'), isNull);
      expect(summary.population.number('population_1km'), 37068.0);
      expect(summary.population.unavailableRadii, ['500m']);
    });

    test('retryable lists exactly the unsettled categories', () {
      final summary = PropertyEnrichmentSummary.fromJson(_summaryPayload());
      expect(summary.retryable, [EnrichmentCategory.population]);
    });

    test('a failed category surfaces the backend error verbatim', () {
      final summary = PropertyEnrichmentSummary.fromJson({
        'property_id': 1,
        'categories': {
          'parking': {
            'status': 'failed',
            'measurement': null,
            'provenance': null,
            'last_error': 'parking source unavailable',
          },
        },
      });
      expect(
        summary.state(EnrichmentCategory.parking).reason,
        'parking source unavailable',
      );
    });

    test('a category with no coordinates explains itself', () {
      final summary = PropertyEnrichmentSummary.fromJson({
        'property_id': 1,
        'categories': {
          'population': {
            'status': 'unavailable',
            'provenance': {'reason': 'property_has_no_coordinates'},
          },
        },
      });
      expect(
        summary.population.reason,
        'This listing has no confirmed coordinates yet.',
      );
    });
  });
}
