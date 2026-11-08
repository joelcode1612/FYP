/// PROJECT1 — L2a administrative boundary overlay oracles.
///
/// Directive: `PROJECT1-L2-OPEN-DATA-FOUR-AREA-ACCEPTANCE-20261031`.
///
/// These tests pin the claims the overlay makes in the browser:
///  * all four supported jurisdictions are mapped, 25 districts in total;
///  * only ADM1/ADM2 is exposed and the lower tier is withheld;
///  * the payload carries the same dataset hashes the L2 harness measured;
///  * the layer can never be read as a calculation footprint;
///  * an unsupported region shows as unavailable, never as an empty area.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:sitewise_jaspr_web/geo/admin_boundary_layer.dart';

void main() {
  group('jurisdiction register', () {
    test('the four supported regions are mapped exactly once', () {
      final ids = kAdminJurisdictions.map((j) => j.regionFixtureId).toList();
      expect(ids.toSet().length, 4);
      expect(ids.toSet(), {'KL', 'PEN', 'JHR', 'SGR'});
    });

    test('the four regions resolve to 25 DOSM districts', () {
      expect(kAdminDistrictTotal, 25);
      expect(adminJurisdictionForRegion('JHR')!.districtCount, 10);
      expect(adminJurisdictionForRegion('PEN')!.districtCount, 5);
      expect(adminJurisdictionForRegion('SGR')!.districtCount, 9);
      expect(adminJurisdictionForRegion('KL')!.districtCount, 1);
    });

    test('DOSM spellings are used, not the navigation labels', () {
      expect(adminJurisdictionForRegion('KL')!.dosmStateName,
          'W.P. Kuala Lumpur');
      expect(adminJurisdictionForRegion('PEN')!.dosmStateName, 'Pulau Pinang');
      expect(adminJurisdictionForRegion('KL')!.codeState, '14');
      expect(adminJurisdictionForRegion('PEN')!.codeState, '7');
      expect(adminJurisdictionForRegion('JHR')!.codeState, '1');
      expect(adminJurisdictionForRegion('SGR')!.codeState, '10');
    });

    test('district codes are unique within a jurisdiction', () {
      for (final j in kAdminJurisdictions) {
        final codes = j.districtCodes.values.toList();
        expect(codes.toSet().length, codes.length,
            reason: '${j.dosmStateName} has a duplicated district code');
      }
    });

    test('measured source-invalid districts are the ones disclosed', () {
      final jhr = adminJurisdictionForRegion('JHR')!;
      final pen = adminJurisdictionForRegion('PEN')!;
      final sgr = adminJurisdictionForRegion('SGR')!;
      final kl = adminJurisdictionForRegion('KL')!;
      expect(jhr.sourceInvalidDistricts, ['Kluang', 'Tangkak']);
      expect(pen.sourceInvalidDistricts, ['Timur Laut']);
      expect(sgr.sourceInvalidDistricts, isEmpty);
      expect(kl.sourceInvalidDistricts, isEmpty);
    });
  });

  group('payload contract', () {
    test('every supported region yields an available L2a payload', () {
      for (final j in kAdminJurisdictions) {
        final p = adminBoundaryPayload(
            regionFixtureId: j.regionFixtureId, visible: true);
        expect(p['status'], kAdminLayerStatusAvailable);
        expect(p['visible'], isTrue);
        expect(p['tier'], 'ADM1+ADM2');
        final jur = p['jurisdiction'] as Map<String, dynamic>;
        expect(jur['dosmState'], j.dosmStateName);
        expect(jur['districtCount'], j.districtCount);
        expect((jur['districts'] as List).length, j.districtCount);
      }
    });

    test('the payload pins the exact dataset bytes the harness measured', () {
      final p = adminBoundaryPayload(regionFixtureId: 'SGR', visible: true);
      final source = p['source'] as Map<String, dynamic>;
      final adm1 = source['adm1'] as Map<String, dynamic>;
      final adm2 = source['adm2'] as Map<String, dynamic>;
      expect(adm1['url'], kAdminDatasetAdm1);
      expect(adm1['sha256'], kAdminDatasetAdm1Sha256);
      expect(adm1['bytes'], kAdminDatasetAdm1Bytes);
      expect(adm2['url'], kAdminDatasetAdm2);
      expect(adm2['sha256'], kAdminDatasetAdm2Sha256);
      expect(adm2['bytes'], kAdminDatasetAdm2Bytes);
    });

    test('the datasets served by the app are the pinned sources', () {
      for (final entry in {
        'web/data/administrative_1_state.geojson': kAdminDatasetAdm1Bytes,
        'web/data/administrative_2_district.geojson': kAdminDatasetAdm2Bytes,
      }.entries) {
        final f = File(entry.key);
        expect(f.existsSync(), isTrue, reason: '${entry.key} is missing');
        expect(f.lengthSync(), entry.value,
            reason: '${entry.key} is not the pinned byte length');
      }
    });

    test('the lower tier is withheld with a rights reason, not omitted', () {
      final p = adminBoundaryPayload(regionFixtureId: 'JHR', visible: true);
      final lower = p['lowerTier'] as Map<String, dynamic>;
      expect(lower['status'], kAdminLayerStatusWithheld);
      expect(lower['features'], 1859);
      expect(lower['releasable'], 0);
      expect(lower['crossStateStraddles'], 245);
      expect(lower['unassignedToDosmDistrict'], 8);
      expect(lower['reason'], contains('unverified licence chain'));
      expect(lower['reason'], contains('shapeISO'));
      expect(lower['reason'], contains('two or more states'));
    });

    test('the licence permits reuse without an application', () {
      final p = adminBoundaryPayload(regionFixtureId: 'KL', visible: true);
      final lic = p['licence'] as Map<String, dynamic>;
      expect(lic['name'], 'DOSM Open Data Licence');
      expect(lic['permitsReuseWithoutApplication'], isTrue);
      expect(lic['summary'], contains('without an individual permission request'));
      expect(lic['summary'], contains('commercial'));
    });

    test('source geometry defects are disclosed, not repaired', () {
      final p = adminBoundaryPayload(regionFixtureId: 'JHR', visible: true);
      final notes = p['geometryNotes'] as Map<String, dynamic>;
      expect(notes['sourceInvalidCount'], 3);
      expect(notes['overlapPairsTouchingFour'], 51);
      expect(notes['overlapPairsWithinFour'], 28);
      expect(notes['overlapPairsCrossBorder'], 23);
      expect(notes['materialOverlapThresholdM2'], 1000);
      expect(notes['displayedUnmodified'], isTrue);
    });

    test('visibility follows the viewer without changing the identity', () {
      final on = adminBoundaryPayload(regionFixtureId: 'SGR', visible: true);
      final off = adminBoundaryPayload(regionFixtureId: 'SGR', visible: false);
      expect(on['visible'], isTrue);
      expect(off['visible'], isFalse);
      expect((off['jurisdiction'] as Map)['districtCount'],
          (on['jurisdiction'] as Map)['districtCount']);
    });

    test('an unsupported region is unavailable, never an empty layer', () {
      final p = adminBoundaryPayload(regionFixtureId: 'XYZ', visible: true);
      expect(p['status'], kAdminLayerStatusUnavailable);
      expect(p['visible'], isFalse);
      expect(p['reason'], contains('UNSUPPORTED_REGION'));
      expect(p['reason'], contains('no empty area'));
      expect(p.containsKey('jurisdiction'), isFalse);
    });
  });

  group('separation from every calculation footprint', () {
    test('the separation statement names all three non-equivalences', () {
      expect(kAdminSeparationStatement, contains('not the system study zone'));
      expect(kAdminSeparationStatement, contains('not the display radius'));
      expect(kAdminSeparationStatement, contains('not a competitor footprint'));
      expect(kAdminSeparationStatement, contains('never change'));
    });

    test('the admin payload carries no membership or count field', () {
      for (final j in kAdminJurisdictions) {
        final p = adminBoundaryPayload(
            regionFixtureId: j.regionFixtureId, visible: true);
        final encoded = jsonEncode(p);
        for (final forbidden in [
          'insideRecordIds',
          'rawObservationCount',
          'distinctObservationCount',
          'undecidedCount',
          'promotableToReal',
          'membership',
        ]) {
          expect(encoded.contains(forbidden), isFalse,
              reason: 'admin payload leaked "$forbidden"');
        }
      }
    });

    test('the separation string is carried inside every payload', () {
      for (final j in kAdminJurisdictions) {
        final p = adminBoundaryPayload(
            regionFixtureId: j.regionFixtureId, visible: true);
        expect(p['separation'], kAdminSeparationStatement);
      }
    });
  });
}
