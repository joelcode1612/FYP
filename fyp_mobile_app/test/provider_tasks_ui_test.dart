import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyp/presentation/mobile/provider/pages/provider_dashboard_controller.dart';
import 'package:fyp/presentation/mobile/provider/pages/provider_models.dart';
import 'package:fyp/presentation/mobile/provider/pages/provider_tasks_mobile_page.dart';
import 'package:shared_logic/shared_logic.dart';

/// Rendering guards for the Agent Tasks tab.
///
/// The screen owns no data: it renders the classified bundle the dashboard
/// uses. What is pinned here is the honesty of that rendering — every card is
/// a real assigned property with a real recorded state, an edit appears only
/// where the backend still permits one, a submission under review is tracked
/// rather than nagged, an approved property is a completed record, and an
/// empty queue says so instead of filling itself with invented work.
ProviderListing _listing({
  required int id,
  required String title,
  required String status,
  required String taskState,
  String address = 'Ipoh, Perak',
  bool isPublished = false,
  List<String> missing = const [],
  String? note,
  String? action,
  String? noteAt,
  String? submittedAt,
  bool? editable,
}) => ProviderListing(
  id: id,
  title: title,
  address: address,
  status: status,
  isPublished: isPublished,
  taskState: taskState,
  missingRequiredFields: missing,
  correctionNote: note,
  correctionAction: action,
  correctionAt: noteAt,
  submittedAt: submittedAt,
  backendEditable: editable,
);

ProviderDashboardData _bundle(List<ProviderListing> listings) =>
    ProviderDashboardData(
      isAgent: true,
      firstName: 'Joel',
      listings: listings,
      tasks: const [],
      agentTasks: buildAgentTasks(listings),
    );

final _agent = SitewiseUser(
  id: 'user-agent',
  name: 'Joel Lim',
  email: 'agent@sitewise.my',
  role: AppRole.agent,
  status: 'active',
  location: 'Kuala Lumpur',
  joinedAt: DateTime(2026, 1, 1),
);

Widget _host(ProviderDashboardData? data) => ProviderScope(
  overrides: [
    authNotifierProvider.overrideWith(
      () =>
          _FixedAuth(AuthState(status: AuthStatus.authenticated, user: _agent)),
    ),
    if (data == null)
      providerDashboardProvider.overrideWith(
        (ref) async => throw StateError('assignment service unavailable'),
      )
    else
      providerDashboardProvider.overrideWith((ref) async => data),
  ],
  child: MaterialApp(
    // The tab host wraps every provider page in its own Scaffold; the ink on
    // a filter pill needs that Material ancestor here too.
    home: const Scaffold(body: ProviderTasksMobilePage()),
  ),
);

class _FixedAuth extends AuthNotifier {
  _FixedAuth(this._state);
  final AuthState _state;

  @override
  AuthState build() => _state;

  @override
  Future<void> start() async {}

  @override
  Future<void> retry() async {}
}

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isNotEmpty) return;
  await tester.scrollUntilVisible(
    finder,
    220,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  final queue = [
    _listing(
      id: 9234,
      title: 'taman DESA JARUM',
      status: 'draft',
      taskState: 'draft',
      address: '84900, Perak',
      missing: const ['availability'],
      editable: true,
    ),
    _listing(
      id: 9235,
      title: 'Sri Petaling Corner Shop',
      status: 'rejected',
      taskState: 'corrections',
      address: 'Kuala Lumpur',
      note: 'The floor area does not match the tenancy agreement.',
      action: 'listing_rejected',
      noteAt: '2026-10-04T09:12:00+00:00',
      editable: true,
    ),
    _listing(
      id: 9236,
      title: 'Bayan Baru Food Court Unit',
      status: 'pending',
      taskState: 'awaiting_review',
      address: 'Penang',
      submittedAt: '2026-11-01T08:00:00',
      editable: false,
    ),
    _listing(
      id: 9237,
      title: 'Tasek Utara Coffee House',
      status: 'approved',
      taskState: 'approved',
      address: 'Johor Bahru, Johor',
      isPublished: true,
    ),
  ];

  testWidgets('the queue header, summary and filters come from the records', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_bundle(queue)));
    await tester.pumpAndSettle();

    expect(find.text('Property tasks'), findsOneWidget);
    expect(
      find.text('Keep your assigned properties ready for review.'),
      findsOneWidget,
    );

    // The chips carry the same arithmetic the summary tiles show, so a count
    // and a filter can never disagree.
    expect(find.text('All (4)'), findsOneWidget);
    expect(find.text('Needs attention (2)'), findsOneWidget);
    expect(find.text('Awaiting review (1)'), findsOneWidget);
    expect(find.text('Approved (1)'), findsOneWidget);

    await _scrollTo(tester, find.text('Needs attention (2)'));
    expect(find.text('Needs attention'), findsWidgets);
    expect(find.text('taman DESA JARUM'), findsOneWidget);
    expect(find.text('84900, Perak'), findsOneWidget);
    expect(find.text('Draft property'), findsOneWidget);
    expect(
      find.textContaining('Missing availability before this can be reviewed'),
      findsOneWidget,
    );
    expect(find.text('Continue editing'), findsOneWidget);
  });

  testWidgets('administrator feedback is quoted, and its date is formatted', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_bundle(queue)));
    await tester.pumpAndSettle();

    await _scrollTo(
      tester,
      find.text('The floor area does not match the tenancy agreement.'),
    );
    expect(find.text('Corrections requested'), findsOneWidget);
    expect(
      find.text('The floor area does not match the tenancy agreement.'),
      findsOneWidget,
    );
    expect(find.text('Administrator feedback · 4 Oct 2026'), findsOneWidget);
    expect(find.text('Review corrections'), findsOneWidget);
  });

  testWidgets(
    'a submission under review is tracked, never offered as an edit',
    (tester) async {
      await tester.pumpWidget(_host(_bundle(queue)));
      await tester.pumpAndSettle();

      await _scrollTo(tester, find.text('Bayan Baru Food Court Unit'));
      expect(find.text('Bayan Baru Food Court Unit'), findsOneWidget);
      expect(find.text('Awaiting administrator review'), findsWidgets);
      expect(find.text('Submitted 1 Nov 2026'), findsOneWidget);
      expect(
        find.text('An administrator is reviewing this listing.'),
        findsOneWidget,
      );
      // The approved card below offers the same status view, and a ListView
      // may or may not have built it yet, so this pins presence, not a count.
      expect(find.text('View status'), findsWidgets);
      // §3: it must not read as incomplete work.
      expect(
        find.text('Editing is closed for this verification state.'),
        findsNothing,
      );
    },
  );

  testWidgets('an approved property is a completed record, not a task', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_bundle(queue)));
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('Completed'));
    expect(find.text('Approved property'), findsOneWidget);
    expect(find.text('Approved and live in the catalogue.'), findsOneWidget);
    expect(find.text('Tasek Utara Coffee House'), findsOneWidget);
  });

  testWidgets('a record the backend has locked shows no edit action', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        _bundle([
          _listing(
            id: 500,
            title: 'Locked Draft Unit',
            status: 'draft',
            taskState: 'draft',
            editable: false,
          ),
        ]),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Continue editing'), findsNothing);
    expect(
      find.text('Editing is closed for this verification state.'),
      findsOneWidget,
    );
  });

  testWidgets('filters narrow the queue to the selected state', (tester) async {
    await tester.pumpWidget(_host(_bundle(queue)));
    await tester.pumpAndSettle();

    final approvedChip = find.text('Approved (1)');
    await tester.ensureVisible(approvedChip);
    await tester.tap(approvedChip);
    await tester.pumpAndSettle();

    expect(find.text('Approved property'), findsOneWidget);
    expect(find.text('Draft property'), findsNothing);
    expect(find.text('Corrections requested'), findsNothing);
    expect(find.text('Awaiting administrator review'), findsNothing);
  });

  testWidgets('an actionable-emptied filter says caught up in plain words', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        _bundle([
          _listing(
            id: 600,
            title: 'Quiet Row House',
            status: 'approved',
            taskState: 'approved',
            isPublished: true,
          ),
        ]),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text("You're all caught up"), findsOneWidget);
    expect(
      find.text('No assigned properties need action right now.'),
      findsOneWidget,
    );
    // And nothing is invented to fill the space.
    expect(find.text('Draft property'), findsNothing);
    expect(find.textContaining('due'), findsNothing);
  });

  testWidgets('no assignments at all is reported as such', (tester) async {
    await tester.pumpWidget(_host(_bundle(const [])));
    await tester.pumpAndSettle();

    expect(find.text('No assigned properties yet'), findsOneWidget);
    expect(find.text('All (0)'), findsNothing);
  });

  testWidgets('a read failure offers a retry and fabricates nothing', (
    tester,
  ) async {
    await tester.pumpWidget(_host(null));
    await tester.pumpAndSettle();

    expect(find.text('Your tasks could not be loaded'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Property tasks'), findsNothing);
  });

  testWidgets('the screen carries no enquiry or appointment surface', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_bundle(queue)));
    await tester.pumpAndSettle();

    for (final absent in [
      'Enquiries',
      'Schedule',
      'Viewings',
      'New viewing appointment',
      'Due today',
    ]) {
      expect(
        find.text(absent),
        findsNothing,
        reason: '$absent must not appear',
      );
    }
  });
}
