import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/data/metric_format.dart';

void main() {
  group('metricGrouped', () {
    test('groups thousands and rounds to the requested decimals', () {
      expect(metricGrouped(15090.90), '15,091');
      expect(metricGrouped(15090.90, decimals: 1), '15,090.9');
      expect(metricGrouped(1000), '1,000');
      expect(metricGrouped(0), '0');
      expect(metricGrouped(-12500), '-12,500');
    });

    test('trims a pure-zero fraction', () {
      expect(metricGrouped(1000, decimals: 1), '1,000');
      expect(metricGrouped(1530.4, decimals: 1), '1,530.4');
    });
  });

  group('fmtResidents', () {
    test('formats a fractional estimate as whole people with separators', () {
      expect(fmtResidents(15090.90), '15,091 residents');
      expect(fmtResidents(999999.49), '999,999 residents');
      expect(fmtResidents(1), '1 resident');
    });

    test('a recorded zero is a real answer, not a missing value', () {
      expect(fmtResidents(0), '0 residents');
    });

    test('missing, NaN, infinite and negative inputs render nothing', () {
      expect(fmtResidents(null), isNull);
      expect(fmtResidents(double.nan), isNull);
      expect(fmtResidents(double.infinity), isNull);
      expect(fmtResidents(-3), isNull);
    });
  });

  group('fmtDistance', () {
    test('metres below ~1 km, whole numbers only', () {
      expect(fmtDistance(35.9), '36 m away');
      expect(fmtDistance(0), '0 m away');
      expect(fmtDistance(994.4), '994 m away');
    });

    test('kilometres at and above ~1 km, one decimal when needed', () {
      expect(fmtDistance(995), '1 km away');
      expect(fmtDistance(999.6), '1 km away');
      expect(fmtDistance(1000), '1 km away');
      expect(fmtDistance(1300), '1.3 km away');
      expect(fmtDistance(12345), '12.3 km away');
    });

    test('missing, NaN, infinite and negative inputs render nothing', () {
      expect(fmtDistance(null), isNull);
      expect(fmtDistance(double.nan), isNull);
      expect(fmtDistance(double.infinity), isNull);
      expect(fmtDistance(-12), isNull);
    });
  });

  group('fmtCount', () {
    test('renders the noun with the right plurality', () {
      expect(
        fmtCount(7, singular: 'business', plural: 'businesses'),
        '7 businesses',
      );
      expect(
        fmtCount(1, singular: 'business', plural: 'businesses'),
        '1 business',
      );
      expect(fmtCount(23, singular: 'shop', plural: 'shops'), '23 shops');
      expect(
        fmtCount(26, singular: 'facility', plural: 'facilities'),
        '26 facilities',
      );
      expect(
        fmtCount(1, singular: 'facility', plural: 'facilities'),
        '1 facility',
      );
    });

    test('groups large counts', () {
      expect(
        fmtCount(1234, singular: 'shop', plural: 'shops'),
        '1,234 shops',
      );
    });

    test('a recorded zero stays visible; missing renders nothing', () {
      expect(fmtCount(0, singular: 'shop', plural: 'shops'), '0 shops');
      expect(fmtCount(null, singular: 'shop', plural: 'shops'), isNull);
    });
  });

  group('fmtMonthlyRental', () {
    test('formats a single monthly rental with separators', () {
      expect(fmtMonthlyRental(3700), 'RM 3,700/month');
      expect(fmtMonthlyRental(3700.49), 'RM 3,700/month');
      expect(fmtMonthlyRental(15200), 'RM 15,200/month');
      expect(fmtMonthlyRental(850), 'RM 850/month');
    });

    test('formats a rental range on one /month', () {
      expect(
        fmtMonthlyRental(3700, rentalMaxRm: 4200),
        'RM 3,700–RM 4,200/month',
      );
    });

    test('max equal to the rental is a single value, not a range', () {
      expect(fmtMonthlyRental(3700, rentalMaxRm: 3700), 'RM 3,700/month');
    });

    test('the zero sentinel and missing values render nothing', () {
      expect(fmtMonthlyRental(0), isNull);
      expect(fmtMonthlyRental(null), isNull);
      expect(fmtMonthlyRental(double.nan), isNull);
      expect(fmtMonthlyRental(-500), isNull);
    });
  });

  group('fmtEvidenceValue', () {
    test('population units render whole people with separators', () {
      expect(fmtEvidenceValue(31366.4, 'people'), '31,366 people');
      expect(fmtEvidenceValue(1191200, 'persons'), '1,191,200 people');
    });

    test('DOSM income renders as ringgit per month', () {
      expect(fmtEvidenceValue(8837, 'RM/month'), 'RM 8,837/month');
    });

    test('distances reuse the metre/kilometre rules', () {
      expect(fmtEvidenceValue(66.9, 'm'), '67 m away');
      expect(fmtEvidenceValue(1062.7, 'm'), '1.1 km away');
    });

    test('counts and departures are grouped integers, no bare unit', () {
      expect(fmtEvidenceValue(47, 'count'), '47');
      expect(fmtEvidenceValue(12, 'departures'), '12');
      expect(fmtEvidenceValue(3.0, ''), '3');
    });

    test('the stored footprint ratio is already a percentage of the area', () {
      expect(fmtEvidenceValue(35.3911, 'ratio'), '35.4% of the area');
      expect(fmtEvidenceValue(0, 'ratio'), '0% of the area');
    });

    test('isochrone areas and road density keep their recorded units', () {
      expect(fmtEvidenceValue(0.1578, 'km²'), '0.16 km²');
      expect(fmtEvidenceValue(213.6033, 'km²'), '213.6 km²');
      expect(fmtEvidenceValue(40.119, 'km/km²'), '40.1 km/km²');
    });

    test('unknown units stay truthful with two decimals', () {
      expect(fmtEvidenceValue(1.23456, 'widgets'), '1.23 widgets');
    });

    test('missing, NaN and negative values render nothing', () {
      expect(fmtEvidenceValue(null, 'count'), isNull);
      expect(fmtEvidenceValue(double.nan, 'people'), isNull);
      expect(fmtEvidenceValue(-1, 'm'), isNull);
    });
  });
}
