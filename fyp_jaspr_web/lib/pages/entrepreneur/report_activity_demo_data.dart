// SYNTHETIC DEMO FIXTURES for the Report and Activity History screens.
//
// The assessment API does not expose a report snapshot or an audit-event
// projection yet, so these values exist only to render the approved layout.
// Replace them with the versioned report/audit reads before any real use.

import 'activity_history_page.dart';
import 'cafe_demand_report_page.dart';

const CafeReportSnapshot demoReportSnapshot = CafeReportSnapshot(
  businessName: 'Morning Junction Café — A-DEMO-001',
  assessmentId: 'A-DEMO-001',
  snapshotId: 'RPT-0001',
  evidenceCutoff: '16 Jan 2025',
  admitted: false,
  concept:
      'Morning Junction Café is a proposed café business intended to operate '
      'from a suburban shoplot in Selangor, Malaysia. The entrepreneur plans to '
      'establish a hybrid café combining dine-in and takeaway services, '
      'providing customers with options for enjoying beverages and light food '
      'either within the premises or elsewhere.',
  productsAndServices:
      'The café plans to offer coffee and espresso beverages, non-coffee drinks '
      '(e.g., tea and chocolate), pastries and light meals. Both dine-in and '
      'takeaway services are intended.',
  targetCustomers:
      'The café primarily intends to serve office workers and nearby residents '
      'as its main customer groups. The entrepreneur claims to differentiate the '
      'café through product quality and convenience, which are intended '
      'attributes and not a verified advantage over existing cafés.',
  uncertaintySummary:
      'Breakfast takeaway interest is declared in M2 (M2-12, M2-13, M2-14) but '
      'remains pending confirmation. Any QL research recommendation is not '
      'scientifically approved and cannot be presented as a finding.',
);

const List<AssessmentActivity> demoActivities = [
  AssessmentActivity(
    eventId: 'EV-0009',
    occurredAtIso: '2025-01-16T14:32:00Z',
    engine: 'QG',
    activityType: 'Candidate generation',
    status: 'Completed',
    title: 'Question candidate generated',
    summary:
        'Generated 3 candidate customer questions based on the confirmed '
        'business context, QJ decision and approved question bank. All '
        'candidates passed basic validity checks and were submitted for owner '
        'review.',
    actor: 'Engine: QG (Question Generator)',
    version: 'QG v1.0',
    inputReferences: [
      'Business context package: BCB v1.2 (ID: BCB-0012)',
      'QJ decision: QJ-DEC-004 (customer research)',
      'Approved question bank: QB v1.0',
    ],
    outputReferences: [
      'QG-01 Interest in specialty coffee · Demand · Accepted (by owner)',
      'QG-02 Working / study at café (duration) · Behaviour · Accepted (by owner)',
      'QG-03 Likely monthly visit frequency · Demand · Accepted (by owner)',
    ],
  ),
  AssessmentActivity(
    eventId: 'EV-0008',
    occurredAtIso: '2025-01-16T14:20:00Z',
    engine: 'QJ',
    activityType: 'Decision',
    status: 'Completed',
    title: 'Research decision finalised',
    summary: 'Selected customer questionnaire for demand evidence (DE-01).',
    actor: 'Engine: QJ (Questionnaire Justification)',
    version: 'QJ v1.0',
    inputReferences: ['QJ-DEC-004'],
    outputReferences: ['Customer research route: DE-01'],
  ),
  AssessmentActivity(
    eventId: 'EV-0007',
    occurredAtIso: '2025-01-16T14:05:00Z',
    engine: 'BCB',
    activityType: 'Context build',
    status: 'Completed',
    title: 'Business context built',
    summary: 'Context package v1.2 created from M2 and BDJ findings.',
    actor: 'Engine: BCB (Business Context Builder)',
    version: 'BCB v1.2',
    inputReferences: ['M2 form answers', 'BDJ-01, BDJ-02, BDJ-03'],
    outputReferences: ['BCB-0012'],
  ),
  AssessmentActivity(
    eventId: 'EV-0006',
    occurredAtIso: '2025-01-16T13:48:00Z',
    engine: 'BDJ',
    activityType: 'Attribute interpretation',
    status: 'Completed',
    title: 'Business description analysed',
    summary:
        '3 findings identified (break-even, startup capital, expenses).',
    actor: 'Engine: BDJ (Business Description Judgement)',
    version: 'BDJ v1.0',
    inputReferences: ['M2-12', 'M2-13', 'M2-14'],
    outputReferences: ['BDJ-01', 'BDJ-02', 'BDJ-03'],
  ),
  AssessmentActivity(
    eventId: 'EV-0005',
    occurredAtIso: '2025-01-16T11:15:00Z',
    engine: 'EE-01',
    activityType: 'Evidence check',
    status: 'Partial',
    title: 'Evidence check (preliminary)',
    summary: 'Checked data availability for demand evidence (Direction A).',
    actor: 'Engine: EE-01 (Evidence Engine)',
    version: 'EE-01 v0.9',
    inputReferences: ['M2-12', 'M2-13', 'M2-14'],
    outputReferences: ['Availability: partial'],
  ),
  AssessmentActivity(
    eventId: 'EV-0004',
    occurredAtIso: '2025-01-16T10:44:00Z',
    engine: 'EXPL',
    activityType: 'Explanation',
    status: 'Completed',
    title: 'Explanation draft prepared',
    summary:
        'Draft explanation text prepared for owner review; not admitted to a '
        'report.',
    actor: 'Engine: Explanation',
    version: 'EXPL v1.0',
    inputReferences: ['BDJ-01'],
    outputReferences: ['EXPL-DRAFT-01'],
  ),
  AssessmentActivity(
    eventId: 'EV-0003',
    occurredAtIso: '2025-01-16T10:30:00Z',
    engine: 'A10',
    activityType: 'Report admission',
    status: 'Pending',
    title: 'Report admission deferred',
    summary:
        'A10 admission has not been granted; report sections stay withheld.',
    actor: 'System',
    version: 'A10 v1.0',
    inputReferences: ['RPT-0001'],
    outputReferences: [],
  ),
  AssessmentActivity(
    eventId: 'EV-0002',
    occurredAtIso: '2025-01-16T10:24:00Z',
    engine: 'System',
    activityType: 'Assessment creation',
    status: 'Completed',
    title: 'Assessment created',
    summary: 'Assessment A-DEMO-001 created from M2-17.',
    actor: 'System',
    version: 'v1.0',
    inputReferences: ['M2-17'],
    outputReferences: ['A-DEMO-001'],
  ),
];
