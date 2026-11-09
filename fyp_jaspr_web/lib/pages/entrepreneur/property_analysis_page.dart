import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/location_evidence_panel.dart';
import '../../components/property_leaflet_map.dart';
import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../data/location_evidence_api.dart';
import '../../layouts/app_layout.dart';

/// Dedicated evidence drill-down. Preserves the property id from the detail
/// page, and does not treat another catalogue's subject as a verified match.
@client
class PropertyAnalysisPage extends StatefulComponent {
  final String id;
  const PropertyAnalysisPage({super.key, required this.id});

  @override
  State<PropertyAnalysisPage> createState() => _PropertyAnalysisPageState();
}

class _PropertyAnalysisPageState extends State<PropertyAnalysisPage> {
  late Future<CommercialProperty?> _property;
  late Future<PropertyEvidence> _evidence;

  @override
  void initState() {
    super.initState();
    final id = component.id;
    _property = _loadProperty(id);
    _evidence = LocationEvidenceApi.load(id, catalog: int.tryParse(id) == null);
  }

  Future<CommercialProperty?> _loadProperty(String id) async {
    if (id.isEmpty) return null;
    return AppLocator.properties.detail(id);
  }

  @override
  Component build(BuildContext context) => AppLayout(
    role: AppRole.entrepreneur,
    currentRoute: '/entrepreneur/property-analysis',
    title: 'Property location analysis',
    eyebrow: 'Location intelligence',
    showPageHead: false,
    child: FutureBuilder<CommercialProperty?>(
      future: _property,
      builder: (context, propertySnap) {
        if (propertySnap.connectionState != ConnectionState.done) {
          return div(classes: 'loading', [Component.text('Loading property…')]);
        }
        if (propertySnap.hasError || propertySnap.data == null) {
          return EmptyState(
            title: 'Property not available',
            body: 'This property could not be retrieved.',
            action: const ActionLink(
              'Back to Explore',
              href: '/entrepreneur/explore',
            ),
          );
        }
        final property = propertySnap.data!;
        return div(classes: 'sw-pa', [
          PageHead(
            eyebrow: 'Property intelligence',
            title: 'Location analysis',
            description:
                '${property.title} · ${property.city}, ${property.state}',
            badges: [StatusBadge('#${property.id}', tone: 'neutral')],
          ),
          div(classes: 'sw-pa__top-actions', [
            ActionLink(
              'Back to property',
              href:
                  '/entrepreneur/property-detail?id=${Uri.encodeComponent(property.id)}',
              variant: 'secondary',
              icon: 'arrow_back',
            ),
            ActionLink(
              'Assess this property',
              href:
                  '/entrepreneur/assessment?id=${Uri.encodeComponent(property.id)}',
              icon: 'fact_check',
            ),
          ]),
          div(classes: 'sw-pa__intro', [
            div(classes: 'sw-pa__intro-text', [
              span(classes: 'sw-pd__eyebrow', [
                Component.text('RESEARCH EVIDENCE'),
              ]),
              h2([Component.text('Five analytical perspectives')]),
              p([
                Component.text(
                  'Source measurements for competition, access, customers, local priorities and rent. These are not five trained-model scores.',
                ),
              ]),
            ]),
            if ((property.suitabilityScore.isFinite &&
                property.suitabilityScore >= 0 &&
                property.suitabilityScore <= 100))
              div(classes: 'sw-pa__score-mini', [
                strong([
                  Component.text(
                    '${property.suitabilityScore.toStringAsFixed(0)} / 100',
                  ),
                ]),
                span([
                  Component.text(
                    'Imported location index · not a business-success probability',
                  ),
                ]),
              ]),
          ]),
          FutureBuilder<PropertyEvidence>(
            future: _evidence,
            builder: (context, evidenceSnap) {
              if (evidenceSnap.connectionState != ConnectionState.done) {
                return section(classes: 'panel', [
                  p([Component.text('Loading measured evidence…')]),
                ]);
              }
              if (evidenceSnap.hasError) {
                return section(classes: 'panel', [
                  h2([Component.text('Could not load analysis')]),
                  p([
                    Component.text(
                      'The analytical service did not respond. Verify your sign-in and FastAPI connection.',
                    ),
                  ]),
                ]);
              }
              final evidence = evidenceSnap.data;
              if (evidence == null) {
                return section(classes: 'panel', [
                  p([Component.text('No analysis response received.')]),
                ]);
              }
              return div([
                if (evidence.available)
                  div(classes: 'sw-pa__provenance', [
                    span([
                      Component.text(
                        'Analysis status: ${evidence.analysisStatus ?? 'Not recorded'}',
                      ),
                    ]),
                    span([
                      Component.text(
                        'Coverage: ${evidence.referenceCoverage ?? 'Not recorded'}',
                      ),
                    ]),
                    span([
                      Component.text(
                        'Feature snapshot: ${evidence.snapshotAt ?? 'Not recorded'}',
                      ),
                    ]),
                  ]),
                LocationEvidenceDetails(evidence: evidence, property: property),
              ]);
            },
          ),
          section(classes: 'panel sw-pa__map-panel', [
            div(classes: 'sw-pd__section-title', [
              h2([Component.text('Property and nearby reference locations')]),
            ]),
            PropertyLeafletMap(property: property, height: 450),
            p(classes: 'sw-pd__footnote', [
              Component.text(
                'Leaflet/CARTO/OSM map. Radius circles are straight-line distances. Optional neighboring pins represent the 955 research properties, not F&B outlets; locations may be approximate.',
              ),
            ]),
          ]),
          section(classes: 'panel', [
            h2([Component.text('Reading these results')]),
            p(classes: 'body', [
              Component.text(
                'A measured zero means no records found in the mapped inventory; an unavailable value means there is no supported observation. Coverage differs by source. This report does not verify licences, predict revenue, or guarantee F&B viability.',
              ),
            ]),
          ]),
        ]);
      },
    ),
  );
}
