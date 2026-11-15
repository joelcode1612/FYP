import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import 'provider_models.dart';
import 'provider_workspace_service.dart';

/// UI-ready bundle for the Owner / Agent dashboard — the Riverpod view-model
/// layer the dashboard screens render from.
///
/// Composition (all reads are the caller's OWN authorized scope; nothing here
/// filters or estimates client-side):
///
/// * `ProviderListingsService.load(role)` — listings for the signed-in role
///   (owner rows via `owner_user_id`, agent rows via assignment). A failure
///   here fails the whole dashboard: the MFA gate / retry card must show.
/// * `ProviderWorkspaceService.enquiries()` — the real inbox + status counts.
///   Also fatal: New Leads / Messages figures are built from it.
/// * `ProviderWorkspaceService.performance()` — **best effort**. A failure is
///   not a dashboard failure; the weekly-performance card renders its honest
///   unavailable state instead.
///
/// Refresh is `ref.refresh(providerDashboardProvider.future)` (pull-to-refresh
/// and post-drill-in reloads both use it).
class ProviderDashboardData {
  const ProviderDashboardData({
    required this.isAgent,
    required this.firstName,
    required this.listings,
    required this.enquiryMetrics,
    required this.recentEnquiries,
    required this.tasks,
    this.performance,
  });

  /// Signed-in role lives in the workspace already; kept here so the screens
  /// never re-derive "which dashboard am I".
  final bool isAgent;

  /// First token of the verified profile name ('' when the profile carries
  /// none — the greeting then omits the name rather than inventing one).
  final String firstName;

  final List<ProviderListing> listings;

  /// Server counts over the caller's own enquiries (total + per status).
  final ProviderEnquiryMetrics enquiryMetrics;

  /// Newest inbox rows in server order — Recent leads (agent) and the
  /// respond-to-enquiry tasks (owner) render these.
  final List<ProviderEnquiry> recentEnquiries;

  /// Owner-only actionable items derived from REAL records (drafts to finish,
  /// rejections to review, enquiries to answer). Empty for an agent — the
  /// agent dock has no tasks section.
  final List<ProviderDashboardTask> tasks;

  /// Null when the performance report failed — rendered as "unavailable",
  /// never as zero.
  final ProviderPerformance? performance;

  // ── Derived figures (arithmetic over the loaded records) ─────────────────

  int get listingCount => listings.length;

  /// Approved AND actually live.
  int get publishedCount =>
      listings.where((l) => l.isPublished && l.stage == ProviderStage.approved).length;

  int get pendingCount =>
      listings.where((l) => l.stage == ProviderStage.pending).length;

  /// Enquiries that arrived and are still unanswered.
  int get newEnquiryCount => enquiryMetrics.count(ProviderEnquiryStatus.incoming);

  /// Replied share of all received enquiries, as a whole percentage — honest
  /// arithmetic over real statuses, or null when there is nothing to divide
  /// (the screen then shows the honest unavailable state).
  int? get responseRatePercent {
    final total = enquiryMetrics.total;
    if (total <= 0) return null;
    final replied = enquiryMetrics.count(ProviderEnquiryStatus.replied);
    return ((replied / total) * 100).round();
  }

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

/// Derives the owner's task list from the loaded records.
///
/// Rules (each maps to an existing destination):
/// * a DRAFT with no reported photos → "Upload property photos" → resume the
///   Add-Property wizard for that draft;
/// * any other DRAFT → "Complete listing information" → same wizard;
/// * a REJECTED listing → "Review rejection feedback" → the listing's detail;
/// * a NEW enquiry → "Respond to new enquiry" → the Messages inbox.
///
/// Everything is capped so a large portfolio cannot bury the inbox signal,
/// and unknown states produce nothing (an unrecognised status is not a task).
List<ProviderDashboardTask> buildOwnerTasks(
  List<ProviderListing> listings,
  List<ProviderEnquiry> enquiries,
) {
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
  var enquiriesUsed = 0;
  for (final enquiry in enquiries) {
    if (enquiriesUsed >= 2) break;
    if (enquiry.status != ProviderEnquiryStatus.incoming) continue;
    enquiriesUsed++;
    tasks.add(
      ProviderDashboardTask(
        icon: Icons.mail_outline_rounded,
        title: 'Respond to new enquiry',
        detail:
            '${enquiry.propertyTitle.isEmpty ? 'Listing L-${enquiry.propertyId}' : enquiry.propertyTitle}'
            ' · Received ${enquiry.receivedDisplay}',
        route: '/provider/enquiries',
      ),
    );
  }
  return tasks.take(4).toList();
}

/// The dashboard view-model provider. Kept alive (not autoDispose) so the
/// shell's unread badge survives switching tabs without refetching.
final providerDashboardProvider =
    FutureProvider<ProviderDashboardData>((ref) async {
  final user = ref.watch(authNotifierProvider.select((s) => s.user));
  if (user == null) {
    throw StateError('No verified session — the dashboard is signed-out view.');
  }

  final results = await Future.wait(<Future<Object?>>[
    ProviderListingsService.load(user.role),
    ProviderWorkspaceService.enquiries(),
  ]);
  final workspace = results[0]! as ProviderWorkspace;
  final inbox =
      results[1]! as ({List<ProviderEnquiry> enquiries, ProviderEnquiryMetrics metrics});

  // Best effort: a failed report only blanks the weekly-performance card.
  ProviderPerformance? performance;
  try {
    performance = await ProviderWorkspaceService.performance();
  } catch (_) {
    performance = null;
  }

  final name = user.name.trim();
  return ProviderDashboardData(
    isAgent: user.role == AppRole.agent,
    firstName: name.isEmpty ? '' : name.split(RegExp(r'\s+')).first,
    listings: workspace.listings,
    enquiryMetrics: inbox.metrics,
    recentEnquiries: inbox.enquiries.take(3).toList(),
    tasks: user.role == AppRole.agent
        ? const []
        : buildOwnerTasks(workspace.listings, inbox.enquiries),
    performance: performance,
  );
});
