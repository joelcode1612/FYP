// Unit tests for the WF-07 geographic readiness data model.
//
// Directive: PROJECT1-GEO-DEV-C01-WF07-READINESS-CORRECTION-20261030.
//
// These tests cover the completeness and operation-readiness predicates in
// `lib/geo/geo_readiness.dart`. They are pure Dart (no Jaspr imports) so they
// can run with `package:test` without a browser or build daemon.

import 'package:test/test.dart';

import 'package:sitewise_jaspr_web/geo/admin_geography.dart';
import 'package:sitewise_jaspr_web/geo/geo_readiness.dart';
import 'package:sitewise_jaspr_web/geo/geometry_contract.dart';
import 'package:sitewise_jaspr_web/geo/synthetic_rentals.dart';

void main() {
  group('GEOH-T-01: all three synthetic rentals visible and uniquely identified',
      () {
    test('rentals list has exactly three fixtures', () {
      expect(syntheticRentalCentres.length, 3);
    });

    test('rentals have distinct IDs', () {
      final ids = syntheticRentalCentres.map((r) => r.rentalId).toSet();
      expect(ids.length, 3);
    });

    test('rental IDs are SYN-A, SYN-B, SYN-C', () {
      expect(syntheticRentalCentres.map((r) => r.rentalId).toSet(),
          {'SYN-A', 'SYN-B', 'SYN-C'});
    });
  });

  group('GEOH-T-02: position/provenance evaluation', () {
    test('SYN-A is eligible (premises with coordinates)', () {
      final r = syntheticRentalCentres.firstWhere((r) => r.rentalId == 'SYN-A');
      final status = evaluatePosition(r);
      expect(status.code, 'ELIGIBLE_FOR_SPECIFIED_OPERATION');
      expect(status.ready, isTrue);
      expect(status.inputPresent, isTrue);
    });

    test('areaOnly centre is WITHHELD', () {
      final r = RentalCentre(
        rentalId: 'SYN-D',
        label: 'Area Only Test',
        locality: 'TEST',
        kind: CentreClass.areaOnly,
        latitude: 3.14,
        longitude: 101.69,
        accuracyMetres: 1.0,
        positionSource: 'TEST_SOURCE',
        coordinateVersion: 'test-v1',
        synthetic: true,
      );
      final status = evaluatePosition(r);
      expect(status.code, 'WITHHELD');
      expect(status.ready, isFalse);
    });

    test('listingPin centre is WITHHELD', () {
      final r = RentalCentre(
        rentalId: 'SYN-E',
        label: 'Listing Pin Test',
        locality: 'TEST',
        kind: CentreClass.listingPin,
        latitude: 3.14,
        longitude: 101.69,
        accuracyMetres: 1.0,
        positionSource: 'TEST_SOURCE',
        coordinateVersion: 'test-v1',
        synthetic: true,
      );
      final status = evaluatePosition(r);
      expect(status.code, 'WITHHELD');
      expect(status.ready, isFalse);
    });

    test('missing coordinates is WITHHELD', () {
      final r = RentalCentre(
        rentalId: 'SYN-F',
        label: 'No Coords',
        locality: 'TEST',
        kind: CentreClass.premises,
        positionSource: 'TEST_SOURCE',
        accuracyMetres: 1.0,
        coordinateVersion: 'test-v1',
        synthetic: true,
      );
      final status = evaluatePosition(r);
      expect(status.code, 'WITHHELD');
      expect(status.explanation, contains('Coordinates'));
    });

    test('missing positionSource is WITHHELD', () {
      final r = RentalCentre(
        rentalId: 'SYN-G',
        label: 'No Source',
        locality: 'TEST',
        kind: CentreClass.premises,
        latitude: 3.14,
        longitude: 101.69,
        accuracyMetres: 1.0,
        synthetic: true,
      );
      final status = evaluatePosition(r);
      expect(status.code, 'WITHHELD');
    });

    test('invalid latitude is WITHHELD', () {
      final r = RentalCentre(
        rentalId: 'SYN-H',
        label: 'Bad Lat',
        locality: 'TEST',
        kind: CentreClass.premises,
        latitude: 999.0,
        longitude: 101.69,
        accuracyMetres: 1.0,
        positionSource: 'TEST_SOURCE',
        coordinateVersion: 'test-v1',
        synthetic: true,
      );
      final status = evaluatePosition(r);
      expect(status.code, 'WITHHELD');
      expect(status.explanation, contains('Invalid geographic coordinate'));
    });

    test('building centre without entrance offset is WITHHELD', () {
      final r = RentalCentre(
        rentalId: 'SYN-I',
        label: 'Building No Offset',
        locality: 'TEST',
        kind: CentreClass.building,
        latitude: 3.14,
        longitude: 101.69,
        accuracyMetres: 1.0,
        positionSource: 'TEST_SOURCE',
        coordinateVersion: 'test-v1',
        synthetic: true,
      );
      final status = evaluatePosition(r);
      expect(status.code, 'WITHHELD');
      expect(status.explanation, contains('entrance-offset'));
    });

    test('negative accuracyMetres is WITHHELD', () {
      final r = RentalCentre(
        rentalId: 'SYN-J',
        label: 'Negative Accuracy',
        locality: 'TEST',
        kind: CentreClass.premises,
        latitude: 3.14,
        longitude: 101.69,
        accuracyMetres: -1.0,
        positionSource: 'TEST_SOURCE',
        coordinateVersion: 'test-v1',
        synthetic: true,
      );
      final status = evaluatePosition(r);
      expect(status.code, 'WITHHELD');
    });

    test('WITHHELD keeps rental visible (inputPresent=false, ready=false)', () {
      final r = RentalCentre(
        rentalId: 'SYN-K',
        label: 'Withheld Test',
        locality: 'TEST',
        kind: CentreClass.areaOnly,
        latitude: 3.14,
        longitude: 101.69,
        accuracyMetres: 1.0,
        positionSource: 'TEST_SOURCE',
        coordinateVersion: 'test-v1',
        synthetic: true,
      );
      final status = evaluatePosition(r);
      expect(status.inputPresent, isFalse);
      expect(status.ready, isFalse);
      expect(status.remediationAction, isNotNull);
    });
  });

  group('GEOH-T-03: administrative identity classification', () {
    test('stateFt tier is PARTIAL in synthetic fixture', () {
      final area = kSyntheticAdminAreas.firstWhere(
        (a) => a.tier == GeoAdminTier.stateFt,
      );
      expect(area.displayLabel, AdminDisplayLabel.partial);
    });

    test('district tier is NOT_APPLICABLE (FT has no district)', () {
      final area = kSyntheticAdminAreas.firstWhere(
        (a) => a.tier == GeoAdminTier.district,
      );
      expect(area.jurisdictionNotApplicable, isTrue);
      expect(area.displayLabel, AdminDisplayLabel.notApplicable);
    });

    test('mukim tier is NAMED (identity only, no polygon)', () {
      final area = kSyntheticAdminAreas.firstWhere(
        (a) => a.tier == GeoAdminTier.mukim,
      );
      expect(area.displayLabel, AdminDisplayLabel.named);
      expect(area.geometryState, GeometryState.absent);
    });

    test('PARTIAL label does not authorize real polygon rendering', () {
      final area = kSyntheticAdminAreas.firstWhere(
        (a) => a.tier == GeoAdminTier.stateFt,
      );
      final status = evaluatePolygonDisplay(area);
      // Synthetic + watermarked + has polygon → DISPLAY_PERMITTED for synthetic
      // but the explanation must state it is synthetic only.
      expect(status.ready, isTrue);
      expect(status.explanation, contains('Synthetic'));
      expect(status.explanation, contains('is unmet'));
    });

    test('NOT_APPLICABLE is distinct from UNRESOLVED', () {
      final area = kSyntheticAdminAreas.firstWhere(
        (a) => a.tier == GeoAdminTier.district,
      );
      final status = evaluatePolygonDisplay(area);
      expect(status.code, 'WITHHELD');
      expect(status.explanation, contains('no polygon geometry'));
    });

    test('classifyAdminArea is total and disjoint', () {
      // verified
      expect(
        classifyAdminArea(
          jurisdictionNotApplicable: false,
          tierIdentityResolved: true,
          geometryState: GeometryState.validatedLicensed,
        ),
        AdminDisplayLabel.verified,
      );
      // partial
      expect(
        classifyAdminArea(
          jurisdictionNotApplicable: false,
          tierIdentityResolved: true,
          geometryState: GeometryState.unvalidated,
        ),
        AdminDisplayLabel.partial,
      );
      // named
      expect(
        classifyAdminArea(
          jurisdictionNotApplicable: false,
          tierIdentityResolved: true,
          geometryState: GeometryState.absent,
        ),
        AdminDisplayLabel.named,
      );
      // unresolved
      expect(
        classifyAdminArea(
          jurisdictionNotApplicable: false,
          tierIdentityResolved: false,
          geometryState: GeometryState.absent,
        ),
        AdminDisplayLabel.unresolved,
      );
      // notApplicable
      expect(
        classifyAdminArea(
          jurisdictionNotApplicable: true,
          tierIdentityResolved: false,
          geometryState: GeometryState.absent,
        ),
        AdminDisplayLabel.notApplicable,
      );
    });
  });

  group('GEOH-T-04: polygon display evaluation', () {
    test('FT synthetic polygon is DISPLAY_PERMITTED', () {
      final area = kSyntheticAdminAreas.firstWhere(
        (a) => a.tier == GeoAdminTier.stateFt,
      );
      final status = evaluatePolygonDisplay(area);
      expect(status.code, 'DISPLAY_PERMITTED');
      expect(status.ready, isTrue);
    });

    test('mukim with absent geometry is WITHHELD', () {
      final area = kSyntheticAdminAreas.firstWhere(
        (a) => a.tier == GeoAdminTier.mukim,
      );
      final status = evaluatePolygonDisplay(area);
      expect(status.code, 'WITHHELD');
      expect(status.explanation, contains('no polygon geometry'));
    });

    test('district (notApplicable) polygon is WITHHELD', () {
      final area = kSyntheticAdminAreas.firstWhere(
        (a) => a.tier == GeoAdminTier.district,
      );
      final status = evaluatePolygonDisplay(area);
      expect(status.code, 'WITHHELD');
    });

    test('polygonRenderable requires synthetic + watermarked + polygon', () {
      // FT area: synthetic=true, watermarked=true, has polygon
      final ft = kSyntheticAdminAreas.firstWhere(
        (a) => a.tier == GeoAdminTier.stateFt,
      );
      expect(ft.polygonRenderable, isTrue);

      // Mukim: synthetic=true, watermarked=true, no polygon (absent)
      final mk = kSyntheticAdminAreas.firstWhere(
        (a) => a.tier == GeoAdminTier.mukim,
      );
      expect(mk.polygonRenderable, isFalse);
    });
  });

  group('GEOH-T-05: study footprint / radius validation', () {
    test('valid radius returns PREVIEW_ONLY', () {
      final r = syntheticRentalCentres.first;
      final status = evaluateFootprint(r, 800);
      expect(status.code, 'PREVIEW_ONLY');
      expect(status.ready, isTrue);
      expect(status.explanation, contains('NOT ADOPTED'));
    });

    test('null radius is WITHHELD', () {
      final r = syntheticRentalCentres.first;
      final status = evaluateFootprint(r, null);
      expect(status.code, 'WITHHELD');
      expect(status.explanation, contains('No study radius requested'));
    });

    test('radius above 5000m is refused, not clamped', () {
      final r = syntheticRentalCentres.first;
      final status = evaluateFootprint(r, 6000);
      expect(status.code, 'WITHHELD');
      expect(status.explanation, contains('refused'));
      expect(status.explanation, contains('6000'));
    });

    test('zero radius is refused', () {
      final r = syntheticRentalCentres.first;
      final status = evaluateFootprint(r, 0);
      expect(status.code, 'WITHHELD');
    });

    test('negative radius is refused', () {
      final r = syntheticRentalCentres.first;
      final status = evaluateFootprint(r, -100);
      expect(status.code, 'WITHHELD');
    });

    test('radius request requires eligible centre', () {
      final r = RentalCentre(
        rentalId: 'SYN-D',
        label: 'Area Test',
        locality: 'TEST',
        kind: CentreClass.areaOnly,
        latitude: 3.14,
        longitude: 101.69,
        accuracyMetres: 1.0,
        positionSource: 'TEST',
        coordinateVersion: 'v1',
        synthetic: true,
      );
      final status = evaluateFootprint(r, 800);
      expect(status.code, 'WITHHELD');
      expect(status.explanation, contains('eligible centre coordinate'));
    });

    test('validateRadius throws on over-maximum (no clamp)', () {
      expect(() => validateRadius(6000), throwsRangeError);
      expect(() => validateRadius(5001), throwsRangeError);
    });

    test('validateRadius accepts within range', () {
      expect(validateRadius(400), 400);
      expect(validateRadius(5000), 5000);
    });

    test('haversine distance is symmetric and positive', () {
      final d = haversineMetres(3.1432, 101.6892, 3.1502, 101.6988);
      expect(d, greaterThan(0));
      // Symmetry
      final d2 = haversineMetres(3.1502, 101.6988, 3.1432, 101.6892);
      expect((d - d2).abs(), lessThan(0.001));
    });

    test('withinCircle requires positive tolerance', () {
      expect(() => withinCircle(100, 800, toleranceMetres: -1),
          throwsRangeError);
    });
  });

  group('GEOH-T-06: competitor evidence evaluation', () {
    test('null snapshot returns S1 (WITHHELD)', () {
      final status = evaluateCompetitor(null);
      expect(status.code, 'WITHHELD');
      expect(status.explanation, contains('No approved displayable'));
    });

    test('kNoCompetitorSnapshot has no display rights', () {
      expect(kNoCompetitorSnapshot.displayRightsEstablished, isFalse);
      expect(kNoCompetitorSnapshot.sourceAnswered, isFalse);
      expect(kNoCompetitorSnapshot.recordCount, 0);
    });

    test('competitorState(S1) for no snapshot', () {
      expect(competitorState(null), CompetitorState.s1);
      expect(competitorState(kNoCompetitorSnapshot), CompetitorState.s1);
    });

    test('S4 snapshot returns WITHHELD with unknown coverage message', () {
      final snap = VenueSnapshot(
        snapshotId: 'TEST-S4',
        source: 'test-source',
        sourceRelease: 'v1',
        coverage: CoverageClass.unknown,
        sourceAnswered: true,
        queryFailed: false,
        displayRightsEstablished: true,
        areaResolved: true,
        hasWrittenCompletenessStatement: false,
        recordCount: 0,
      );
      final state = competitorState(snap);
      expect(state, CompetitorState.s4);
      final status = evaluateCompetitor(snap);
      expect(status.code, 'WITHHELD');
      expect(status.explanation, contains('unknown'));
    });

    test('S7 snapshot returns AVAILABLE with record count', () {
      final snap = VenueSnapshot(
        snapshotId: 'TEST-S7',
        source: 'test-source',
        sourceRelease: 'v1',
        coverage: CoverageClass.complete,
        sourceAnswered: true,
        queryFailed: false,
        displayRightsEstablished: true,
        areaResolved: true,
        hasWrittenCompletenessStatement: true,
        recordCount: 15,
      );
      final state = competitorState(snap);
      expect(state, CompetitorState.s7);
      final status = evaluateCompetitor(snap);
      expect(status.code, 'SOURCE_OBSERVATIONS_AVAILABLE');
      expect(status.ready, isTrue);
    });

    test('unknown coverage distinct from complete coverage', () {
      final unknown = VenueSnapshot(
        snapshotId: 'U',
        source: 's',
        sourceRelease: 'v1',
        coverage: CoverageClass.unknown,
        sourceAnswered: true,
        queryFailed: false,
        displayRightsEstablished: true,
        areaResolved: true,
        hasWrittenCompletenessStatement: false,
        recordCount: 0,
      );
      final complete = VenueSnapshot(
        snapshotId: 'C',
        source: 's',
        sourceRelease: 'v1',
        coverage: CoverageClass.complete,
        sourceAnswered: true,
        queryFailed: false,
        displayRightsEstablished: true,
        areaResolved: true,
        hasWrittenCompletenessStatement: true,
        recordCount: 0,
      );
      expect(competitorState(unknown), CompetitorState.s4);
      expect(competitorState(complete), CompetitorState.s6);
    });

    test('partial coverage distinct from complete coverage', () {
      final partial = VenueSnapshot(
        snapshotId: 'P',
        source: 's',
        sourceRelease: 'v1',
        coverage: CoverageClass.partial,
        sourceAnswered: true,
        queryFailed: false,
        displayRightsEstablished: true,
        areaResolved: true,
        hasWrittenCompletenessStatement: false,
        recordCount: 0,
      );
      final complete = VenueSnapshot(
        snapshotId: 'C',
        source: 's',
        sourceRelease: 'v1',
        coverage: CoverageClass.complete,
        sourceAnswered: true,
        queryFailed: false,
        displayRightsEstablished: true,
        areaResolved: true,
        hasWrittenCompletenessStatement: true,
        recordCount: 0,
      );
      expect(competitorState(partial), CompetitorState.s5);
      expect(competitorState(complete), CompetitorState.s6);
    });
  });

  group('GEOH-T-07: cross-rental comparison', () {
    test('comparison is WITHHELD when competitor is S1', () {
      final a = computeRentalReadiness(
        syntheticRentalCentres[0],
        requestedRadius: 800,
      );
      final b = computeRentalReadiness(
        syntheticRentalCentres[1],
        requestedRadius: 800,
      );
      final status = evaluateComparison(a, b);
      expect(status.code, 'WITHHELD');
      expect(status.explanation, contains('approved source'));
    });

    test('mayDisplayCrossCandidateCounts requires all conditions', () {
      expect(
        mayDisplayCrossCandidateCounts(
          sameMethodAndRadius: true,
          sameVersionedSource: true,
          sameObservationWindow: true,
          bothDisplayable: true,
          bothHaveDocumentedCompleteness: true,
        ),
        isTrue,
      );
      // One missing → false
      expect(
        mayDisplayCrossCandidateCounts(
          sameMethodAndRadius: false,
          sameVersionedSource: true,
          sameObservationWindow: true,
          bothDisplayable: true,
          bothHaveDocumentedCompleteness: true,
        ),
        isFalse,
      );
    });
  });

  group('GEOH-T-08: operation readiness matrix', () {
    test('matrix has all six operations', () {
      final r = computeRentalReadiness(
        syntheticRentalCentres[0],
        requestedRadius: 800,
      );
      final ops = computeOperationMatrix(r);
      expect(ops.length, 6);
      expect(ops.map((o) => o.op).toSet(), GeoOperation.values.toSet());
    });

    test('MAP_PREVIEW is PREVIEW_ONLY for eligible rental', () {
      final r = computeRentalReadiness(
        syntheticRentalCentres[0],
        requestedRadius: 800,
      );
      final ops = computeOperationMatrix(r);
      final mapOp = ops.firstWhere((o) => o.op == GeoOperation.mapPreview);
      expect(mapOp.status, OperationStatus.previewOnly);
    });

    test('ADMIN_AREA_LABEL is PREVIEW_ONLY', () {
      final r = computeRentalReadiness(
        syntheticRentalCentres[0],
        requestedRadius: 800,
      );
      final ops = computeOperationMatrix(r);
      final labelOp =
          ops.firstWhere((o) => o.op == GeoOperation.adminAreaLabel);
      expect(labelOp.status, OperationStatus.previewOnly);
    });

    test('ADMIN_POLYGON_DISPLAY is PREVIEW_ONLY (synthetic)', () {
      final r = computeRentalReadiness(
        syntheticRentalCentres[0],
        requestedRadius: 800,
      );
      final ops = computeOperationMatrix(r);
      final polyOp =
          ops.firstWhere((o) => o.op == GeoOperation.adminPolygonDisplay);
      expect(polyOp.status, OperationStatus.previewOnly);
    });

    test('COMPETITOR_LIST is WITHHELD (S1)', () {
      final r = computeRentalReadiness(
        syntheticRentalCentres[0],
        requestedRadius: 800,
      );
      final ops = computeOperationMatrix(r);
      final compOp =
          ops.firstWhere((o) => o.op == GeoOperation.competitorList);
      expect(compOp.status, OperationStatus.withheld);
    });

    test('CROSS_RENTAL_COUNT is WITHHELD (UNADOPTED_POLICY)', () {
      final r = computeRentalReadiness(
        syntheticRentalCentres[0],
        requestedRadius: 800,
      );
      final ops = computeOperationMatrix(r);
      final crossOp =
          ops.firstWhere((o) => o.op == GeoOperation.crossRentalCount);
      expect(crossOp.status, OperationStatus.withheld);
      expect(crossOp.reason, contains('UNADOPTED_POLICY'));
    });
  });

  group('GEOH-T-09: engineering readiness levels', () {
    test('L0 is PROPOSED and achieved', () {
      final l0 = kEngineeringReadiness.firstWhere((e) => e.level == EngineeringLevel.l0);
      expect(l0.achieved, isTrue);
      expect(l0.status, 'PROPOSED');
    });

    test('L1 is PARTIAL', () {
      final l1 = kEngineeringReadiness.firstWhere((e) => e.level == EngineeringLevel.l1);
      expect(l1.achieved, isTrue);
      expect(l1.status, 'PARTIAL');
    });

    test('L2 is WITHHELD (not achieved)', () {
      final l2 = kEngineeringReadiness.firstWhere((e) => e.level == EngineeringLevel.l2);
      expect(l2.achieved, isFalse);
      expect(l2.status, 'WITHHELD');
      expect(l2.explanation, contains('teammate'));
    });

    test('L3 is WITHHELD (not achieved)', () {
      final l3 = kEngineeringReadiness.firstWhere((e) => e.level == EngineeringLevel.l3);
      expect(l3.achieved, isFalse);
      expect(l3.status, 'WITHHELD');
      expect(l3.explanation, contains('NO_COMPETITOR_SNAPSHOT'));
    });
  });

  group('GEOH-T-10: computeAllRentalReadiness consistency', () {
    test('returns readiness for all three rentals', () {
      final all = computeAllRentalReadiness();
      expect(all.length, 3);
      expect(all.map((r) => r.rental.rentalId).toSet(),
          {'SYN-A', 'SYN-B', 'SYN-C'});
    });

    test('all three rentals are position-eligible', () {
      final all = computeAllRentalReadiness();
      for (final r in all) {
        expect(r.position.ready, isTrue);
        expect(r.position.code, 'ELIGIBLE_FOR_SPECIFIED_OPERATION');
      }
    });

    test('all competitors are S1 (no source)', () {
      final all = computeAllRentalReadiness();
      for (final r in all) {
        expect(r.competitor.code, 'WITHHELD');
        expect(r.competitor.explanation, contains('No approved'));
      }
    });
  });
}
