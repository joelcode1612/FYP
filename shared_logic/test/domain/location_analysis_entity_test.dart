import 'package:test/test.dart';
// The barrel hides the staff `LocationAnalysis` (the entrepreneur one is the
// exported name); the staff report types come in through this direct import.
import 'package:shared_logic/src/domain/entities/property_verification.dart'
    as staff;

void main() {
  group('LocationAnalysis entity parsing', () {
    test('parses a full staff-detail payload', () {
      final analysis = staff.LocationAnalysis.fromJson({
        'analysis_version': '2026.11-1',
        'generated_at': '2026-11-15T05:11:09+00:00',
        'available': true,
        'part_a': {
          'state': 'ready_for_admin_review',
          'listing_status': 'pending',
          'ownership_status': 'pending',
          'checks': [
            {
              'id': 'photos',
              'label': 'Listing photographs',
              'status': 'ok',
              'detail': '3 photograph(s) uploaded.',
            },
          ],
        },
        'part_b': {
          'population': {
            'available': true,
            'method': 'raster rings',
            'source': 'worldpop_2025_constrained (2025)',
            'pop_500m': 1071.6,
            'pop_1km': 6431.8,
            'landscan_ambient_1km': 2749.0,
            'landscan_source_year': '2024',
            'quality_flag': 'PARTIAL_COVERAGE',
          },
          'socioeconomic': {
            'available': true,
            'method': 'DOSM district',
            'source': 'DOSM district income',
            'income_median': 8837.0,
          },
          'fnb_environment': {
            'available': true,
            'method': 'research outlets',
            'source': 'fnb_a',
            'competitor_count_500m': 9,
            'competitor_breakdown_500m': {
              'cafes_500m': 2,
              'restaurants_500m': 5,
              'fast_food_500m': 2,
            },
          },
          'accessibility': {
            'available': true,
            'method': 'index + walk figures',
            'source': 'OSM · GTFS',
            'accessibility_score': 62.79,
            'transit': {'bus_stops_500m_walk': 0, 'nearest_transit_walk_m': 3092.4},
          },
          'research_association': {
            'available': false,
            'score': null,
            'feature_count': 47,
            'available_features': 42,
            'missing_features': ['fnb_competitors_500m'],
            'unavailable_reason':
                'Required model features are missing; no score was generated.',
            'score_meaning': 'research_positive_label_association',
            'research_only': true,
          },
        },
        'part_c': {
          'families_total': 5,
          'families_available': 3,
          'families_available_names': ['population', 'socioeconomic', 'accessibility'],
          'missing': [
            {
              'family': 'fnb_environment',
              'reason': 'No F&B surrounding measurement has been calculated.',
            },
          ],
          'outdated': [
            {'what': 'feature snapshot', 'status': 'stale', 'detail': 'drift'},
          ],
          'resolution_notes': ['Straight-line radii only.'],
          'licences': [
            {'source': 'openstreetmap', 'licence': 'ODbL'},
          ],
        },
        'recommendation': {
          'text': 'The listing looks ready for review.',
          'policy_separation': [
            {
              'domain': 'publication_eligibility',
              'current_status': false,
              'is_published': false,
              'note': 'Recomputed by the decision workflow.',
            },
          ],
          'suggested_focus': ['No photographs have been uploaded.'],
        },
      });

      expect(analysis.available, isTrue);
      expect(analysis.partA.state, 'ready_for_admin_review');
      expect(analysis.partA.checks.single.id, 'photos');
      expect(analysis.partB.population.pop500m, 1071.6);
      expect(analysis.partB.population.landscanAmbient1km, 2749.0);
      expect(analysis.partB.population.landscanAmbientRatio1km, isNull);
      expect(analysis.partB.socioeconomic.incomeMedian, 8837.0);
      expect(
        analysis.partB.fnbEnvironment.competitorBreakdown500m['cafes_500m'],
        2.0,
      );
      expect(
        analysis.partB.accessibility.transit['nearest_transit_walk_m'],
        3092.4,
      );
      expect(analysis.partB.researchAssociation.available, isFalse);
      expect(analysis.partB.researchAssociation.availableFeatures, 42);
      expect(
        analysis.partB.researchAssociation.missingFeatures,
        ['fnb_competitors_500m'],
      );
      expect(analysis.partC.familiesAvailable, 3);
      expect(analysis.partC.missing.single.family, 'fnb_environment');
      expect(analysis.partC.outdated.single.status, 'stale');
      expect(analysis.partC.licences.single.licence, 'ODbL');
      expect(analysis.recommendation.policySeparation.single.domain,
          'publication_eligibility');
      expect(analysis.recommendation.suggestedFocus, hasLength(1));
    });

    test('an empty or unavailable payload degrades to explicit unavailability',
        () {
      final unavailable = staff.LocationAnalysis.fromJson({});
      expect(unavailable.available, isFalse);
      expect(unavailable.partA.state, 'unavailable');
      expect(unavailable.partB.population.available, isFalse);
      expect(unavailable.partC.familiesTotal, 0);

      final failed = staff.LocationAnalysis.fromJson({
        'available': false,
        'error': 'Location analysis could not be assembled: boom',
        'part_a': {'state': 'unknown'},
      });
      expect(failed.available, isFalse);
      expect(failed.error, contains('boom'));
    });

    test('VerificationDetail defaults to an unavailable analysis when the key '
        'is missing (older backend payloads keep parsing)', () {
      final detail = staff.VerificationDetail.fromJson(<String, dynamic>{
        'property': <String, dynamic>{'property_id': 7},
        'verification': <String, dynamic>{},
      });
      expect(detail.locationAnalysis.available, isFalse);
      expect(detail.locationAnalysis.partA.state, 'unavailable');
    });
  });
}
