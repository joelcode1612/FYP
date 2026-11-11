import 'package:shared_logic/shared_logic.dart';

import 'app_locator.dart';

/// The data behind the Agent workspace.
///
/// ## One authoritative assignment dataset
///
/// Every assigned-listing surface (dashboard KPIs and portfolio, Assigned
/// Listings, performance, the notification bell) reads the SAME authorized
/// source: `GET /api/v1/staff/me/listings` resolves the authenticated
/// agent's Supabase profile from the verified bearer token, then returns the
/// rows of the local `agent_listing_assignment` table. Each row's
/// `listing_id` is a real FOREIGN KEY to `fyp.rental_properties(id)` — the
/// backend joins the operational property fields in the same query, so a
/// "listing" can never be a catalogue stand-in and ids can never diverge
/// between id systems.
///
/// An empty result is a truthful empty portfolio: no assignments exist, and
/// nothing is substituted. The former suitability-rank demonstration
/// selection (`assignedProperties()`) has been removed entirely.
abstract final class AgentRecords {
  /// The listings GENUINELY assigned to the authenticated agent — one
  /// enriched query, authorization enforced server-side on every call.
  static Future<List<AgentAssignment>> assignedListings() =>
      AppLocator.agentListingRepo.assignedListings();

  /// The agent-facing label for an operational listing's wire
  /// `verification_status` (`draft | pending | approved | rejected`;
  /// `under_review` can also surface while an administrator works a queue).
  ///
  /// "Active" means the listing PASSED administrator review (`approved`).
  /// Publication (`is_published`) is a separate flag — approved is never
  /// reported as published, and published is never inferred from approval.
  static String wireStatusLabel(String? wire) => switch (wire) {
    'approved' || 'verified' => 'Active',
    'pending' => 'Pending review',
    'under_review' => 'Under review',
    'draft' => 'Draft',
    'rejected' => 'Rejected',
    _ => 'Unknown state',
  };

  static String wireStatusTone(String? wire) => switch (wire) {
    'approved' || 'verified' => 'success',
    'pending' => 'warning',
    'under_review' => 'action',
    'draft' => 'neutral',
    'rejected' => 'danger',
    _ => 'neutral',
  };

  /// Display helpers over the enriched assignment row the backend returns
  /// (`AgentAssignmentRepository._LIST_SELECT`). Absent fields render as
  /// explicit "not provided/recorded" states, never as invented values.
  static String rentDisplay(AgentAssignment assignment) {
    final price = assignment.raw['rental_price'];
    return price is num ? 'RM ${price.round()}' : 'Not provided';
  }

  static String locationDisplay(AgentAssignment assignment) {
    final parts = [
      assignment.raw['city'],
      assignment.raw['state'],
    ]
        .whereType<String>()
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
    return parts.isEmpty ? 'Location not recorded' : parts.join(', ');
  }

  static String typeDisplay(AgentAssignment assignment) {
    final value = assignment.raw['property_type'];
    return value is String && value.trim().isNotEmpty
        ? value.trim()
        : 'Not provided';
  }

  static String? wireStatus(AgentAssignment assignment) =>
      assignment.raw['verification_status']?.toString();

  /// `false` when the backend reports the assignment's operational property
  /// row as missing (`property_exists: false`) — such a row is shown as a
  /// data-integrity problem, never as a normal listing.
  static bool propertyExists(AgentAssignment assignment) =>
      assignment.raw['property_exists'] != false;
}

/// A property enquiry.
///
/// **No backing exists.** There is no `enquiries` table, no contact-button
/// event and no endpoint that could store one. These rows are prototype
/// content, kept to the five fields the brief lists so the screen reads as a
/// proposed extension rather than a customer-relationship system.
typedef AgentEnquiry = ({
  String id,
  String enquirer,
  String contact,
  String property,
  String received,
  String status,
});

const List<AgentEnquiry> demoEnquiries = [
  (
    id: 'ENQ-01',
    enquirer: 'Café operator, SS2',
    contact: 'via listing contact button',
    property: 'SS2 Corner Retail Lot',
    received: 'This week',
    status: 'New',
  ),
  (
    id: 'ENQ-02',
    enquirer: 'Bakery group, Damansara',
    contact: 'via listing contact button',
    property: 'Damansara Uptown Shoplot',
    received: 'This week',
    status: 'Follow up',
  ),
  (
    id: 'ENQ-03',
    enquirer: 'Bubble tea franchise',
    contact: 'via listing contact button',
    property: 'Subang Commercial Unit',
    received: 'Earlier',
    status: 'Closed',
  ),
];

/// A pending agent task.
///
/// Also **no backing** — nothing in the domain layer models work items. Shown
/// because the brief's Section D asks for it, and clearly marked.
typedef AgentTask = ({String title, String detail, String status, bool done});

List<AgentTask> demoTasks({int completed = 0}) => [
  (
    title: 'Confirm listing availability',
    detail: 'Availability is not a stored field yet',
    status: completed > 0 ? 'Complete' : 'Pending',
    done: completed > 0,
  ),
  (
    title: 'Review property media',
    detail: 'No photo table is connected to the catalog',
    status: 'Pending',
    done: false,
  ),
  (
    title: 'Answer 1 enquiry',
    detail: 'Enquiry storage is a proposed extension',
    status: 'Pending',
    done: false,
  ),
];
