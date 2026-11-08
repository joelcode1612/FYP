import 'package:test/test.dart';
import 'package:project1_geo_report_demo/geometry_contract.dart';
import 'package:project1_geo_report_demo/synthetic_rentals.dart';

void main() {
  test('three different synthetic fixture coordinates are available to Jaspr', () {
    expect(syntheticRentalCentres.length, 3);
    expect(syntheticRentalCentres.map((r) => r.rentalId).toSet().length, 3);
    for (final r in syntheticRentalCentres) {
      expect(r.synthetic, isTrue);
      expect(r.positionSource, 'SYNTHETIC_FIXTURE_NOT_MEASURED');
      expect(classifyCentre(r).canDraw, isTrue);
    }
    for (var i = 0; i < syntheticRentalCentres.length; i++) {
      for (var j = i + 1; j < syntheticRentalCentres.length; j++) {
        final a = syntheticRentalCentres[i], b = syntheticRentalCentres[j];
        expect(haversineMetres(a.latitude!, a.longitude!, b.latitude!, b.longitude!), greaterThan(0));
      }
    }
  });
  test('D-1 requests above five kilometres are refused rather than clamped', () {
    expect(() => validateRadius(6000), throwsRangeError);
    expect(validateRadius(800), 800);
  });
  test('F-2 explicit tolerance controls the exact boundary', () {
    expect(withinCircle(800.0000000000036, 800, toleranceMetres: 0), isFalse);
    expect(withinCircle(800.0000000000036, 800, toleranceMetres: 0.5), isTrue);
    expect(withinCircle(805, 800, toleranceMetres: 0.5), isFalse);
  });
  test('area-only and unverified listing pin do not yield a precise circle', () {
    const area = RentalCentre(rentalId: 'A',label:'A',locality:'Area',kind: CentreClass.areaOnly);
    const pin = RentalCentre(rentalId: 'B',label:'B',locality:'Area',kind: CentreClass.listingPin,latitude:3,longitude:101,accuracyMetres:3,positionSource:'listing');
    expect(classifyCentre(area).canDraw, isFalse);
    expect(classifyCentre(pin).canDraw, isFalse);
  });
  test('unknown coverage does not become zero assertion', () {
    const s = VenueSnapshot(snapshotId:'demo',source:'SYN',sourceRelease:'v',coverage:CoverageClass.unknown,
      sourceAnswered:true,queryFailed:false,displayRightsEstablished:true,areaResolved:true,hasWrittenCompletenessStatement:false,recordCount:0);
    expect(competitorState(s), CompetitorState.s4);
    expect(absenceBody(CompetitorState.s4).contains('0'), isFalse);
  });
  test('complete coverage without attestation falls back to unknown', () {
    const s = VenueSnapshot(snapshotId:'demo',source:'SYN',sourceRelease:'v',coverage:CoverageClass.complete,
      sourceAnswered:true,queryFailed:false,displayRightsEstablished:true,areaResolved:true,hasWrittenCompletenessStatement:false,recordCount:0);
    expect(competitorState(s), CompetitorState.s4);
  });
  test('unlicensed source is never displayed', () {
    const s = VenueSnapshot(snapshotId:'demo',source:'SYN',sourceRelease:'v',coverage:CoverageClass.unknown,
      sourceAnswered:true,queryFailed:false,displayRightsEstablished:false,areaResolved:true,hasWrittenCompletenessStatement:false,recordCount:5);
    expect(competitorState(s), CompetitorState.s1);
  });
  test('even equal radii cannot compare incomplete sources', () {
    expect(mayDisplayCrossCandidateCounts(sameMethodAndRadius:true,sameVersionedSource:true,
      sameObservationWindow:true,bothDisplayable:true,bothHaveDocumentedCompleteness:false),isFalse);
  });
}
