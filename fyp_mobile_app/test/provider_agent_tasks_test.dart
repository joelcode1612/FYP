import 'package:flutter_test/flutter_test.dart';
import 'package:fyp/presentation/mobile/provider/pages/provider_dashboard_controller.dart';
import 'package:fyp/presentation/mobile/provider/pages/provider_models.dart';

/// The Agent task queue reads its categories from the authoritative records the
/// backend joins (`verification_status`, `property_verification`,
/// `verification_audit`). These tests pin the classification to those fields:
/// a task exists only when a record says so, an edit is offered only when the
/// backend permits it, and an approved property never becomes work.
ProviderListing _listing({
  required int id,
  required String status,
  String? taskState,
  List<String> missing = const [],
  String? correctionNote,
  String? correctionAction,
  String? correctionAt,
  String? submittedAt,
  bool? backendEditable,
  bool isPublished = false,
}) => ProviderListing(
  id: id,
  title: 'Shophouse $id',
  address: 'Jalan Tun Razak, Kuala Lumpur, WP',
  status: status,
  isPublished: isPublished,
  taskState: taskState,
  missingRequiredFields: missing,
  correctionNote: correctionNote,
  correctionAction: correctionAction,
  correctionAt: correctionAt,
  submittedAt: submittedAt,
  backendEditable: backendEditable,
);

ProviderDashboardData _data(List<ProviderListing> listings) =>
    ProviderDashboardData(
      isAgent: true,
      firstName: 'Aiman',
      listings: listings,
      tasks: const [],
      agentTasks: buildAgentTasks(listings),
    );

void main() {
  group('buildAgentTasks', () {
    test('a draft is work, and names what the submission gate still needs', () {
      final task = buildAgentTasks([
        _listing(
          id: 9234,
          status: 'draft',
          taskState: 'draft',
          missing: const ['availability'],
          backendEditable: true,
        ),
      ]).single;

      expect(task.kind, ProviderAgentTaskKind.needsAttention);
      expect(task.category, 'Draft property');
      expect(task.instruction, contains('availability'));
      expect(task.actionLabel, 'Continue editing');
      expect(task.note, isNull);
      expect(task.noteAt, isNull);
    });

    test('a draft with nothing missing is still a draft, without a invented gap', () {
      final task = buildAgentTasks([
        _listing(id: 1, status: 'draft', taskState: 'draft'),
      ]).single;
      expect(task.instruction, isNot(contains('Missing')));
    });

    test('an edit is never offered when the backend has locked the record', () {
      final locked = buildAgentTasks([
        _listing(
          id: 2,
          status: 'draft',
          taskState: 'draft',
          backendEditable: false,
        ),
      ]).single;
      expect(locked.actionLabel, isNull);
      expect(locked.kind, ProviderAgentTaskKind.needsAttention);
    });

    test('corrections carry the administrator feedback that was recorded', () {
      final task = buildAgentTasks([
        _listing(
          id: 3,
          status: 'rejected',
          taskState: 'corrections',
          correctionNote: 'The floor area does not match the tenancy agreement.',
          correctionAction: 'listing_rejected',
          correctionAt: '2026-10-04T09:12:00+00:00',
          backendEditable: true,
        ),
      ]).single;

      expect(task.kind, ProviderAgentTaskKind.needsAttention);
      expect(task.category, 'Corrections requested');
      expect(task.note, 'The floor area does not match the tenancy agreement.');
      expect(task.instruction, 'Rejected by an administrator.');
      expect(task.actionLabel, 'Review corrections');
    });

    test('a request for more information is worded as what it is', () {
      final task = buildAgentTasks([
        _listing(
          id: 4,
          status: 'rejected',
          taskState: 'corrections',
          correctionAction: 'listing_information_requested',
        ),
      ]).single;
      expect(task.instruction, 'More information requested by an administrator.');
      // No audit reason on the record, so the card has nothing to quote.
      expect(task.note, isNull);
    });

    test('a submitted listing is tracked, never presented as incomplete', () {
      final task = buildAgentTasks([
        _listing(
          id: 5,
          status: 'pending',
          taskState: 'awaiting_review',
          submittedAt: '2026-11-01T08:00:00',
        ),
      ]).single;

      expect(task.kind, ProviderAgentTaskKind.awaitingReview);
      expect(task.category, 'Awaiting administrator review');
      expect(task.actionLabel, 'View status');
      expect(task.noteAt, '2026-11-01T08:00:00');
    });

    test('a submission with no recorded date shows no date', () {
      final task = buildAgentTasks([
        _listing(id: 6, status: 'pending', taskState: 'awaiting_review'),
      ]).single;
      expect(task.noteAt, isNull);
    });

    test('an approved property is a completed record, not a task', () {
      final task = buildAgentTasks([
        _listing(
          id: 7,
          status: 'approved',
          taskState: 'approved',
          isPublished: true,
        ),
      ]).single;
      expect(task.kind, ProviderAgentTaskKind.completed);
      expect(task.instruction, 'Approved and live in the catalogue.');
    });

    test('an unrecognised status produces nothing', () {
      expect(
        buildAgentTasks([_listing(id: 8, status: 'under_review_extra')]),
        isEmpty,
      );
    });

    test('a payload without the projection still classifies off its status', () {
      final tasks = buildAgentTasks([
        _listing(id: 9, status: 'draft'),
        _listing(id: 10, status: 'pending'),
      ]);
      expect(
        tasks.map((task) => task.kind),
        [
          ProviderAgentTaskKind.needsAttention,
          ProviderAgentTaskKind.awaitingReview,
        ],
      );
      // The mirrored lock policy only stands in where the server said nothing.
      expect(tasks[1].actionLabel, 'View status');
      expect(tasks[0].actionLabel, 'Continue editing');
    });

    test('every task points at the existing listing screen', () {
      for (final task in buildAgentTasks([
        _listing(id: 11, status: 'draft', taskState: 'draft'),
        _listing(id: 12, status: 'pending', taskState: 'awaiting_review'),
        _listing(id: 13, status: 'approved', taskState: 'approved'),
      ])) {
        expect(task.route, '/provider/property-detail');
        expect(task.arguments, task.listing.id);
      }
    });
  });

  group('dashboard bundle', () {
    final mixed = [
      _listing(id: 20, status: 'draft', taskState: 'draft'),
      _listing(id: 21, status: 'rejected', taskState: 'corrections'),
      _listing(id: 22, status: 'pending', taskState: 'awaiting_review'),
      _listing(id: 23, status: 'approved', taskState: 'approved'),
    ];

    test('the counts are arithmetic over the same classified list', () {
      final data = _data(mixed);
      expect(data.needsAttentionCount, 2);
      expect(data.awaitingReviewCount, 1);
      expect(data.approvedCount, 1);
    });

    test('Home previews at most three actionable tasks', () {
      final many = [
        for (var id = 30; id < 36; id++)
          _listing(id: id, status: 'draft', taskState: 'draft'),
      ];
      final data = _data(many);
      expect(data.needsAttentionCount, 6);
      expect(data.attentionPreview, hasLength(3));
    });

    test('an agent with nothing actionable has an honest empty preview', () {
      final data = _data([
        _listing(id: 40, status: 'approved', taskState: 'approved'),
      ]);
      expect(data.needsAttentionCount, 0);
      expect(data.attentionPreview, isEmpty);
    });

    test('a preview row keeps the property and the route the tab uses', () {
      final row = _data(mixed).attentionPreview.first.asDashboardTask;
      expect(row.title, 'Draft property');
      expect(row.detail, contains('Shophouse 20'));
      expect(row.route, '/provider/property-detail');
      expect(row.arguments, 20);
    });
  });
}
