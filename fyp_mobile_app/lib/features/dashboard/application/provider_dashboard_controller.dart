import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:fyp/features/property_management/domain/entities/provider_models.dart';
import 'package:fyp/features/property_management/application/provider_listings_service.dart';

/// UI-ready bundle for the Owner / Agent dashboard — the Riverpod view-model
/// layer the dashboard screens render from.
///
/// Composition (all reads are the caller's OWN authorized scope; nothing here
/// filters or estimates client-side):
///
/// * `ProviderListingsService.load(role)` — the ONLY load. Listings for the
///   signed-in role (owner rows via `owner_user_id`, agent rows via
///   assignment). Its failure fails the dashboard: the MFA gate / retry card
///   must show.
///
/// The dashboard deliberately does NOT depend on the Enquiries or Schedule
/// features: those screens are removed from the mobile Provider workspace, and
/// coupling their fetch into this bundle is what made the Agent Home fail
/// whenever the inbox leg failed while the authorized listings had loaded fine.
/// Every figure here is derived from real listing records; an empty portfolio
/// renders the honest empty state, never an error, and no figure is ever
/// fabricated.
///
/// Refresh is `ref.refresh(providerDashboardProvider.future)` (pull-to-refresh
/// and post-drill-in reloads both use it).
class ProviderDashboardData {
  const ProviderDashboardData({
    required this.isAgent,
    required this.firstName,
    required this.listings,
    required this.tasks,
    this.agentTasks = const [],
  });

  /// Signed-in role lives in the workspace already; kept here so the screens
  /// never re-derive "which dashboard am I".
  final bool isAgent;

  /// First token of the verified profile name ('' when the profile carries
  /// none — the greeting then omits the name rather than inventing one).
  final String firstName;

  final List<ProviderListing> listings;

  /// Owner-only actionable items derived from REAL records (drafts to finish,
  /// rejections to review). Empty for an agent.
  final List<ProviderDashboardTask> tasks;

  /// The agent's assigned listings classified from the verification records.
  /// The Tasks tab renders this same list, so Home can never disagree with it.
  final List<ProviderAgentTask> agentTasks;

  // ── Derived figures (arithmetic over the loaded records) ─────────────────

  int get listingCount => listings.length;

  /// Approved AND actually live.
  int get publishedCount =>
      listings.where((l) => l.isPublished && l.stage == ProviderStage.approved).length;

  int get pendingCount =>
      listings.where((l) => l.stage == ProviderStage.pending).length;

  int get draftCount =>
      listings.where((l) => l.stage == ProviderStage.draft).length;

  int agentTaskCount(ProviderAgentTaskKind kind) =>
      agentTasks.where((task) => task.kind == kind).length;

  int get needsAttentionCount =>
      agentTaskCount(ProviderAgentTaskKind.needsAttention);

  int get awaitingReviewCount =>
      agentTaskCount(ProviderAgentTaskKind.awaitingReview);

  int get approvedCount => agentTaskCount(ProviderAgentTaskKind.completed);

  // ── Agent workflow figures (overview metrics) ────────────────────────────
  //
  // Every count is arithmetic over the enriched rows the backend returned —
  // the same rows the cards below render, so a metric can never disagree
  // with the list. When the backend request fails the whole provider fails
  // and the screen shows its retry card: no figure is ever rendered as a
  // fabricated zero.

  /// Assignments still awaiting this agent's accept / decline response.
  int get newRequestsCount =>
      listings.where((l) => l.isRequestPending).length;

  /// Assignments the backend reports as an ACTIVE inspection: accepted (or
  /// under correction) and not yet submitted or ready. A declined assignment
  /// is never counted, and a draft is only counted when the assignment
  /// workflow actually says it is active.
  int get inspectionsInProgressCount => listings
      .where((l) =>
          l.isInspectionActive &&
          !l.isSubmittedForReview &&
          l.submissionReady != true)
      .length;

  /// Submissions an administrator is currently reviewing (submitted
  /// assignments and properties in the pending / under-review states).
  int get pendingAdminReviewCount => listings
      .where((l) =>
          l.assignmentStatus == 'submitted' || l.isSubmittedForReview)
      .length;

  /// The three longest-standing items that need the agent to act, for Home.
  List<ProviderAgentTask> get attentionPreview => agentTasks
      .where((task) => task.kind == ProviderAgentTaskKind.needsAttention)
      .take(3)
      .toList();

  /// Cards for the properties strip, newest first.
  List<ProviderListing> get recentListings {
    final sorted = [...listings]..sort((a, b) => b.id.compareTo(a.id));
    return sorted.take(3).toList();
  }
}

/// One owner task row, pointing at an existing route — never at invented
/// data. Built only from records the server actually returned.
class ProviderDashboardTask {
  const ProviderDashboardTask({
    required this.icon,
    required this.title,
    required this.detail,
    required this.route,
    this.arguments,
  });

  final IconData icon;
  final String title;
  final String detail;
  final String route;
  final Object? arguments;
}

/// The three buckets the Agent task screen filters by. §3 of the workspace
/// has four categories; the fourth (approved properties) is a completed
/// record, not a task, so it lives in its own bucket and never counts as
/// work.
enum ProviderAgentTaskKind { needsAttention, awaitingReview, completed }

/// One agent task: a real assigned listing plus what the authoritative records
/// say still has to happen to it.
///
/// Every field is either a property of the listing or a value the backend read
/// out of `rental_properties` / `property_verification` / `verification_audit`.
/// There is no due date, appointment, or administrator note anywhere in here
/// because there is no record that would supply one.
class ProviderAgentTask {
  const ProviderAgentTask({
    required this.listing,
    required this.kind,
    required this.category,
    required this.instruction,
    required this.icon,
    required this.route,
    this.actionLabel,
    this.note,
    this.noteAt,
    this.responsibility,
  });

  final ProviderListing listing;
  final ProviderAgentTaskKind kind;

  /// What kind of record this is, in the workspace's own words.
  final String category;

  /// The response the records ask for, or why none is asked for.
  final String instruction;
  final IconData icon;

  /// The existing authorized screen that carries this record forward.
  final String route;

  /// null for a completed property: there is nothing left to do on it.
  final String? actionLabel;

  /// The administrator's recorded feedback, when there is one.
  final String? note;

  /// ISO-8601 date of that feedback, when the audit row carries it.
  final String? noteAt;

  /// Who owns the next step, as the backend derived it:
  /// `agent` | `owner` | `admin` | `system` | `none`. Null on payloads from
  /// before the workflow enrichment. A task owned by the property OWNER is
  /// never worded as agent work, and never offers an agent action button.
  final String? responsibility;

  Object get arguments => listing.id;

  /// The same task as a dashboard row, so Home and Tasks render one
  /// classification rather than two competing ones.
  ProviderDashboardTask get asDashboardTask => ProviderDashboardTask(
    icon: icon,
    title: category,
    detail: '${listing.displayTitle} · $instruction',
    route: route,
    arguments: listing.id,
  );
}

/// The listing the backend's `task_state` is missing for, read off the status
/// the row does carry — a payload from before the projection still cannot
/// produce a task the database does not support.
String _taskStateOf(ProviderListing listing) {
  final reported = listing.taskState;
  if (reported != null && reported.isNotEmpty) return reported;
  return switch (listing.stage) {
    ProviderStage.draft => 'draft',
    ProviderStage.rejected => 'corrections',
    ProviderStage.pending => 'awaiting_review',
    ProviderStage.approved => 'approved',
    ProviderStage.unknown => '',
  };
}

/// Derives the agent's task list from the assigned records.
///
/// Classification is WORKFLOW-first: when the enriched payload carries the
/// assignment's `workflow_status` (requested | accepted | needs_correction |
/// submitted | declined), the task comes from that status and the backend's
/// own next-action derivation — never from a re-implementation of the
/// readiness rules. Only a legacy payload without the workflow block falls
/// back to the verification-record classification below.
///
/// * a REQUESTED assignment asks the agent to accept or decline it;
/// * a DECLINED assignment is a closed record — no task is built;
/// * an ACTIVE inspection is classified by the backend's `next_action`, and
///   the responsibility travels with it: an owner-owned step (ownership
///   proof) is reported as waiting on the OWNER, never as agent work;
/// * a SUBMITTED assignment is tracked, never framed as incomplete, and is
///   locked — it offers a status view, not an edit;
/// * administrator feedback (corrections) outranks the workflow status;
/// * an approved listing is a completed record, not a task.
///
/// An unrecognised state produces nothing. Nothing here assigns work, sets a
/// deadline, or books a viewing: the only properties considered are the ones
/// the server assigned to this agent.
List<ProviderAgentTask> buildAgentTasks(List<ProviderListing> listings) {
  final tasks = <ProviderAgentTask>[];
  for (final listing in listings) {
    // A declined assignment is closed work — never a task.
    if (listing.isDeclined) continue;
    final workflow = listing.assignmentStatus;
    if (workflow != null && workflow.isNotEmpty) {
      final task = _workflowTask(listing, workflow);
      if (task != null) tasks.add(task);
      continue;
    }
    final state = _taskStateOf(listing);
    final missing = listing.missingRequiredFields;
    switch (state) {
      case 'draft':
        tasks.add(
          ProviderAgentTask(
            listing: listing,
            kind: ProviderAgentTaskKind.needsAttention,
            category: 'Draft property',
            instruction: missing.isEmpty
                ? 'Finish the draft and send it in for review.'
                : 'Missing ${missing.join(', ')} before this can be reviewed.',
            icon: Icons.edit_note_outlined,
            route: '/provider/property-detail',
            actionLabel: listing.canEdit ? 'Continue editing' : null,
          ),
        );
      case 'corrections':
        tasks.add(_correctionsTask(listing));
      case 'awaiting_review':
        tasks.add(_awaitingReviewTask(listing));
      case 'approved':
        tasks.add(_approvedTask(listing));
      default:
      // No recognised state — the record cannot be classified as work.
    }
  }
  return tasks;
}

/// Classifies one assignment from its authoritative workflow status plus the
/// backend's `next_action`. Returns null for a state the records do not turn
/// into work.
ProviderAgentTask? _workflowTask(ProviderListing listing, String workflow) {
  // Administrator feedback outranks everything: the records asked for a
  // response and that response is still outstanding.
  if (listing.taskState == 'corrections') return _correctionsTask(listing);

  switch (workflow) {
    case 'requested':
      return ProviderAgentTask(
        listing: listing,
        kind: ProviderAgentTaskKind.needsAttention,
        category: 'New assignment request',
        instruction:
            'This property was assigned to you. Review it and accept or '
            'decline the request before inspecting.',
        icon: Icons.mark_email_unread_outlined,
        route: '/provider/property-detail',
        actionLabel: 'Review request',
        responsibility: 'agent',
      );
    case 'accepted':
    case 'needs_correction':
    case 'submitted':
      if (workflow == 'submitted' || listing.isSubmittedForReview) {
        return _awaitingReviewTask(listing);
      }
      // Active inspection: the step comes from the backend's own next-action
      // derivation over the readiness records. Unknown steps produce a
      // generic tracked row, never an invented action.
      return switch (listing.nextAction) {
        'await_owner_proof' => ProviderAgentTask(
          listing: listing,
          kind: ProviderAgentTaskKind.needsAttention,
          category: 'Waiting for owner proof',
          instruction:
              listing.ownershipSubmissionStatus == null ||
                  listing.ownershipSubmissionStatus == 'not_submitted'
              ? 'The property owner still has to upload readable ownership '
                    'proof and submit it for verification.'
              : 'The ownership proof is uploaded but has not been submitted '
                    'for verification yet.',
          icon: Icons.verified_user_outlined,
          route: '/provider/property-detail',
          actionLabel: 'View status',
          responsibility: 'owner',
        ),
        'complete_details' => ProviderAgentTask(
          listing: listing,
          kind: ProviderAgentTaskKind.needsAttention,
          category: 'Complete property details',
          instruction: listing.missingRequiredFields.isEmpty
              ? 'Required property information is still missing.'
              : 'Missing ${listing.missingRequiredFields.join(', ')}.',
          icon: Icons.edit_note_outlined,
          route: '/provider/property-detail',
          actionLabel: 'Complete details',
          responsibility: 'agent',
        ),
        'continue_inspection' => ProviderAgentTask(
          listing: listing,
          kind: ProviderAgentTaskKind.needsAttention,
          category: 'Physical inspection in progress',
          instruction:
              '${listing.inspectionProgressDisplay}. Save the remaining '
              'on-site verification checks.',
          icon: Icons.fact_check_outlined,
          route: '/provider/property-detail',
          actionLabel: 'Continue inspection',
          responsibility: 'agent',
        ),
        'capture_panorama' => ProviderAgentTask(
          listing: listing,
          kind: ProviderAgentTaskKind.needsAttention,
          category: 'Capture 360° tour',
          instruction:
              'No server-confirmed 360° tour exists for this inspection yet. '
              'Capture and sync it through the Agent pipeline.',
          icon: Icons.threesixty_outlined,
          route: '/provider/property-detail',
          actionLabel: 'Capture panorama',
          responsibility: 'agent',
        ),
        'wait_enrichment' => ProviderAgentTask(
          listing: listing,
          kind: ProviderAgentTaskKind.needsAttention,
          category: 'Geospatial processing',
          instruction:
              'Location enrichment is still running. Wait for it to finish '
              'before submitting.',
          icon: Icons.autorenew_outlined,
          route: '/provider/property-detail',
          actionLabel: 'View status',
          responsibility: 'system',
        ),
        'submit_for_review' => ProviderAgentTask(
          listing: listing,
          kind: ProviderAgentTaskKind.needsAttention,
          category: 'Ready to submit',
          instruction:
              'All requirements are met. Submit the inspection for '
              'administrator review.',
          icon: Icons.send_outlined,
          route: '/provider/property-detail',
          actionLabel: 'Submit for review',
          responsibility: 'agent',
        ),
        _ => ProviderAgentTask(
          listing: listing,
          kind: ProviderAgentTaskKind.needsAttention,
          category: 'Inspection in progress',
          instruction: listing.submissionBlockers.isEmpty
              ? 'The inspection is open; the next step was not reported by '
                    'the backend.'
              : 'Before submitting: ${listing.submissionBlockers.join(' ')}',
          icon: Icons.fact_check_outlined,
          route: '/provider/property-detail',
          actionLabel: 'View status',
          responsibility: listing.nextActionOwner,
        ),
      };
    default:
      // requested/declined handled above; an unrecognised workflow produces
      // nothing rather than a guessed task.
      return null;
  }
}

ProviderAgentTask _correctionsTask(ProviderListing listing) => ProviderAgentTask(
  listing: listing,
  kind: ProviderAgentTaskKind.needsAttention,
  category: 'Corrections requested',
  instruction: _correctionInstruction(listing),
  icon: Icons.error_outline_rounded,
  route: '/provider/property-detail',
  // A listing locked for review cannot be edited, whatever the
  // draft/rejected label on the card says.
  actionLabel: listing.canEdit ? 'Review corrections' : null,
  note: listing.correctionNote,
  noteAt: listing.correctionAt,
  responsibility: 'agent',
);

ProviderAgentTask _awaitingReviewTask(ProviderListing listing) =>
    ProviderAgentTask(
      listing: listing,
      kind: ProviderAgentTaskKind.awaitingReview,
      category: 'Awaiting administrator review',
      instruction: 'An administrator is reviewing this listing.',
      icon: Icons.hourglass_top_rounded,
      route: '/provider/property-detail',
      actionLabel: 'View status',
      noteAt: listing.submissionTimestamp,
      responsibility: 'admin',
    );

ProviderAgentTask _approvedTask(ProviderListing listing) => ProviderAgentTask(
  listing: listing,
  kind: ProviderAgentTaskKind.completed,
  category: 'Approved property',
  instruction: listing.isPublished
      ? 'Approved and live in the catalogue.'
      : 'Approved by an administrator; not published yet.',
  icon: Icons.task_alt_outlined,
  route: '/provider/property-detail',
  actionLabel: 'View status',
  responsibility: listing.isPublished ? 'none' : 'admin',
);

/// The response an administrator actually asked for, worded from the recorded
/// action rather than from a template.
String _correctionInstruction(ProviderListing listing) {
  final action = listing.correctionAction;
  if (action == 'listing_information_requested') {
    return 'More information requested by an administrator.';
  }
  if (action == 'listing_rejected') return 'Rejected by an administrator.';
  return 'An administrator asked for corrections to this listing.';
}

/// Derives the owner's task list from the loaded records.
///
/// Rules (each maps to an existing destination):
/// * a DRAFT with no reported photos → "Upload property photos" → resume the
///   Add-Property wizard for that draft;
/// * any other DRAFT → "Complete listing information" → same wizard;
/// * a REJECTED listing → "Review rejection feedback" → the listing's detail.
///
/// Everything is capped so a large portfolio cannot bury the signal, and
/// unknown states produce nothing (an unrecognised status is not a task).
List<ProviderDashboardTask> buildOwnerTasks(List<ProviderListing> listings) {
  final tasks = <ProviderDashboardTask>[];
  var drafts = 0;
  var rejected = 0;
  for (final listing in listings) {
    final stage = listing.stage;
    if (stage == ProviderStage.draft && drafts < 2) {
      drafts++;
      final photosKnown = listing.photoCount != null;
      final needsPhotos = !photosKnown || listing.photoCount! == 0;
      tasks.add(
        ProviderDashboardTask(
          icon: needsPhotos
              ? Icons.photo_camera_outlined
              : Icons.edit_note_outlined,
          title: needsPhotos
              ? 'Upload property photos'
              : 'Complete listing information',
          detail: '${listing.displayTitle} · Draft',
          route: '/provider/add-property',
          arguments: listing.id,
        ),
      );
    } else if (stage == ProviderStage.rejected && rejected < 2) {
      rejected++;
      tasks.add(
        ProviderDashboardTask(
          icon: Icons.error_outline_rounded,
          title: 'Review rejection feedback',
          detail: '${listing.displayTitle} · Rejected',
          route: '/provider/property-detail',
          arguments: listing.id,
        ),
      );
    }
    if (drafts >= 2 && rejected >= 2) break;
  }
  return tasks.take(4).toList();
}

/// The dashboard view-model provider. Kept alive (not autoDispose) so switching
/// tabs does not refetch the workspace.
final providerDashboardProvider =
    FutureProvider<ProviderDashboardData>((ref) async {
  final user = ref.watch(authNotifierProvider.select((s) => s.user));
  if (user == null) {
    throw StateError('No verified session — the dashboard is signed-out view.');
  }

  final workspace = await ProviderListingsService.load(user.role);

  final name = user.name.trim();
  final isAgent = user.role == AppRole.agent;
  return ProviderDashboardData(
    isAgent: isAgent,
    firstName: name.isEmpty ? '' : name.split(RegExp(r'\s+')).first,
    listings: workspace.listings,
    tasks: isAgent ? const [] : buildOwnerTasks(workspace.listings),
    agentTasks: isAgent ? buildAgentTasks(workspace.listings) : const [],
  );
});
