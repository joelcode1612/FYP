import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import 'provider_models.dart';

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
/// Four categories, straight from the authoritative state of each listing:
/// * a DRAFT is work: the details an administrator would refuse it for are
///   listed exactly as the submission gate words them;
/// * a REJECTED / more-information-requested listing is work, and carries the
///   staff reason that was actually recorded against it;
/// * a listing awaiting review is tracked, never framed as incomplete, and is
///   locked — so it offers a status view, not an edit;
/// * an approved listing is a completed record, not a task.
///
/// An unrecognised state produces nothing. Nothing here assigns work, sets a
/// deadline, or books a viewing: the only properties considered are the ones
/// the server assigned to this agent.
List<ProviderAgentTask> buildAgentTasks(List<ProviderListing> listings) {
  final tasks = <ProviderAgentTask>[];
  for (final listing in listings) {
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
        tasks.add(
          ProviderAgentTask(
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
          ),
        );
      case 'awaiting_review':
        tasks.add(
          ProviderAgentTask(
            listing: listing,
            kind: ProviderAgentTaskKind.awaitingReview,
            category: 'Awaiting administrator review',
            instruction: 'An administrator is reviewing this listing.',
            icon: Icons.hourglass_top_rounded,
            route: '/provider/property-detail',
            actionLabel: 'View status',
            noteAt: listing.submittedAt,
          ),
        );
      case 'approved':
        tasks.add(
          ProviderAgentTask(
            listing: listing,
            kind: ProviderAgentTaskKind.completed,
            category: 'Approved property',
            instruction: listing.isPublished
                ? 'Approved and live in the catalogue.'
                : 'Approved by an administrator; not published yet.',
            icon: Icons.task_alt_outlined,
            route: '/provider/property-detail',
            actionLabel: 'View status',
          ),
        );
      default:
      // No recognised state — the record cannot be classified as work.
    }
  }
  return tasks;
}

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
