import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/components/property_detail/district_demographics_panel.dart';
import 'package:sitewise_jaspr_web/data/location_evidence_api.dart';

/// The district panel must show DOSM's real district figures, keep each block's
/// own reference year, and never turn a missing dataset into a number.
///
/// The payloads below are the values the backend returns for the listings named
/// in backend/tests/test_district_demographics.py: W.P. Kuala Lumpur, which
/// DOSM publishes under the same label as both state and district, and W.P.
/// Putrajaya, which has household income but no district population or age
/// bands.
const _klGroups = [
  DistrictAgeGroup(key: '0-14', label: '0–14 years', persons: 345200, share: 0.1658),
  DistrictAgeGroup(key: '15-24', label: '15–24 years', persons: 288500, share: 0.1385),
  DistrictAgeGroup(key: '25-34', label: '25–34 years', persons: 336700, share: 0.1617),
  DistrictAgeGroup(key: '35-49', label: '35–49 years', persons: 670800, share: 0.3221),
  DistrictAgeGroup(key: '50-64', label: '50–64 years', persons: 286700, share: 0.1377),
  DistrictAgeGroup(key: '65+', label: '65+ years', persons: 154600, share: 0.0742),
];

const _kl = DistrictStatistics(
  available: true,
  totalPopulation: 2082500,
  ageGroups: _klGroups,
  district: 'W.P. Kuala Lumpur',
  state: 'W.P. Kuala Lumpur',
  ageYear: '2026',
  malePopulation: 1123500,
  femalePopulation: 958800,
  districtPopulation: 2082300,
  populationAsOf: '2026-01-01',
  incomeMedianMyr: 10234.0,
  incomeAsOf: '2022-01-01',
);

const _incomeOnly = DistrictStatistics(
  available: true,
  totalPopulation: 0,
  ageGroups: [],
  district: 'W.P. Putrajaya',
  state: 'W.P. Putrajaya',
  ageNote: 'No DOSM district age bands are published for W.P. Putrajaya.',
  populationNote:
      'No DOSM district population estimate is published for W.P. Putrajaya.',
  incomeMedianMyr: 10056.0,
  incomeAsOf: '2022-01-01',
);

const _unresolved = DistrictStatistics(
  available: false,
  totalPopulation: 0,
  ageGroups: [],
  reason: 'This property has no matched administrative district.',
);

const _residents500m = EvidenceMetric(
  key: 'pop_500m',
  label: 'Estimated residents within 500 m',
  unit: 'persons',
  // WorldPop publishes a fractional raster sum; people are never shown in
  // decimals.
  value: 10111.4,
  status: 'available',
);

const _residents1km = EvidenceMetric(
  key: 'pop_1000m',
  label: 'Estimated residents within 1 km',
  unit: 'persons',
  value: 24680,
  status: 'available',
);

void main() {
  test('a district with no published bands stays missing, never zero', () {
    final group = DistrictAgeGroup.fromJson(const {
      'key': '65+',
      'label': '65+ years',
      'persons': null,
      'share': null,
    });
    expect(group.persons, isNull);
  });

  testComponents('kuala lumpur district figures render with their own years', (
    tester,
  ) async {
    tester.pumpComponent(
      const DistrictDemographicsPanel(
        statistics: _kl,
        residents500m: _residents500m,
        residents1km: _residents1km,
      ),
    );

    // The federal territory is one place, not a doubled label.
    expect(find.text('W.P. Kuala Lumpur'), findsOneComponent);

    // District-wide DOSM population, whole people, with its own year.
    expect(find.text('2,082,300 people'), findsOneComponent);
    expect(
      find.text('DOSM district-wide population · 2026'),
      findsOneComponent,
    );

    // The sex split travels with the population dataset (2026) — the same
    // record the total came from, not the age bands or the income survey.
    expect(
      find.text(
        'District population by sex: 1,123,500 male · 958,800 female (DOSM 2026).',
      ),
      findsOneComponent,
    );

    // Household income keeps its HIES year.
    expect(
      find.text(
        'Typical monthly household income in this district: '
        'RM 10,234/month (2022)',
      ),
      findsOneComponent,
    );

    // Six age bars with accessible values; no decimals on people.
    expect(find.text('0–14 years'), findsOneComponent);
    expect(find.text('65+ years'), findsOneComponent);
    expect(find.text('32.2%'), findsOneComponent);
    expect(find.text('670,800 people'), findsOneComponent);

    // The catchment estimates stay labelled as estimates.
    expect(find.text('10,111 estimated residents'), findsOneComponent);
    expect(find.text('24,680 estimated residents'), findsOneComponent);
    expect(find.text('District data not available'), findsNothing);
  });

  testComponents('an unpublished block reads unavailable, not zero', (
    tester,
  ) async {
    tester.pumpComponent(
      const DistrictDemographicsPanel(
        statistics: _incomeOnly,
        residents500m: _residents500m,
        residents1km: _residents1km,
      ),
    );

    expect(find.text('No age data'), findsOneComponent);
    expect(
      find.text('No DOSM district age bands are published for W.P. Putrajaya.'),
      findsOneComponent,
    );
    expect(find.text('W.P. Putrajaya'), findsOneComponent);
    // The district population genuinely is not published for this district
    // (and only that card reads unavailable - the catchment estimates stand).
    expect(find.text('Not available'), findsOneComponent);
    // The income DOSM does publish is still shown, with its own year.
    expect(
      find.text(
        'Typical monthly household income in this district: '
        'RM 10,056/month (2022)',
      ),
      findsOneComponent,
    );
    expect(find.text('0 people'), findsNothing);
    expect(find.text('DOSM district-wide population · 2026'), findsNothing);
  });

  testComponents('a property with no matched district shows the reason', (
    tester,
  ) async {
    tester.pumpComponent(
      const DistrictDemographicsPanel(statistics: _unresolved),
    );

    expect(find.text('District data not available'), findsOneComponent);
    expect(
      find.text('This property has no matched administrative district.'),
      findsOneComponent,
    );
    expect(
      find.text('Typical monthly household income in this district: Not available'),
      findsOneComponent,
    );
    // Nothing is borrowed from another district.
    expect(find.text('2,082,300 people'), findsNothing);
  });
}
