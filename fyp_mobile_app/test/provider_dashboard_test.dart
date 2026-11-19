import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyp/presentation/mobile/provider/pages/provider_dashboard_controller.dart';
import 'package:fyp/presentation/mobile/provider/pages/provider_dashboard_mobile_page.dart';
import 'package:fyp/presentation/mobile/provider/pages/provider_models.dart';
import 'package:shared_logic/shared_logic.dart';

/// Rendering guards for the Owner / Agent dashboards.
///
/// The dashboards are role-scoped presentations over the SAME authorized
/// records. What is pinned here:
///
/// * the Agent layout — greeting with the real profile name, overview metrics
///   from the authorized listing rows (including the HONEST '—' for viewings
///   SiteWise never records), and assigned-property cards;
/// * the Owner layout — portfolio metrics, "Tasks to do" derived from real
///   drafts and rejections, Manage buttons;
/// * the absence of the removed Enquiries / Schedule surfaces — no lead rows,
///   no schedule section, no enquiry metric, no Messages action;
/// * the loading and error surfaces keep their retry affordances.
///
/// No network: [providerDashboardProvider] is overridden with a fixed bundle,
/// exactly like the backend fixture would answer.
void main() {
  final agentUser = _userFor(AppRole.agent, 'Joel Lim');
  final ownerUser = _userFor(AppRole.owner, 'Maria Tan');

  ProviderDashboardData agentBundle() => ProviderDashboardData(
    isAgent: true,
    firstName: 'Joel',
    listings: const [
      ProviderListing(
        id: 1755,
        title: 'Riverside Promenade – Unit 01',
        address: 'Kuala Lumpur, Federal Territory of Kuala Lumpur',
        status: 'approved',
        isPublished: true,
        rent: 12000,
        imageUrl: 'https://example.test/photo.jpg',
      ),
      ProviderListing(
        id: 1760,
        title: 'Maple Court – Unit B2-05',
        address: 'Penang, Pulau Pinang',
        status: 'pending',
        isPublished: false,
        rent: 9800,
      ),
    ],
    tasks: const [],
  );

  ProviderDashboardData ownerBundle() {
    final listings = [
      const ProviderListing(
        id: 1801,
        title: 'Riverside Promenade – Unit 01',
        address: 'Kuala Lumpur, Federal Territory of Kuala Lumpur',
        status: 'approved',
        isPublished: true,
        rent: 12000,
        imageUrl: 'https://example.test/photo.jpg',
        photoCount: 4,
      ),
      const ProviderListing(
        id: 1802,
        title: 'Maple Court – Unit B2-05',
        address: 'Penang, Pulau Pinang',
        status: 'pending',
        isPublished: false,
        rent: 9800,
        photoCount: 2,
      ),
      const ProviderListing(
        id: 1803,
        title: 'Orchard Central – Unit 03-02',
        address: 'Johor Bahru, Johor',
        status: 'draft',
        isPublished: false,
        rent: null,
        photoCount: 0,
      ),
    ];
    return ProviderDashboardData(
      isAgent: false,
      firstName: 'Maria',
      listings: listings,
      tasks: buildOwnerTasks(listings),
    );
  }

  Widget host({
    required SitewiseUser user,
    required ProviderDashboardData data,
  }) =>
      ProviderScope(
        overrides: [
          authNotifierProvider.overrideWith(
            () => _FixedAuthNotifier(
              AuthState(
                status: AuthStatus.authenticated,
                user: user,
              ),
            ),
          ),
          providerDashboardProvider.overrideWith((ref) async => data),
        ],
        child: const MaterialApp(home: ProviderDashboardMobilePage()),
      );

  testWidgets('the agent dashboard renders its sections with real figures', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(user: agentUser, data: agentBundle()),
    );
    await tester.pumpAndSettle();

    // Greeting uses the verified profile name, never a hard-coded one.
    expect(find.text('Welcome back, Joel'), findsOneWidget);
    expect(
      find.text(
        'Manage your assigned properties and their verification statuses.',
      ),
      findsOneWidget,
    );

    // Overview metrics from the authorized listing rows. Viewings are
    // honestly untracked.
    expect(find.text('Agent overview'), findsOneWidget);
    expect(find.text('Your agency activity at a glance.'), findsOneWidget);
    expect(find.text('2'), findsOneWidget); // assigned properties
    expect(find.text('1'), findsNWidgets(2)); // published + pending
    expect(find.text('—'), findsWidgets); // at least Viewings Today
    expect(find.text('Not tracked'), findsOneWidget);

    // Quick actions — no Enquiries, no Schedule.
    expect(find.text('Assigned Listings'), findsOneWidget);
    expect(find.text('Add Property'), findsOneWidget);
    expect(find.text('Performance'), findsOneWidget);
    expect(find.text('Enquiries'), findsNothing);
    expect(find.text('Schedule'), findsNothing);

    // The removed sections never render.
    expect(find.text("Today's schedule"), findsNothing);
    expect(find.text('No schedule yet'), findsNothing);
    expect(find.text('Recent leads'), findsNothing);
    expect(find.text('New Leads'), findsNothing);

    // Assigned property cards with the real record. (Section headers above
    // the scrolled target are not asserted — a ListView builds and lays out
    // lazily, so a header may sit just above the viewport edge while the
    // card it titles is centred.)
    await _scrollUntilVisible(tester, find.text('Riverside Promenade – Unit 01'));
    expect(find.text('Riverside Promenade – Unit 01'), findsOneWidget);
    expect(find.text('RM 12000 / month'), findsOneWidget);
    expect(find.text('Open'), findsWidgets);
  });

  testWidgets('the owner dashboard renders portfolio, tasks and properties', (
    tester,
  ) async {
    await tester.pumpWidget(host(user: ownerUser, data: ownerBundle()));
    await tester.pumpAndSettle();

    expect(find.text('Welcome back, Maria'), findsOneWidget);
    expect(
      find.text(
        'Manage your F&B properties, listings, and verification in one place.',
      ),
      findsOneWidget,
    );

    expect(find.text('Portfolio overview'), findsOneWidget);
    // 3 total, 1 published, 1 pending, 1 draft.
    expect(find.text('3'), findsOneWidget); // total properties
    expect(find.text('1'), findsNWidgets(3)); // published + pending + drafts

    // Quick actions for the owner dock vocabulary — no Messages.
    expect(find.text('Add Property'), findsOneWidget);
    expect(find.text('My Properties'), findsOneWidget);
    expect(find.text('Performance'), findsOneWidget);
    expect(find.text('Messages'), findsNothing);
    expect(find.text('New Enquiries'), findsNothing);

    // Property cards with Manage (the strip is scrollable; two cards fit the
    // first viewport, the rest build lazily as the list scrolls). "Pending
    // Review" appears twice — the overview metric label AND the Maple Court
    // card's compact pill.
    await _scrollUntilVisible(tester, find.text('Your properties'));
    expect(find.text('Manage'), findsWidgets);
    await _scrollUntilVisible(tester, find.text('Pending Review'));
    expect(find.text('Pending Review'), findsNWidgets(2));

    // Tasks derived ONLY from real records: one draft without photos →
    // upload task. The pending listing is NOT a task, and no enquiry-derived
    // task exists any more.
    await _scrollUntilVisible(tester, find.text('Upload property photos'));
    expect(find.text('Upload property photos'), findsOneWidget);
    expect(find.text('Respond to new enquiry'), findsNothing);
    expect(find.textContaining('Maple Court'), findsWidgets);
  });

  testWidgets('a failed load renders the retry surface, never fake data', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authNotifierProvider.overrideWith(
            () => _FixedAuthNotifier(
              AuthState(status: AuthStatus.authenticated, user: agentUser),
            ),
          ),
          providerDashboardProvider.overrideWith(
            (ref) async => throw StateError('backend unavailable'),
          ),
        ],
        child: const MaterialApp(home: ProviderDashboardMobilePage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Your dashboard could not be loaded'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('the loading state shows before data arrives', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authNotifierProvider.overrideWith(
            () => _FixedAuthNotifier(
              AuthState(status: AuthStatus.authenticated, user: agentUser),
            ),
          ),
          // A never-completing future keeps the provider in loading.
          providerDashboardProvider.overrideWith(
            (ref) => Completer<ProviderDashboardData>().future,
          ),
        ],
        child: const MaterialApp(home: ProviderDashboardMobilePage()),
      ),
    );
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('the agent home previews the tasks the Tasks tab renders', (
    tester,
  ) async {
    // The same classifier the tab uses, over records an agent was assigned —
    // Home and Tasks are two views of one list, so a count here is the count
    // there.
    final listings = [
      const ProviderListing(
        id: 1901,
        title: 'Annexe Road Shophouse',
        address: 'Ipoh, Perak',
        status: 'draft',
        isPublished: false,
        taskState: 'draft',
        missingRequiredFields: ['availability'],
        backendEditable: true,
      ),
      const ProviderListing(
        id: 1902,
        title: 'Bukit Bintang Loft',
        address: 'Kuala Lumpur, Federal Territory',
        status: 'draft',
        isPublished: false,
        taskState: 'draft',
        backendEditable: true,
      ),
      const ProviderListing(
        id: 1903,
        title: 'Tanjung Tokong Corner Unit',
        address: 'Penang, Pulau Pinang',
        status: 'rejected',
        isPublished: false,
        taskState: 'corrections',
        correctionNote: 'Tenancy period does not match the document.',
        correctionAction: 'listing_rejected',
        correctionAt: '2026-10-04T09:12:00+00:00',
        backendEditable: true,
      ),
      const ProviderListing(
        id: 1904,
        title: 'Seremban Garden Store',
        address: 'Nilai, Negeri Sembilan',
        status: 'approved',
        isPublished: true,
        taskState: 'approved',
      ),
    ];

    await tester.pumpWidget(
      host(
        user: agentUser,
        data: ProviderDashboardData(
          isAgent: true,
          firstName: 'Joel',
          listings: listings,
          tasks: const [],
          agentTasks: buildAgentTasks(listings),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _scrollUntilVisible(
      tester,
      find.text('Tasks requiring attention (3)'),
    );
    expect(find.text('Tasks requiring attention (3)'), findsOneWidget);
    expect(find.text('View all tasks'), findsOneWidget);

    // Three actionable records, and the preview never exceeds three.
    expect(find.text('Draft property'), findsNWidgets(2));
    expect(find.text('Corrections requested'), findsOneWidget);

    // An approved property is not work, and no task comes from an enquiry or
    // an appointment.
    expect(find.text('Approved property'), findsNothing);
    expect(find.text('Respond to new enquiry'), findsNothing);
    expect(find.text('Today\'s schedule'), findsNothing);
  });
}

/// Scrollable assertions: the dashboard is one long ListView, so sections
/// below the fold are built lazily — bring the target into view first.
Future<void> _scrollUntilVisible(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isNotEmpty) return;
  await tester.scrollUntilVisible(
    finder,
    240,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

SitewiseUser _userFor(AppRole role, String name) => SitewiseUser(
  id: 'user-${role.name}',
  name: name,
  email: 'test@sitewise.my',
  role: role,
  status: 'active',
  location: 'Kuala Lumpur',
  joinedAt: DateTime(2026, 1, 1),
);

/// A fixed session; the real notifier would start a Supabase restore.
class _FixedAuthNotifier extends AuthNotifier {
  _FixedAuthNotifier(this._state);

  final AuthState _state;

  @override
  AuthState build() => _state;

  @override
  Future<void> start() async {}

  @override
  Future<void> retry() async {}
}
