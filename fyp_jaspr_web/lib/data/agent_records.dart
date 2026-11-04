import 'package:shared_logic/shared_logic.dart';

import 'app_locator.dart';

/// The data behind the Agent Dashboard.
///
/// ## What is real and what is not
///
/// The **properties are real** — they come from the same authenticated catalog
/// the entrepreneur workspace reads, so prices, floor areas and locations are
/// the imported dataset, not invented numbers.
///
/// The **assignment is not**. There is no agent table and no
/// `property_assignments` column anywhere in the schema, so which catalog rows
/// "belong" to this agent is chosen here by suitability rank. Every screen that
/// consumes this file has to label that as a demonstration; the brief forbids
/// implying that agent assignments are enforced when nothing server-side knows
/// what an agent is.
abstract final class AgentRecords {
  /// Identifier an administrator would issue. Display only — no such column
  /// exists, and no agent account can sign in until `profiles.role` accepts
  /// `'agent'`.
  static const String agentId = 'AGT-DEMO-01';
  static const String agentName = 'Agent Aina';
  static const String agentAgency = 'Selangor Commercial';

  /// How many catalog rows stand in for "assigned to this agent".
  static const int assignmentCount = 6;

  /// Deterministic stand-in for the assignment table: the top-ranked units by
  /// the imported suitability index.
  ///
  /// Sorted rather than randomised so two reloads show the same portfolio — a
  /// demo that reshuffles every refresh reads like a bug.
  static Future<List<CommercialProperty>> assignedProperties() async {
    final listings = [...await AppLocator.properties.listings()];
    listings.sort((a, b) => b.suitabilityScore.compareTo(a.suitabilityScore));
    return listings.take(assignmentCount).toList();
  }

  /// The agent-facing name for an existing [VerificationStatus].
  ///
  /// Mapping note: the design reference borrows PropertyGuru's tabs (Active /
  /// Draft / Past / Suspended). Three of the four map onto values Sitewise
  /// already stores; "Past" has no counterpart, so it is not offered rather
  /// than smuggled in as a new enum value.
  static String listingLabel(VerificationStatus status) => switch (status) {
    VerificationStatus.verified => 'Active',
    VerificationStatus.pending => 'Pending review',
    VerificationStatus.draft => 'Draft',
    VerificationStatus.rejected => 'Suspended',
  };

  static String listingTone(VerificationStatus status) => switch (status) {
    VerificationStatus.verified => 'success',
    VerificationStatus.pending => 'warning',
    VerificationStatus.draft => 'neutral',
    VerificationStatus.rejected => 'danger',
  };

  /// Owner column text.
  ///
  /// The imported dataset carries no ownership relation and
  /// `ApiPropertyRepository.fromJson` leaves `ownerId` empty, so the truthful
  /// answer is "not recorded" — inventing a landlord name here would be the
  /// exact fake-data claim the brief prohibits.
  /// Terse because the portfolio table repeats it on every row; the property
  /// page spells out what the missing reference means.
  static String ownerLabel(CommercialProperty property) =>
      property.ownerId.isEmpty
      ? 'Owner not recorded'
      : 'Owner ${property.ownerId}';
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
