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
    required this.conceptVersion,
  });
}

/// Fictional UI previews, not Project1 customer invitations.
const demoAssessmentOffers = <AssessmentOffer>[
  AssessmentOffer(
    id: 'SYN-CAFE-01',
    title: 'Neighbourhood Café Survey',
    area: 'Sample locality · Preview only',
    description:
        'Help explore café purchasing and stated interest in a proposed café.',
    bankVersion: 'CUST03-UI-DEMO',
    routingVersion: 'SIMULATOR-ONLY',
    contextVersion: 'SYN-CTX-001',
    conceptVersion: 'SYN-CONCEPT-001',
  ),
  AssessmentOffer(
    id: 'SYN-CAFE-02',
    title: 'Campus Café Survey',
    area: 'Sample campus area · Preview only',
    description:
        'A second fictional assessment to test separate saved progress.',
    bankVersion: 'CUST03-UI-DEMO',
    routingVersion: 'SIMULATOR-ONLY',
    contextVersion: 'SYN-CTX-002',
    conceptVersion: 'SYN-CONCEPT-002',
  ),
];
