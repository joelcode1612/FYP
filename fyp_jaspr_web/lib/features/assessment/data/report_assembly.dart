/// Reads everything the assessment report document is built from, in one place.
///
/// The report is reachable from two entry points — in place inside the
/// workspace, and from its own route (`/entrepreneur/assessment-report`) — and
/// both must assemble the *same* document. Duplicating the read sequence would
/// let the two disagree about which sections are available, and the explanation
/// chain in particular is a governed, identity-checked read that must not be
/// reimplemented per caller.
///
/// The reads are sequential on purpose: when the report itself fails, the
/// business description is not fetched at all, so a failed page never issues a
/// second request whose result it cannot use.
library;

import 'package:sitewise_jaspr_web/features/assessment/data/assessment_api.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/assessment_report.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/business_description.dart';
import 'package:sitewise_jaspr_web/features/assessment/data/explanation_candidate.dart';

/// The report document and the RP-13 business description read together.
///
/// They are one future because they are one document: section 02 is part of the
/// report, so a page that rendered the report without it and then again with it
/// would flicker between two different documents. [business] is null when the
/// description read failed — the section then renders its held state, and the
/// failure never masks a report that did assemble.
final class ReportAssembly {
  final ApiResult<AssessmentReportPayload> report;
  final BusinessDescription? business;

  /// The explanation the report may render, or `null` when none could be read.
  final ExplanationPanel? explanation;

  const ReportAssembly(this.report, this.business, [this.explanation]);
}

/// Assembles the report for [record].
///
/// A failed business-description read leaves section 02 in its held state rather
/// than failing the whole report; the failure is not silent, because the section
/// then says no confirmed description could be read.
Future<ReportAssembly> loadReportAssembly(
  AssessmentApi api,
  AssessmentRecord record,
) async {
  final report = await api.report(record.assessmentId);
  if (!report.ok) return ReportAssembly(report, null);
  final business = await api.businessDescription(record.assessmentId);
  final explanation = await loadReportExplanation(api, record);
  return ReportAssembly(
    report,
    business.ok ? business.value : null,
    explanation,
  );
}

/// The explanation the report may show.
///
/// EX-05 closes the three EX-04 gaps: the readback envelope carries the
/// assessment/campaign/snapshot identity, the backend resolves that chain from
/// the authenticated owner's records, and a store-backed read endpoint returns
/// the persisted candidate. The client still verifies every returned identity
/// before drawing anything.
///
/// The module-level notice remains the honest answer when no result exists. If a
/// result exists but is substantive and unadmitted, no card is shown — a warning
/// would still confirm that a measurement exists.
Future<ExplanationPanel?> loadReportExplanation(
  AssessmentApi api,
  AssessmentRecord record,
) async {
  final availability = await api.explanationAvailability();
  ExplanationPanel? moduleHeld;
  if (availability.ok && availability.value?['state'] == 'held') {
    final message = availability.value?['message'];
    moduleHeld = ExplanationPanel.unavailable(
      reason: message is String && message.trim().isNotEmpty ? message : null,
    );
  }

  final m2AssessmentId = record.m2AssessmentId;
  if (m2AssessmentId == null) return moduleHeld;
  final bindingResult = await api.explanationBinding(m2AssessmentId);
  if (!bindingResult.ok || bindingResult.value == null) return moduleHeld;
  final binding = bindingResult.value!;
  // The binding contract is keyed by the M2 assessment, not the marketplace
  // record: `/cq/assessments/{id}/explanations/binding` is addressed with
  // `m2AssessmentId` and echoes that id back. Comparing it to
  // `record.assessmentId` could never succeed, which silently disabled the whole
  // governed readback path.
  if (binding['assessment_id']?.toString() != m2AssessmentId) {
    return moduleHeld;
  }
  final campaignId = binding['campaign_id']?.toString();
  final snapshots = binding['snapshots'];
  if (campaignId == null || campaignId.isEmpty || snapshots is! List) {
    return moduleHeld;
  }

  var sawResult = false;
  for (final entry in snapshots) {
    if (entry is! Map) continue;
    final snapshot = Map<String, dynamic>.from(entry);
    final snapshotId = snapshot['snapshot_id']?.toString();
    final questionId = snapshot['slot_id']?.toString();
    final contextHash = snapshot['context_hash']?.toString();
    if (snapshotId == null || questionId == null || contextHash == null) {
      continue;
    }
    final read = await api.explanationReadback(
      assessmentId: m2AssessmentId,
      campaignId: campaignId,
      snapshotId: snapshotId,
      questionId: questionId,
      contextHash: contextHash,
    );
    if (!read.ok || read.value == null) continue;
    sawResult = true;
    ExplanationPanel panel;
    try {
      panel = ExplanationPanel.fromReadback(read.value!);
    } on FormatException {
      continue;
    }
    // The readback envelope carries the M2 assessment id the route was addressed
    // with, so identity is checked against that — not the marketplace record id.
    if (panel.assessmentId != m2AssessmentId ||
        panel.campaignId != campaignId ||
        panel.snapshotId != snapshotId ||
        !panel.boundToSnapshot(snapshotId)) {
      continue;
    }
    if (panel.isRenderable) return panel;
  }
  // A stored candidate that cannot be shown is not the same as no candidate.
  return sawResult ? null : moduleHeld;
}
