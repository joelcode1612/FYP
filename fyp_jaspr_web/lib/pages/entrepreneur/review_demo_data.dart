// SYNTHETIC DEMO FIXTURES for the Stage 3 / Stage 4 review screens.
//
// Nothing here is measured, verified or fielding-authorized data. The
// assessment API exposes no BDJ findings, QJ bank, QG candidates or audit
// events yet, so these fixtures exist only to show the review UI. Replace
// each list with the versioned read API before any real review.

import 'customer_questionnaire_preview_page.dart';
import 'review_portal_page.dart';

const String demoAssessmentTitle = 'Morning Junction Café';
const String demoAssessmentId = 'A-DEMO-001';
const String demoBatchId = 'QG-BATCH-001';

const List<BdjReviewFinding> demoFindings = [
  BdjReviewFinding(
    id: 'BDJ-01',
    title: 'Break-even expectation',
    sourceRefs: 'M2-12 · M2-13 · M2-14',
    revision: 'Fictional revision 1',
    declaredAnswer: 'Estimated break-even period of 12–23 months.',
    explanation:
        'Based on the entrepreneur forecast and industry benchmarks, the '
        'estimated period is within a reasonable range for a café business '
        'with the proposed concept and location.',
    recommendedAction:
        'Preserve the assumption. Route a request for a calculated break-even '
        'scenario to the separate Financial Planning process.',
    verificationStatus: 'Not verified',
    measurementRequirements: [
      'M2-12: Start-up cost range (total and key components)',
      'M2-13: Expected average monthly expenses',
      'M2-14: Expected monthly revenue or sales range',
    ],
    limitations:
        'Based on entrepreneur assumption, not independently verified. Actual '
        'break-even may vary due to location, demand and operating cost '
        'changes. Benchmark is a general reference — may not reflect the '
        'specific concept.',
    relatedQuestions: 2,
    evidenceCount: 1,
    notesCount: 0,
    updatedAt: '16 Jan 2025, 10:27',
    updatedBy: 'System',
    reviewVersion: 'v1.0',
    relatedM2: 'M2-12, M2-13, M2-14',
    currentStatus: 'Not verified',
  ),
  BdjReviewFinding(
    id: 'BDJ-02',
    title: 'Startup capital',
    sourceRefs: 'M2-12',
    revision: 'Fictional revision 1',
    declaredAnswer: 'Declared start-up capital of RM 120,000.',
    explanation:
        'Captured from the Stage 2 questionnaire as a declared figure with no '
        'independent quotation.',
    recommendedAction: 'Ask for itemised cost quotations before planning.',
    verificationStatus: 'Not verified',
    limitations: 'Single self-declared value; no supplier quotation attached.',
    relatedQuestions: 1,
    evidenceCount: 1,
    updatedAt: '16 Jan 2025, 10:28',
    reviewVersion: 'v1.0',
    relatedM2: 'M2-12',
    currentStatus: 'Not verified',
  ),
  BdjReviewFinding(
    id: 'BDJ-03',
    title: 'Dominant expenses',
    sourceRefs: 'M2-13',
    revision: 'Fictional revision 1',
    declaredAnswer: 'Rent and staffing are the two dominant monthly expenses.',
    explanation:
        'Derived from the declared monthly expense split; the split itself is '
        'not benchmarked.',
    recommendedAction: 'Split fixed and variable costs explicitly.',
    verificationStatus: 'Not verified',
    limitations: 'Expense split is self-reported and unrounded.',
    relatedQuestions: 0,
    evidenceCount: 1,
    updatedAt: '16 Jan 2025, 10:29',
    reviewVersion: 'v1.0',
    relatedM2: 'M2-13',
    currentStatus: 'Not verified',
  ),
];

const List<QjQuestion> demoQjQuestions = [
  QjQuestion(
      id: 'QJ-01',
      shortTitle: 'Target customer segment',
      construct: 'Demand',
      status: 'Reviewed'),
  QjQuestion(
      id: 'QJ-02',
      shortTitle: 'Visit frequency',
      construct: 'Demand',
      status: 'Reviewed'),
  QjQuestion(
      id: 'QJ-03',
      shortTitle: 'Daypart preference',
      construct: 'Demand',
      status: 'Reviewed'),
  QjQuestion(
      id: 'QJ-04',
      shortTitle: 'Price sensitivity',
      construct: 'Pricing',
      status: 'Reviewed'),
  QjQuestion(
      id: 'QJ-05',
      shortTitle: 'Service format',
      construct: 'Service',
      status: 'Reviewed'),
  QjQuestion(
      id: 'QJ-06',
      shortTitle: 'Takeaway share',
      construct: 'Service',
      status: 'Reviewed'),
  QjQuestion(
      id: 'QJ-07',
      shortTitle: 'Travel radius',
      construct: 'Location'),
  QjQuestion(
      id: 'QJ-08',
      shortTitle: 'Past café visit occasions',
      construct: 'Occasions'),
  QjQuestion(
      id: 'QJ-09',
      shortTitle: 'Future café visit occasions',
      construct: 'Occasions'),
  QjQuestion(
      id: 'QJ-10',
      shortTitle: 'Café feature priorities',
      construct: 'Occasions'),
  QjQuestion(
      id: 'QJ-11',
      shortTitle: 'Preferred service format',
      construct: 'Context'),
  QjQuestion(
      id: 'QJ-12',
      shortTitle: 'Travel mode to study area',
      construct: 'Context'),
  QjQuestion(
      id: 'QJ-13',
      shortTitle: 'Expected latte price band',
      construct: 'Pricing'),
];

QgCandidatePreview _candidate({
  required String id,
  required String title,
  required String construct,
  required String disposition,
  String bankStatus = 'Not equivalent — draft wording',
}) =>
    QgCandidatePreview(
      item: QuestionnairePreviewItem(
        id: id,
        shortTitle: title,
        prompt: title,
        help: 'Illustrative QG draft wording — not fielding-approved.',
        construct: construct,
        measurementGate: 'Stimulus wording not approved',
        source: 'Owner-accepted QG candidate (synthetic demo)',
        version: 'QG draft, unverified',
        blocked: true,
      ),
      ownerDisposition: disposition,
      candidateVersion: 'v0.1 draft',
      bankEquivalenceStatus: bankStatus,
      stimulusStatus: 'Illustrative summary only; versioned concept card is not approved',
    );

const String _pending = QgOwnerDisposition.pending;
const String _accepted = QgOwnerDisposition.accepted;

final List<QgReviewCandidate> demoCandidates = [
  QgReviewCandidate(
    candidate: _candidate(
      id: 'QG-CAND-001',
      title: 'Purchase frequency: breakfast takeaway combination',
      construct: 'Demand',
      disposition: _pending,
    ),
    researchQuestion:
        'How often would customers buy a breakfast takeaway combination?',
    respondentDefinition: 'Café customers within the stated travel radius',
    stimulusRequirement: 'Menu and price panel',
    inferenceLimit: 'Descriptive frequency only; no revenue inference',
    methodologicalNote:
        'Draft wording has not passed bank-equivalence or pretest gates.',
  ),
  QgReviewCandidate(
    candidate: _candidate(
      id: 'QG-CAND-002',
      title: 'Preferred price range for a medium latte',
      construct: 'Pricing',
      disposition: _pending,
    ),
    researchQuestion: 'Which price band feels acceptable for a medium latte?',
    respondentDefinition: 'Café customers within the stated travel radius',
    stimulusRequirement: 'Price ladder card',
    inferenceLimit: 'Acceptance band only; not willingness to pay',
    methodologicalNote:
        'Price ladder needs stimulus approval before any fielding.',
  ),
  QgReviewCandidate(
    candidate: _candidate(
      id: 'QG-CAND-003',
      title: 'Dine-in vs takeaway preference',
      construct: 'Service',
      disposition: _pending,
    ),
    researchQuestion: 'Would customers dine in or take away most visits?',
    respondentDefinition: 'Café customers within the stated travel radius',
    stimulusRequirement: 'Seating and counter layout description',
    inferenceLimit: 'Stated preference only',
    methodologicalNote: 'Layout description is illustrative, not approved.',
  ),
  QgReviewCandidate(
    candidate: _candidate(
      id: 'QG-CAND-004',
      title: 'Weekend visit intent',
      construct: 'Demand',
      disposition: _pending,
    ),
    researchQuestion: 'How likely is a weekend visit within the next month?',
    respondentDefinition: 'Café customers within the stated travel radius',
    stimulusRequirement: 'None',
    inferenceLimit: 'Intent only; not a demand estimate',
    methodologicalNote: 'Intent questions are not demand evidence.',
  ),
  QgReviewCandidate(
    candidate: _candidate(
      id: 'QG-CAND-005',
      title: 'Hybrid café visit interest',
      construct: 'Service',
      disposition: _accepted,
      bankStatus: 'Potential overlap with Q05; no scientific equivalence finding',
    ),
    researchQuestion:
        'How likely would customers be to visit a hybrid café offering '
        'beverages, pastries and light meals?',
    respondentDefinition: 'Café customers within the stated travel radius',
    stimulusRequirement: 'Illustrative concept card (not approved)',
    inferenceLimit: 'Stated hypothetical interest only',
    methodologicalNote:
        'Owner acceptance is a workflow state, not scientific acceptance.',
  ),
];

final List<ReviewAuditEvent> demoAuditHistory = [
  ReviewAuditEvent(
    candidateId: 'BDJ-01',
    title: 'Candidate created',
    note: 'BDJ-01 generated from M2-12, M2-13, M2-14.',
    actor: 'System',
    at: DateTime.utc(2025, 1, 16, 10, 24),
  ),
  ReviewAuditEvent(
    candidateId: 'BDJ-01',
    title: 'Under review',
    note: 'Ready for owner decision.',
    actor: 'System',
    at: DateTime.utc(2025, 1, 16, 10, 27),
  ),
  ReviewAuditEvent(
    candidateId: 'QG-CAND-005',
    title: 'Candidate accepted for review',
    note: 'Owner accepted this candidate for scientific review only.',
    actor: 'Owner decision (demo)',
    at: DateTime.utc(2025, 1, 16, 10, 31),
  ),
];

const List<QuestionnairePreviewItem> demoQuestionBank = [
  QuestionnairePreviewItem(
    id: 'Q01',
    shortTitle: 'Business concept summary',
    group: 'A. Business basics',
    prompt: 'Describe the café concept in one sentence.',
    help: 'Existing bank item; wording is illustrative in this demo.',
    construct: 'Context',
    measurementGate: 'Wording revision pending',
  ),
  QuestionnairePreviewItem(
    id: 'Q02',
    shortTitle: 'Target customer',
    group: 'A. Business basics',
    prompt: 'Who is the main target customer?',
    help: 'Existing bank item; wording is illustrative in this demo.',
    construct: 'Demand',
    measurementGate: 'Wording revision pending',
  ),
  QuestionnairePreviewItem(
    id: 'Q03',
    shortTitle: 'Opening hours',
    group: 'A. Business basics',
    prompt: 'Which operating hours are planned?',
    help: 'Existing bank item; wording is illustrative in this demo.',
    construct: 'Service',
    measurementGate: 'Wording revision pending',
  ),
  QuestionnairePreviewItem(
    id: 'Q04',
    shortTitle: 'Seating capacity',
    group: 'A. Business basics',
    prompt: 'How many seats are planned?',
    help: 'Existing bank item; wording is illustrative in this demo.',
    construct: 'Service',
    measurementGate: 'Wording revision pending',
  ),
  QuestionnairePreviewItem(
    id: 'Q05',
    shortTitle: 'Menu focus',
    group: 'B. Demand and customers',
    prompt: 'Which menu items will lead the offer?',
    help: 'Existing bank item; wording is illustrative in this demo.',
    construct: 'Demand',
    measurementGate: 'Wording revision pending',
  ),
  QuestionnairePreviewItem(
    id: 'Q06',
    shortTitle: 'Visit frequency',
    group: 'B. Demand and customers',
    prompt: 'How often do customers visit cafés like this?',
    help: 'Existing bank item; wording is illustrative in this demo.',
    construct: 'Demand',
    measurementGate: 'Wording revision pending',
  ),
  QuestionnairePreviewItem(
    id: 'Q07',
    shortTitle: 'Spend per visit',
    group: 'B. Demand and customers',
    prompt: 'What is the typical spend per visit?',
    help: 'Existing bank item; wording is illustrative in this demo.',
    construct: 'Pricing',
    measurementGate: 'Wording revision pending',
  ),
  QuestionnairePreviewItem(
    id: 'Q08',
    shortTitle: 'Past café visit occasions',
    group: 'C. Occasions and features',
    prompt: 'Which occasions best describe your past café visits?',
    help: 'Existing bank item; wording is illustrative in this demo.',
    construct: 'Occasions',
    measurementGate: 'Wording revision pending',
    options: [
      'Breakfast before work',
      'Lunch with colleagues',
      'Afternoon study or remote work',
      'Weekend social meet-up',
    ],
    multiple: true,
  ),
  QuestionnairePreviewItem(
    id: 'Q09',
    shortTitle: 'Future café visit occasions',
    group: 'C. Occasions and features',
    prompt: 'Which occasions are most likely for future visits?',
    help: 'Existing bank item; wording is illustrative in this demo.',
    construct: 'Occasions',
    measurementGate: 'Wording revision pending',
    options: ['Morning', 'Lunch', 'Afternoon', 'Evening'],
    multiple: true,
  ),
  QuestionnairePreviewItem(
    id: 'Q10',
    shortTitle: 'Café feature priorities',
    group: 'C. Occasions and features',
    prompt: 'Rank the features that matter most in choosing a café.',
    help: 'Existing bank item; wording is illustrative in this demo.',
    construct: 'Occasions',
    measurementGate: 'Wording revision pending',
    options: ['Wi-Fi and sockets', 'Quiet seating', 'Food quality', 'Price'],
    multiple: true,
  ),
  QuestionnairePreviewItem(
    id: 'Q11',
    shortTitle: 'Preferred service format',
    group: 'D. Additional context',
    prompt: 'How would you prefer to order and collect?',
    help: 'Existing bank item; wording is illustrative in this demo.',
    construct: 'Service',
    measurementGate: 'Wording revision pending',
    options: ['Counter service', 'Table service', 'App pre-order'],
  ),
  QuestionnairePreviewItem(
    id: 'Q12',
    shortTitle: 'Travel mode to study area',
    group: 'D. Additional context',
    prompt: 'How would you usually travel to this area?',
    help: 'Existing bank item; wording is illustrative in this demo.',
    construct: 'Context',
    measurementGate: 'Wording revision pending',
    options: ['Drive', 'Public transport', 'Walk', 'Ride-hailing'],
  ),
  QuestionnairePreviewItem(
    id: 'Q13',
    shortTitle: 'Expected latte price band',
    group: 'D. Additional context',
    prompt: 'What price band would you expect for a medium latte?',
    help: 'Existing bank item; wording is illustrative in this demo.',
    construct: 'Pricing',
    measurementGate: 'Wording revision pending',
    options: ['Under RM 10', 'RM 10–13', 'RM 14–17', 'Above RM 17'],
  ),
];

/// The accepted QG candidate as a full preview item with answer options.
final List<QgCandidatePreview> demoPreviewCandidates = [
  QgCandidatePreview(
    item: const QuestionnairePreviewItem(
      id: 'QG-CAND-005',
      shortTitle: 'Hybrid café visit interest',
      group: 'Accepted QG candidates',
      prompt:
          'How likely would you be to visit the proposed hybrid café offering '
          'beverages, pastries and light meals in the next three months?',
      help: 'Illustrative QG draft wording — not fielding-approved.',
      construct: 'Stated hypothetical visit interest',
      measurementGate:
          'Potential overlap with Q05; no scientific equivalence finding',
      source: 'Owner-accepted QG candidate (synthetic demo)',
      version: 'QG draft, unverified',
      options: [
        'Very likely',
        'Likely',
        'Not sure',
        'Unlikely',
        'Very unlikely',
      ],
    ),
    ownerDisposition: QgOwnerDisposition.accepted,
    candidateVersion: 'v0.1 draft',
    bankEquivalenceStatus:
        'Potential overlap with Q05; no scientific equivalence finding',
    stimulusStatus:
        'Illustrative summary only; versioned concept card is not approved',
  ),
  for (final candidate in demoCandidates)
    if (candidate.id != 'QG-CAND-005') candidate.candidate,
];
