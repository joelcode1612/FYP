import 'package:shared_logic/src/domain/entities/property_compare.dart';
import 'package:test/test.dart';

/// The compare result carries per-id unresolved reasons so both clients can
/// explain WHY a selected property was left out instead of a generic
/// "not found". Older responses without `unresolved_details` must still parse.
void main() {
  group('PropertyCompareResult unresolved details', () {
    test('parses per-id reasons and exposes them by id', () {
      final result = PropertyCompareResult.fromJson({
        'selected_count': 2,
        'resolved_count': 1,
        'unresolved_ids': ['ZZ-404'],
        'unresolved_details': [
          {
            'id': 'ZZ-404',
            'reason': 'No published, administrator-approved commercial '
                'listing exists with this id.',
          },
        ],
        'properties': [
          {
            'property_id': 'MD-00510',
            'title': 'Resolved',
            'metrics': <String, dynamic>{},
          },
        ],
      });

      expect(result.unresolvedIds, ['ZZ-404']);
      expect(result.reasonFor('ZZ-404'), contains('administrator-approved'));
      expect(result.reasonFor('MD-00510'), isNull);
    });

    test('an older response without details falls back to a generic reason',
        () {
      final result = PropertyCompareResult.fromJson({
        'selected_count': 2,
        'resolved_count': 1,
        'unresolved_ids': ['EP-00000'],
        'properties': const [],
      });

      expect(result.unresolvedDetails, isEmpty);
      expect(result.reasonFor('EP-00000'), isNull);
    });
  });

  group('CompareProperty metrics', () {
    test('radius provenance drives the caption, so 1 km is never shown as '
        '500 m', () {
      final property = CompareProperty.fromJson({
        'property_id': 'MD-00001',
        'title': 'One',
        'metrics': {
          'universities_count_500m': {
            'value': 7,
            'available': true,
            'label': 'Nearby universities / colleges',
            'unit': 'institutions',
            'radius_m': 1000,
            'group': 'location',
            'source': 'mapped education POIs',
            'display': '7 institutions',
          },
        },
      });

      expect(property.metric('universities_count_500m').caption,
          contains('1000 m'));
      expect(property.metric('universities_count_500m').caption,
          isNot(contains('500 m')));
    });

    test('a missing metric reads as unavailable, never zero', () {
      final property = CompareProperty.fromJson({
        'property_id': 'MD-00001',
        'title': 'One',
        'metrics': const {},
      });
      final metric = property.metric('fnb_competitors_500m');
      expect(metric.available, isFalse);
      expect(metric.value, isNull);
      expect(metric.display, 'Data not available');
    });
  });

  group('Preference fit rows', () {
    test('parses each row plus the basis it was measured against', () {
      final result = PropertyCompareResult.fromJson({
        'selected_count': 2,
        'resolved_count': 2,
        'properties': [
          {
            'property_id': 'MD-00001',
            'title': 'One',
            'metrics': const {},
            'preference_fit': [
              {
                'key': 'budget',
                'label': 'Monthly rent',
                'status': 'meets',
                'detail': 'RM 4,000 per month is within your saved budget.',
              },
              {
                'key': 'parking',
                'label': 'Parking',
                'status': 'not_recorded',
                'detail': 'No on-site parking value is recorded.',
              },
            ],
          },
          {
            'property_id': 'MD-00002',
            'title': 'Two',
            'metrics': const {},
          },
        ],
        'preference_fit_basis': {
          'saved': true,
          'statement': 'These are facts, not scores.',
          'not_compared': ['Accessibility is not recorded for any property.'],
        },
      });

      expect(result.fitBasis.saved, isTrue);
      expect(result.fitBasis.notCompared, hasLength(1));
      final rows = result.properties.first.preferenceFit;
      expect(rows.map((row) => row.status), ['meets', 'not_recorded']);
      expect(rows.first.checked, isTrue);
      expect(rows.first.satisfied, isTrue);
      expect(rows.first.statusLabel, 'Within your requirement');
      // A status the client must show as missing data, not as a fail.
      expect(rows.last.checked, isFalse);
      expect(rows.last.satisfied, isFalse);
      expect(rows.last.statusLabel, 'Not recorded for this property');
      // An unknown status still renders, as plainly unavailable.
      expect(
        const CompareFitRow(
          key: 'x',
          label: 'X',
          status: 'future_status',
          detail: 'd',
        ).statusLabel,
        'Not available',
      );
      // A property the backend gave no rows for never breaks the layout.
      expect(result.properties.last.preferenceFit, isEmpty);
    });

    test('a response without fit data reads as not available', () {
      final result = PropertyCompareResult.fromJson({
        'selected_count': 2,
        'resolved_count': 1,
        'properties': const [],
      });

      expect(result.fitBasis.saved, isFalse);
      expect(result.fitBasis.statement, contains('not available'));
      expect(result.fitBasis.notCompared, isEmpty);
    });
  });
}
