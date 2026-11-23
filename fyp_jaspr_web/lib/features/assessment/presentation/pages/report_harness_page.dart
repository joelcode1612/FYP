import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_report.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/measurement_chart_preview.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/q01_synthetic_preview.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/synthetic_preview_gate.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/pages/assessment_report_view.dart';
import 'package:sitewise_jaspr_web/shared/presentation/components/ui.dart';
import 'package:sitewise_jaspr_web/shared/presentation/layouts/app_layout.dart';

/// Development-only harness that mounts the **real** report.
///
/// This is not a second report design. It renders [AssessmentReportView] — the
/// same component the Step-5 workspace renders — with a synthetic payload so the
/// document can be inspected in a browser without a live fielded assessment.
/// The production route needs an authenticated API session to assemble a
/// payload; this harness supplies one instead, and says so at the top of the
/// page.
///
/// What it exists to show: the Q01 synthetic demonstration sitting inside the
/// report's own questionnaire section, in the report's own layout. Every class
/// on screen belongs to the report; the harness only supplies data.
///
/// It grants no authority. The Q01 chart is `SYNTHETIC_PREVIEW_ONLY` with a
/// `HELD` admission block, and the report's R03 section keeps its held state
/// because no admitted spec is supplied.
class ReportHarnessPage extends StatelessComponent {
  const ReportHarnessPage({super.key});

  @override
  Component build(BuildContext context) {
    if (!syntheticPreviewEnabled) {
      return AppLayout(
        role: AppRole.entrepreneur,
        currentRoute: syntheticPreviewPath,
        title: 'Report harness unavailable',
        child: const _Refusal(),
      );
    }
    return AppLayout(
      role: AppRole.entrepreneur,
      currentRoute: syntheticPreviewPath,
      title: 'Assessment report',
      subtitle: 'Development harness — synthetic inputs, real report component.',
      showBreadcrumbs: false,
      child: div(classes: 'stack stack--md', [
        const _HarnessNotice(),
        AssessmentReportView(
          report: _payload(),
          record: _record(),
          register: const [],
          decisions: const {},
          scope: _businessScope,
          objective:
              'Decide whether the area supports the concept for the declared '
              'business.',
          extraQuestions: const [],
          // No admitted chart: R03 stays held, exactly as in production.
          q01Preview: Q01SyntheticPreview.tryFromFixture(),
          // The real EE-01 measurement readback for R03. Withheld, not admitted.
          measurementChart: MeasurementChartPreview.tryFromFixture(),
          backLabel: 'Back',
          onBack: () {},
        ),
      ]),
    );
  }

  /// The declared business, as the report's Step-2 scope rows. Synthetic, and
  /// deliberately shaped like the five BCB V1.2.1 headings RP-13 will map onto.
  static const List<(String, String)> _businessScope = [
    ('Business overview', 'Neighbourhood café serving the surrounding offices'),
    ('Products and services', 'Coffee, pastries and light lunch'),
    ('Intended customer groups', 'Office workers and local residents'),
    ('Proposed customer experience', 'Fast counter service with limited seating'),
    ('Planning status and limitations', 'Concept only — premises not secured'),
  ];

  /// The assessment this harness presents: the FC4-D synthetic run's own
  /// assessment id, not a placeholder.
  ///
  /// It must be the real id because the report binds a measurement readback to
  /// the assessment named in its provenance (`_boundMeasurement`). A made-up
  /// placeholder would silently drop the card — which would hide the very thing
  /// this harness exists to show — so the harness names the record the
  /// measurement actually belongs to.
  static const String _assessmentId = '37f20705-cd31-5b53-b792-9b30cb49c465';

  static AssessmentRecord _record() => AssessmentRecord.fromJson({
    'assessment_id': _assessmentId,
    'property_id': 'prop-harness-0001',
    'status': 'in_progress',
    'current_stage': 4,
    'current_stage_key': 'question_review',
    'completed_stages': 3,
    'total_stages': 5,
    'progress_percent': 60,
    'report_available': false,
  });

  static AssessmentReportPayload _payload() => AssessmentReportPayload(
    assessmentId: _assessmentId,
    propertyId: 'prop-harness-0001',
    status: 'in_progress',
    generatedAt: '2026-11-22T09:00:00Z',
    requirementsVersion: 1,
    questionnaire: const ReportSection(
      available: false,
      reason:
          'No released questionnaire has been fielded for this assessment, so '
          'no customer response exists to distribute.',
    ),
    property: ReportSection.empty,
    listingMedia: ReportSection.empty,
    geospatialFeatures: ReportSection.empty,
    evidenceCategories: ReportSection.empty,
    researchAssociation: ReportSection.empty,
    explanation: ReportSection.empty,
    requirementMatching: const RequirementMatching(),
    missingInformation: const [
      'Released questionnaire and fielded responses',
      'Adopted report-admission adapter (A10)',
    ],
    modelInformation: const {},
    exportPdf: false,
    exportReason: null,
  );
}

/// Says plainly what the page is. Rendered above the report, never inside it.
class _HarnessNotice extends StatelessComponent {
  const _HarnessNotice();

  @override
  Component build(BuildContext context) => div(classes: 'dev-preview__banner', [
    Icon('science', size: 'lg'),
    div(classes: 'dev-preview__banner-body', [
      p(classes: 'dev-preview__banner-title', [
        Component.text('Development harness — synthetic inputs'),
      ]),
      p(classes: 'dev-preview__banner-text', [
        Component.text(
          'This page mounts the real assessment report with a synthetic '
          'payload, so the document can be inspected without a fielded '
          'assessment. The report layout, sections and styling are the '
          'production ones. The Q01 section below is a synthetic demonstration '
          'and is not report evidence.',
        ),
      ]),
      p(classes: 'dev-preview__banner-text', [
        Component.text(
          'The measurement readback below belongs to assessment '
          '${ReportHarnessPage._assessmentId} — the FC4-D synthetic run — and is '
          'drawn only because this page names that assessment. It is a withheld '
          'readback of a synthetic measurement, never an admitted finding, and it '
          'cannot appear under any other assessment.',
        ),
      ]),
    ]),
  ]);
}

class _Refusal extends StatelessComponent {
  const _Refusal();

  @override
  Component build(BuildContext context) => SectionCard(
    title: 'Not available',
    child: p([
      Component.text(
        'The report harness is disabled. It requires a build made with '
        'SITEWISE_SYNTHETIC_PREVIEW=true, SITEWISE_BUILD_ENV=development, and a '
        'local development origin. Production reports are unaffected.',
      ),
    ]),
  );
}
