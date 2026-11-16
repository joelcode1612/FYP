import 'package:shared_logic/src/domain/entities/recommendation_search.dart';
import 'package:test/test.dart';

/// The contract behind the interconnected filter form.
///
/// The fixtures below are verbatim shapes from
/// `GET /api/v1/recommendations/facets` over the live catalogue with Johor and
/// `Shop lot` selected, so they assert what the client does with real
/// leave-one-out counts — including the property that every state option
/// (114 + 79 + 65 + 41) sums to the count releasing the state restores, and
/// the rental bands (44 + 14 + 6 + 1) sum to the population they price.
void main() {
  Map<String, dynamic> contextual() => {
    'states': [
      {'value': 'Selangor', 'total': 114},
      {'value': 'Pulau Pinang', 'total': 79},
      {'value': 'Johor', 'total': 65},
      {'value': 'W.P. Kuala Lumpur', 'total': 41},
    ],
    'property_types': [
      {'value': 'Shop lot', 'total': 65},
      {'value': 'Shophouse / Shop-office', 'total': 18},
    ],
    'sort_options': [
      {'value': 'best_match', 'label': 'Best requirement match'},
      {'value': 'rent_asc', 'label': 'Lowest monthly rent'},
    ],
    'rental_ranges': {
      'options': [
        {
          'min_rental_rm': 800.0,
          'max_rental_rm': 5000.0,
          'total': 44,
          'label': 'RM 800 – RM 5,000',
        },
        {
          'min_rental_rm': 6000.0,
          'max_rental_rm': 10000.0,
          'total': 14,
          'label': 'RM 6,000 – RM 10,000',
        },
        {
          'min_rental_rm': 11000.0,
          'max_rental_rm': 15000.0,
          'total': 6,
          'label': 'RM 11,000 – RM 15,000',
        },
        {'min_rental_rm': 20000.0, 'max_rental_rm': 20000.0, 'total': 1,
          'label': 'RM 20,000'},
      ],
      'unbounded_total': 65,
      'selected': null,
    },
    'size_ranges': {
      'options': [
        {
          'min_size_sqft': 650.0,
          'max_size_sqft': 1628.0,
          'total': 36,
          'label': '650 – 1,628 sq ft',
        },
        {
          'min_size_sqft': 1650.0,
          'max_size_sqft': 2640.0,
          'total': 21,
          'label': '1,650 – 2,640 sq ft',
        },
      ],
      'unbounded_total': 65,
      'selected': null,
    },
    'matching_total': 65,
    'universe_total': 351,
    'relaxations': [
      {'field': 'preferred_state', 'label': 'Preferred state', 'total': 299},
      {'field': 'property_type', 'label': 'Property type', 'total': 83},
    ],
    'fields': [
      {
        'key': 'preferred_state',
        'label': 'Preferred state',
        'role': 'hard_filter',
        'effect': 'Only listings in the selected state remain eligible.',
      },
      {
        'key': 'business_type',
        'label': 'Business type',
        'role': 'ranking_only',
        'effect': 'Orders the eligible set. It does not remove properties.',
      },
      {
        'key': 'target_market',
        'label': 'Target market',
        'role': 'unverified',
        'effect': 'The catalogue records no customer-mix field.',
      },
    ],
    'contextual': true,
    'pu_eligibility': {
      'threshold': 50.0,
      'scale': '0-100',
      'comparison': 'strictly_greater_than',
      'column': 'live_expanded64_inference',
    },
  };

  group('contextual facets', () {
    test('carries the server-priced intervals, totals and alternatives', () {
      final facets = RecommendationFacets.fromJson(contextual());
      expect(facets.contextual, isTrue);
      expect(facets.matchingTotal, 65);
      expect(facets.universeTotal, 351);
      expect(facets.puThreshold, 50.0);
      expect(facets.rentalRanges, hasLength(4));
      expect(facets.rentalRanges.first.low, 800.0);
      expect(facets.rentalRanges.first.high, 5000.0);
      expect(facets.rentalRanges.first.total, 44);
      expect(facets.rentalRanges.first.label, 'RM 800 – RM 5,000');
      expect(facets.rentalUnboundedTotal, 65);
      expect(facets.sizeRanges.last.total, 21);
      expect(facets.selectedRentalRange, isNull);
      // Every band is counted over the same population it would return.
      expect(
        facets.rentalRanges.fold<int>(0, (sum, r) => sum + r.total),
        facets.rentalUnboundedTotal,
      );
      expect(
        facets.states.fold<int>(0, (sum, s) => sum + s.total),
        facets.relaxations.first.total,
      );
      expect(facets.states[2].value, 'Johor');
      expect(facets.states[2].total, 65);
      expect(facets.relaxations.map((r) => r.field), [
        'preferred_state',
        'property_type',
      ]);
      expect(facets.relaxations.first.label, 'Preferred state');
      expect(facets.sortOptions.keys, ['best_match', 'rent_asc']);
    });

    test('reports which inputs filter and which only order', () {
      final facets = RecommendationFacets.fromJson(contextual());
      expect(facets.roleOf('preferred_state'), FilterRole.hardFilter);
      expect(facets.roleOf('business_type'), FilterRole.rankingOnly);
      expect(facets.roleOf('target_market'), FilterRole.unverified);
      expect(facets.effectOf('business_type'), contains('does not remove'));
      // A key the server never described is treated as the constraint it most
      // likely is, so an unknown input cannot silently claim to be cosmetic.
      expect(facets.roleOf('not_a_field'), FilterRole.hardFilter);
      expect(facets.effectOf('not_a_field'), isEmpty);
      expect(facets.labelOf('preferred_state', fallback: 'State'),
          'Preferred state');
      expect(facets.labelOf('missing', fallback: 'State'), 'State');
    });

    test('an out-of-band selection stays visible with its own count', () {
      final payload = contextual();
      payload['rental_ranges']['selected'] = {
        'min_rental_rm': 1000.0,
        'max_rental_rm': 25000.0,
        'label': 'RM 1,000 – RM 25,000',
        'total': 0,
        'generated': false,
      };
      payload['matching_total'] = 0;
      final facets = RecommendationFacets.fromJson(payload);
      final selected = facets.selectedRentalRange!;
      expect(selected.generated, isFalse);
      expect(selected.total, 0);
      expect(selected.matches(1000.0, 25000.0), isTrue);
      // No generated band covers it, so the form must not drop the choice.
      expect(
        facets.rentalRanges.any((r) => r.matches(1000.0, 25000.0)),
        isFalse,
      );
      expect(facets.matchingTotal, 0);
    });

    test('an uncalled-catalogue payload degrades to nothing rather than to '
        'fabricated options', () {
      final facets = RecommendationFacets.fromJson(const {
        'states': [
          {'value': 'Johor', 'total': 151},
        ],
        'ranges': {'min_rental_rm': 500.0, 'total': 351},
      });
      expect(facets.contextual, isFalse);
      expect(facets.rentalRanges, isEmpty);
      expect(facets.sizeRanges, isEmpty);
      expect(facets.selectedRentalRange, isNull);
      expect(facets.matchingTotal, isNull);
      expect(facets.relaxations, isEmpty);
      expect(facets.puThreshold, isNull);
      expect(facets.states.single.value, 'Johor');
    });
  });

  group('facetsQuery', () {
    test('sends only the filters that can move a count', () {
      const request = RecommendationSearchRequest(
        businessType: 'Cafe / Coffee Shop',
        preferredState: 'Johor',
        propertyType: 'Shop lot',
        minRentalRm: 3000,
        maxRentalRm: 8000.5,
        layoutPreferences: ['Students'],
        query: 'Petaling',
      );
      expect(request.facetsQuery, {
        'preferred_state': 'Johor',
        'property_type': 'Shop lot',
        'min_rental_rm': '3000',
        'max_rental_rm': '8000.5',
        'query': 'Petaling',
      });
    });

    test('a browse sends nothing and management scope travels', () {
      expect(const RecommendationSearchRequest().facetsQuery, isEmpty);
      expect(
        const RecommendationSearchRequest(
          managedOnly: true,
          preferredArea: 'KLCC',
          maxSizeSqft: 1628,
        ).facetsQuery,
        {'managed_only': 'true', 'preferred_area': 'KLCC', 'max_size_sqft': '1628'},
      );
    });
  });
}
