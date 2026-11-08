/// WF-07 — System-generated study zone (L1, sample-only).
///
/// Directive: `PROJECT1-GEO-SYSTEM-ZONE-V2-L1-EXECUTE-20261030`.
///
/// This page supersedes the earlier user-drawn-area prototype. It displays:
///  1. Synthetic region navigation (Kuala Lumpur / Penang / Johor / Selangor)
///     — a fixture-context switcher, **not** the teammate BC-05 catalogue.
///  2. A read-only, system-owned [SystemStudyZone] resolved automatically from
///     the selected rental fixture. There is no draw/edit/drag/delete affordance.
///  3. A visually distinct, display-only experimental radius circle that never
///     changes the observation count.
///  4. The twelve synthetic observations, with membership in the active zone.
///  5. An explicit "active calculation footprint = SYSTEM_STUDY_ZONE" statement
///     and a colour-independent accessible text summary.
///  6. L2a: the real DOSM ADM1/ADM2 boundaries for the selected jurisdiction,
///     drawn as context only (see [admin_boundary_layer.dart]). The lower tier
///     (ADM3) is withheld and is not drawn.
///
/// The **synthetic system zones** are still not KL/Penang/Johor/Selangor
/// boundaries and must never be labelled as such; the real boundaries are the
/// separate, dashed L2a layer and carry their own attribution.
library sitewise_jaspr_web.geo.geo_page;

import 'dart:convert';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'package:sitewise_jaspr_web/prototype/prototype_ui.dart';

import 'admin_boundary_layer.dart';
import 'system_study_zone.dart';
import 'system_zone_fixture.dart';

class GeoMapPage extends StatefulComponent {
  const GeoMapPage({super.key});

  @override
  State<GeoMapPage> createState() => _GeoMapPageState();
}

class _GeoMapPageState extends State<GeoMapPage> {
  String selectedRegionId = 'KL';
  double demoRadius = 800; // DISPLAY-ONLY. Never enters the membership count.
  bool showZone = true;
  bool showRadius = true;
  bool showVenues = true;
  bool showAdmin = true;

  static const List<double> kRadiusOptions = [400, 500, 800, 1200];

  SystemZoneRegion get region =>
      regionById(selectedRegionId) ?? kSystemZoneRegions.first;

  // ---------------------------------------------------------------------------
  // Membership (radius is structurally absent from this call)
  // ---------------------------------------------------------------------------

  QueryResult get membership => computeMembership(
        rental: region.rental,
        zone: region.zone,
        observations: region.observations,
        sourceSnapshotId: 'SYNTHETIC-SNAPSHOT-V2',
      );

  // ---------------------------------------------------------------------------
  // Map bridge payload
  // ---------------------------------------------------------------------------

  String geoStateJson() {
    final r = region;
    final m = membership;
    final insideIds = m.insideRecordIds.toSet();
    final payload = <String, dynamic>{
      'sampleMode': true,
      'contractVersion': kSystemZoneContractVersion,
      'activeFootprint': 'SYSTEM_STUDY_ZONE',
      'demoCentre': {
        'lat': r.rental.position?.lat,
        'lng': r.rental.position?.lon,
      },
      'rental': {
        'id': r.rental.rentalId,
        'region': r.navigationLabel,
        'lat': r.rental.position?.lat,
        'lng': r.rental.position?.lon,
        'sample': true,
      },
      'systemZone': {
        'zoneId': r.zone.zoneId,
        'rentalId': r.zone.rentalId,
        'ruleVersion': r.zone.ruleVersion,
        'revision': r.zone.geometryRevision,
        'hash': r.zone.geometryHash,
        'type': r.zone.geometry.type,
        'watermark': kSystemZoneWatermark,
        'visible': showZone,
        'polygons': [
          for (final poly in r.zone.geometry.polygons)
            {
              'outer': [
                for (final p in poly.outer) [p.lat, p.lon],
              ],
              'holes': [
                for (final hole in poly.holes)
                  [
                    for (final p in hole) [p.lat, p.lon],
                  ],
              ],
            },
        ],
      },
      'radius': {
        'active': showRadius && r.rental.position != null,
        'displayOnly': true,
        'lat': r.rental.position?.lat,
        'lng': r.rental.position?.lon,
        'radius': demoRadius,
      },
      'venues': [
        for (final o in r.observations)
          {
            'id': o.recordId,
            'category': o.categoryType,
            'sample': true,
            'lat': o.position?.lat,
            'lng': o.position?.lon,
            'inside': insideIds.contains(o.recordId),
            'visible': showVenues,
          },
      ],
      'admin': adminBoundaryPayload(
        regionFixtureId: r.regionFixtureId,
        visible: showAdmin,
      ),
    };
    return jsonEncode(payload);
  }

  // ---------------------------------------------------------------------------
  // Markup helpers
  // ---------------------------------------------------------------------------

  Component _kv(String label, String value, {String? badge, String? tone}) {
    return div(classes: 'proto-row', [
      span(classes: 'proto-row__label', [Component.text(label)]),
      if (badge != null) ProtoBadge(badge, tone: tone ?? 'neutral'),
      span(classes: 'proto-row__value', [Component.text(value)]),
    ]);
  }

  Component _regionButton(SystemZoneRegion r) {
    final selected = r.regionFixtureId == selectedRegionId;
    return button(
      classes: selected ? 'geo-rental geo-rental--sel' : 'geo-rental',
      attributes: {
        'aria-current': selected ? 'true' : 'false',
        'aria-label': selected
            ? '${r.navigationLabel} region (selected)'
            : '${r.navigationLabel} region',
      },
      events: events(onClick: () {
        setState(() {
          selectedRegionId = r.regionFixtureId;
          showZone = true;
          showRadius = true;
          showVenues = true;
          showAdmin = true;
        });
      }),
      [
        strong([Component.text(r.navigationLabel)]),
        small([Component.text(r.regionFixtureId)]),
        small([Component.text(r.zone.zoneId)]),
      ],
    );
  }

  Component _toggle(String label, bool value, void Function(bool) setter) {
    return button(
      classes: value ? 'geo-rental geo-rental--sel' : 'geo-rental',
      attributes: {
        'aria-pressed': value ? 'true' : 'false',
        'aria-label': '$label layer ${value ? "on" : "off"}',
      },
      events: events(onClick: () => setter(!value)),
      [Component.text('$label: ${value ? "ON" : "OFF"}')],
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Component build(BuildContext context) {
    final r = region;
    final m = membership;
    final zone = r.zone;
    final rentalPos = r.rental.position;
    final adminJ = adminJurisdictionForRegion(r.regionFixtureId);

    return ProtoShell(
      title: 'System-Generated Study Zone',
      eyebrow: 'WF-07 · L1 synthetic system zone (sample-only)',
      currentRoute: '/prototype/wf-07',
      child: div(classes: 'proto-stack', [
        // ------------------------------------------------------------------
        // Scope banner
        // ------------------------------------------------------------------
        ProtoNote(
          'L1 SYNTHETIC DEMONSTRATION. The study zone is system-generated, '
          'read-only and predetermined — there is no user polygon editor '
          '(no draw / edit / drag / delete). The four regions are navigation '
          'labels only; the zones are NOT real Kuala Lumpur, Penang, Johor or '
          'Selangor administrative boundaries and NOT customer catchments. '
          'All twelve venues are fictional sample rows. The thin grey dashed '
          'L2a layer IS real DOSM administrative geometry, drawn as context '
          'only and never counted.',
          tone: 'warn',
        ),

        // ------------------------------------------------------------------
        // 1. Region navigation
        // ------------------------------------------------------------------
        ProtoCard(
          title: 'Synthetic region context (fixture switcher)',
          child: div(classes: 'proto-stack', [
            ProtoNote(
              'This is a developer fixture-context switcher. It is NOT the '
              'teammate BC-05 rental-selection catalogue and creates no '
              'second rental workflow.',
              tone: 'info',
            ),
            div(classes: 'geo-rental-grid', [
              for (final region in kSystemZoneRegions) _regionButton(region),
            ]),
          ]),
        ),

        // ------------------------------------------------------------------
        // 2. Active footprint statement (explicit, non-negotiable)
        // ------------------------------------------------------------------
        ProtoCard(
          title: 'Active calculation footprint',
          child: div(classes: 'proto-stack', [
            div(classes: 'proto-inline', [
              ProtoBadge('SYSTEM_STUDY_ZONE', tone: 'success'),
              span(classes: 'proto-row__value', [
                Component.text(
                  'The ONLY footprint that determines sample venue membership. '
                  'The experimental radius is display-only and does not affect '
                  'the count.',
                ),
              ]),
            ]),
            _kv('Active footprint', m.activeFootprintType,
                badge: 'ACTIVE', tone: 'success'),
            _kv('Rule version', m.ruleVersion),
            _kv('Source snapshot', m.sourceSnapshotId),
            _kv('Contract version', m.contractVersion),
          ]),
        ),

        // ------------------------------------------------------------------
        // 3. System zone (read-only) details
        // ------------------------------------------------------------------
        ProtoCard(
          title: 'System zone — ${zone.zoneId} (read-only)',
          child: div(classes: 'proto-stack', [
            ProtoNote(
              'Resolved automatically from rental "${zone.rentalId}". '
              'Construction: ${zone.constructionMethod}. '
              'Ownership: SYSTEM_DEFINED_READ_ONLY. '
              'Administrative boundary: ${zone.adminBoundary ? "yes" : "NO"}.',
              tone: 'info',
            ),
            _kv('Zone ID', zone.zoneId, badge: 'SYSTEM_OWNED', tone: 'success'),
            _kv('Rental reference', zone.rentalId),
            _kv('Geometry type', zone.geometry.type),
            _kv('Geometry revision', 'r${zone.geometryRevision}'),
            _kv('Geometry digest', zone.geometryHash),
            _kv('Rights state', zone.rightsState),
            _kv('Sample mode', zone.sampleMode ? 'SYNTHETIC_ONLY' : 'REAL',
                badge: zone.sampleMode ? 'SAMPLE' : 'REAL',
                tone: zone.sampleMode ? 'warn' : 'danger'),
            _kv('Administrative boundary', 'NO — synthetic fixture only'),
          ]),
        ),

        // ------------------------------------------------------------------
        // 4. Membership result
        // ------------------------------------------------------------------
        ProtoCard(
          title: 'Sample venue membership — ${r.navigationLabel}',
          child: div(classes: 'proto-stack', [
            ProtoNote(
              'These are synthetic sample observations, never a complete real '
              'business population. A sample count is not a competitor finding.',
              tone: 'warn',
            ),
            div(classes: 'proto-inline', [
              ProtoBadge('${m.insideDistinctCount} INSIDE', tone: 'success'),
              ProtoBadge('${m.rawObservationCount} RAW', tone: 'info'),
              ProtoBadge('${m.distinctObservationCount} DISTINCT', tone: 'info'),
              ProtoBadge('${m.undecidedCount} UNDECIDED',
                  tone: m.undecidedCount > 0 ? 'warn' : 'neutral'),
            ]),
            if (m.unavailableReason != null)
              ProtoNote(m.unavailableReason!, tone: 'danger'),
            _kv(
              'Inside sample venues',
              m.insideRecordIds.isEmpty
                  ? 'none'
                  : m.insideRecordIds.join(', '),
            ),
            if (m.duplicateRecordIds.isNotEmpty)
              _kv('Duplicate records (collapsed)',
                  m.duplicateRecordIds.join(', ')),
            if (m.positionalDuplicateRecordIds.isNotEmpty)
              _kv('Positional duplicates (not double counted)',
                  m.positionalDuplicateRecordIds.join(', ')),
            ProtoNote(
              'Sample-only: this result cannot be promoted to a real '
              'competitor finding (promotableToReal = ${m.promotableToReal}).',
              tone: 'danger',
            ),
          ]),
        ),

        // ------------------------------------------------------------------
        // 5. Display-only radius
        // ------------------------------------------------------------------
        ProtoCard(
          title: 'Experimental radius (display-only)',
          child: div(classes: 'proto-stack', [
            ProtoNote(
              'The radius circle is a visual guide only. It is NOT a '
              'calculation footprint, does not clip or union the system zone, '
              'and cannot change the observation count.',
              tone: 'warn',
            ),
            div(classes: 'proto-inline', [
              for (final radius in kRadiusOptions)
                button(
                  classes: demoRadius == radius
                      ? 'geo-rental geo-rental--sel'
                      : 'geo-rental',
                  attributes: {
                    'aria-label': '${radius.toInt()} metre display radius',
                  },
                  events: events(onClick: () {
                    setState(() => demoRadius = radius);
                  }),
                  [Component.text('${radius.toInt()} m')],
                ),
            ]),
            _kv('Display radius', '${demoRadius.toInt()} m',
                badge: 'DISPLAY_ONLY', tone: 'warn'),
            _kv('Membership count', '${m.insideDistinctCount} (unchanged)',
                badge: 'ZONE-ONLY', tone: 'success'),
          ]),
        ),

        // ------------------------------------------------------------------
        // 6. Map preview
        // ------------------------------------------------------------------
        ProtoCard(
          title: 'Map preview (synthetic)',
          child: div(classes: 'proto-stack', [
            ProtoNote(
              'OSM tiles are display-only (attribution required). The solid '
              'teal polygon is the read-only SYSTEM STUDY ZONE. The dashed '
              'circle is the display-only radius. Filled dots are sample '
              'venues inside the zone; hollow dots are outside. The thin grey '
              'dashed lines are real DOSM ADM1/ADM2 boundaries (L2a), drawn as '
              'context only — they never affect the count.',
              tone: 'info',
            ),
            div(classes: 'proto-inline', [
              _toggle('Zone', showZone, (v) => setState(() => showZone = v)),
              _toggle(
                  'Radius', showRadius, (v) => setState(() => showRadius = v)),
              _toggle(
                  'Venues', showVenues, (v) => setState(() => showVenues = v)),
              _toggle('Admin boundary', showAdmin,
                  (v) => setState(() => showAdmin = v)),
            ]),
            div(
              attributes: {
                'id': 'geo-map',
                'class': 'geo-map',
                'data-geo': geoStateJson(),
                'role': 'region',
                'aria-label': 'Synthetic system zone map for '
                    '${r.navigationLabel}. The system study zone is a '
                    'read-only synthetic polygon; the radius is display-only.',
              },
              [],
            ),
            // Colour-independent accessible summary.
            div(classes: 'proto-stack', [
              span(classes: 'proto-row__label', [
                Component.text('Accessible geographic summary'),
              ]),
              ul(attributes: {'class': 'geo-markers'}, [
                li([
                  Component.text(
                    'Region: ${r.navigationLabel} (${r.regionFixtureId}), '
                    'synthetic fixture context.',
                  ),
                ]),
                li([
                  Component.text(
                    'Rental reference: ${r.rental.rentalId} at '
                    '${rentalPos == null ? "MISSING COORDINATE" : "${rentalPos.lat}, ${rentalPos.lon}"} '
                    '— synthetic fixture, not an actual rental.',
                  ),
                ]),
                li([
                  Component.text(
                    'System study zone: ${zone.zoneId}, read-only, '
                    '${zone.geometry.type}, revision r${zone.geometryRevision}, '
                    'digest ${zone.geometryHash}. Not an administrative boundary.',
                  ),
                ]),
                li(
                  classes: 'geo-admin-summary',
                  [
                    Component.text(
                      _adminSummaryText(r),
                    ),
                  ],
                ),
                li([
                  Component.text(
                    'Active calculation footprint: SYSTEM_STUDY_ZONE only. '
                    'Display radius ${demoRadius.toInt()} m does not affect '
                    'the count.',
                  ),
                ]),
                li([
                  Component.text(
                    'Sample venues inside the zone: '
                    '${m.insideDistinctCount} of ${m.distinctObservationCount} '
                    'distinct (${m.rawObservationCount} raw, '
                    '${m.undecidedCount} undecided).',
                  ),
                ]),
                for (final o in r.observations)
                  li([
                    Component.text(
                      '${o.recordId} (${o.categoryType}) — '
                      '${m.insideRecordIds.contains(o.recordId) ? "INSIDE" : "OUTSIDE"} '
                      'the system zone. Synthetic sample row.',
                    ),
                  ]),
              ]),
            ]),
          ]),
        ),

        // ------------------------------------------------------------------
        // 7. Administrative boundary layer (L2a: DOSM open data)
        // ------------------------------------------------------------------
        ProtoCard(
          title: 'Administrative boundary layer (L2a: DOSM open data)',
          child: div(classes: 'proto-stack', [
            div(classes: 'proto-inline', [
              ProtoBadge('L2A AVAILABLE', tone: 'success'),
              ProtoBadge('ADM3 WITHHELD', tone: 'danger'),
            ]),
            _kv('Layer state', kAdminLayerStatusAvailable,
                badge: 'L2A', tone: 'success'),
            _kv('Source', kAdminSourceId),
            _kv('Licence', '$kAdminLicenceName — reuse without an application',
                badge: 'OPEN', tone: 'success'),
            if (adminJ == null)
              ProtoNote(
                'No DOSM jurisdiction is mapped to this region, so no boundary '
                'is drawn. An unsupported region shows as absent, never as an '
                'empty area that could be read as "no boundary exists".',
                tone: 'danger',
              )
            else ...[
              _kv('Jurisdiction',
                  '${adminJ.dosmStateName} (code_state ${adminJ.codeState})'),
              _kv(
                  'Districts drawn',
                  '${adminJ.districtCount} of $kAdminDistrictTotal across the '
                      'four supported jurisdictions'),
              _kv(
                  'Source geometry defects',
                  '${adminJ.sourceInvalidDistricts.length} OGC-invalid '
                      'district(s) of ${adminJ.districtCount}, displayed '
                      'unmodified; $kAdminOverlapPairsTouchingFour material '
                      'overlap pairs touch these jurisdictions (largest '
                      '${kAdminLargestOverlapKm2.toStringAsFixed(3)} km²)',
                  badge: 'DISCLOSED',
                  tone: 'warn'),
              if (adminJ.sourceInvalidReasons.isNotEmpty)
                ProtoNote(adminJ.sourceInvalidReasons, tone: 'warn'),
            ],
            _kv('Lower tier (mukim / ADM3)', kAdminLayerStatusWithheld,
                badge: 'BLOCKED', tone: 'danger'),
            ProtoNote(kAdminSeparationStatement, tone: 'warn'),
            ProtoNote(kAdminLowerTierReason, tone: 'danger'),
          ]),
        ),

        // ------------------------------------------------------------------
        // 8. Refusal states (documented)
        // ------------------------------------------------------------------
        ProtoCard(
          title: 'Refusal semantics (what happens on bad input)',
          child: div(classes: 'proto-list', [
            _kv('No zone for rental', 'ZONE_NOT_AVAILABLE — no count emitted'),
            _kv('Two valid zones claim rental',
                'ZONE_CONFLICT — resolution refused'),
            _kv('Invalid / self-intersecting zone',
                'ZONE_INVALID_GEOMETRY — no fabricated rectangle'),
            _kv('Unsupported jurisdiction',
                'ZONE_UNSUPPORTED_RENTAL — no other area leaks in'),
            _kv('User attempts to edit zone',
                'REJECT_UNAUTHORIZED_ZONE_EDIT — read-only by design'),
            _kv('Circle and zone counts mixed',
                'REFUSE_AMBIGUOUS_FOOTPRINT — one footprint only'),
          ]),
        ),

        // ------------------------------------------------------------------
        // 9. Release scope and later gates
        // ------------------------------------------------------------------
        ProtoCard(
          title: 'Release scope (L1 now; L2a available; L2b–L4 later)',
          child: div(classes: 'geo-eng-grid', [
            _levelCard('L1 — Synthetic system zone (this build)', 'IN PROGRESS',
                'System-generated read-only zone, display-only radius, sample '
                'venue membership, four region fixtures.'),
            _levelCard(
                'L2a — DOSM administrative boundaries (this build)', 'AVAILABLE',
                'Real DOSM ADM1/ADM2 polygons for KL / Penang / Johor / '
                'Selangor under the DOSM Open Data Licence, drawn as context '
                'only. Owner release decision (L2-10) is still pending.'),
            _levelCard('L2b — Lower tier (mukim / ADM3)', 'WITHHELD',
                'Banked geoBoundaries ADM3: licence chain unverified, no '
                'official codes, 245 cross-state straddles. 0 of 1,859 '
                'features releasable.'),
            _levelCard('L3 — Real rental integration', 'HOLD',
                'Requires the teammate BC-05 interface, stable rental IDs and '
                'Master assessment binding.'),
            _levelCard('L4 — Real zone policy & competitors', 'HOLD',
                'Requires an approved zone-generation policy, real competitor '
                'evidence and R09/R12 report authority.'),
          ]),
        ),

        // ------------------------------------------------------------------
        // 10. Machine-readable receipt
        // ------------------------------------------------------------------
        ProtoCard(
          title: 'Machine-readable receipt',
          child: div(classes: 'proto-stack', [
            ProtoNote(
              'The receipt is synthetic-only and cannot enter genuine evidence '
              'or report paths.',
              tone: 'warn',
            ),
            pre(
              attributes: {'id': 'geo-receipt', 'class': 'geo-receipt'},
              [Component.text(jsonEncode(_receipt()))],
            ),
          ]),
        ),
      ]),
    );
  }

  Component _levelCard(String title, String status, String detail) {
    final tone = switch (status) {
      'AVAILABLE' => 'success',
      'IN PROGRESS' => 'warn',
      'WITHHELD' => 'danger',
      _ => 'neutral',
    };
    return div(classes: 'geo-eng-card', [
      div(classes: 'geo-eng-card__head', [
        span(classes: 'geo-eng-card__title', [Component.text(title)]),
        ProtoBadge(status, tone: tone),
      ]),
      div(classes: 'geo-eng-card__body', [
        ProtoNote(detail, tone: 'info'),
      ]),
    ]);
  }

  /// Colour-independent description of the administrative layer for the
  /// accessible summary. States absence explicitly; never leaves a silent gap.
  String _adminSummaryText(SystemZoneRegion r) {
    final j = adminJurisdictionForRegion(r.regionFixtureId);
    if (j == null) {
      return 'Administrative boundary (L2a): unsupported region — no boundary '
          'is drawn and no empty area implies that none exists.';
    }
    if (!showAdmin) {
      return 'Administrative boundary (L2a, DOSM open data): hidden by the '
          'viewer. It remains context only and never affects the count.';
    }
    final defects = j.sourceInvalidDistricts.isEmpty
        ? 'none of its districts are OGC-invalid in the source'
        : '${j.sourceInvalidDistricts.length} of its ${j.districtCount} '
            'districts are OGC-invalid in the source and are displayed '
            'unmodified (${j.sourceInvalidDistricts.join(", ")})';
    return 'Administrative boundary (L2a, DOSM open data): ${j.dosmStateName} '
        'state outline and ${j.districtCount} district outlines, drawn as '
        'context only — not the study zone, not the radius, not a competitor '
        'footprint, and never counted. $defects. Lower tier (ADM3) is '
        'withheld: $kAdm3Releasable of $kAdm3FeatureCount features releasable '
        '(licence chain unverified).';
  }

  Map<String, dynamic> _receipt() {
    final r = region;
    final m = membership;
    final j = adminJurisdictionForRegion(r.regionFixtureId);
    return {
      'version': 'SYNTHETIC-GEO-SYSTEM-ZONE-L1-20261030',
      'synthetic': true,
      'contractVersion': kSystemZoneContractVersion,
      'fixtureMode': kFixtureMode,
      'activeFootprint': 'SYSTEM_STUDY_ZONE',
      'region': {
        'id': r.regionFixtureId,
        'label': r.navigationLabel,
        'rentalId': r.rental.rentalId,
        'zoneId': r.zone.zoneId,
        'zoneHash': r.zone.geometryHash,
        'ruleVersion': r.zone.ruleVersion,
        'geometryRevision': r.zone.geometryRevision,
        'adminBoundary': r.zone.adminBoundary,
      },
      'membership': m.toJson(),
      'displayRadiusMetres': demoRadius,
      'radiusAffectsCount': false,
      'adminLayer': {
        'status': kAdminLayerStatusAvailable,
        'source': kAdminSourceId,
        'licence': kAdminLicenceName,
        'regionState': j?.dosmStateName,
        'districtCount': j?.districtCount,
        'sourceInvalidDistricts': j?.sourceInvalidDistricts ?? const [],
        'lowerTier': kAdminLayerStatusWithheld,
        'displayedUnmodified': true,
      },
      'adminLayerAffectsMembership': false,
      'warnings': [
        'All study-zone geometry is synthetic. Coordinates are not certified.',
        'System zones are not real Malaysian administrative boundaries.',
        'The L2a administrative overlay is real DOSM open data, drawn as '
            'context only and never counted.',
        'Sample venue counts are not real competitor findings.',
        'Radius is display-only and does not affect the count.',
      ],
    };
  }
}
