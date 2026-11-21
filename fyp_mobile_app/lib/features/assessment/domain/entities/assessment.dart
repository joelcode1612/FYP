class AssessmentOffer {
  final String id;
  final String title;
  final String area;
  final String description;
  final String bankVersion;
  final String routingVersion;
  final String contextVersion;
  final String conceptVersion;
  const AssessmentOffer({
    required this.id,
    required this.title,
    required this.area,
    required this.description,
    required this.bankVersion,
    required this.routingVersion,
    required this.contextVersion,
    required     this.conceptVersion,
  });
}

/// UI demonstration offers for the local assessment preview.
///
/// Synthetic data only — no real customer research is fielded. Mirrors the
/// development-preview disclaimer shown on the assessment home screen.
const List<AssessmentOffer> demoAssessmentOffers = <AssessmentOffer>[
  AssessmentOffer(
    id: 'demo-cafe',
    title: 'Café demand assessment',
    area: 'City Centre',
    description:
        'Gauge interest in a coffee, drinks and pastries concept in a busy '
        'pedestrian area.',
    bankVersion: 'demo-bank-0',
    routingVersion: 'demo-route-0',
    contextVersion: 'demo-context-0',
    conceptVersion: 'demo-concept-cafe',
  ),
  AssessmentOffer(
    id: 'demo-gym',
    title: 'Micro-gym demand assessment',
    area: 'Suburban Plaza',
    description:
        'Test appetite for a compact fitness and recovery studio near '
        'residential blocks.',
    bankVersion: 'demo-bank-0',
    routingVersion: 'demo-route-0',
    contextVersion: 'demo-context-0',
    conceptVersion: 'demo-concept-gym',
  ),
  AssessmentOffer(
    id: 'demo-kiosk',
    title: 'Retail kiosk demand assessment',
    area: 'Transit Hub',
    description:
        'Explore demand for a quick-service retail kiosk with high footfall.',
    bankVersion: 'demo-bank-0',
    routingVersion: 'demo-route-0',
    contextVersion: 'demo-context-0',
    conceptVersion: 'demo-concept-kiosk',
  ),
];
