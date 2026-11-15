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
///   (including the HONEST '—' for viewings / deals SiteWise never records),
///   the schedule empty state, assigned-property cards and lead rows;
/// * the Owner layout — portfolio metrics, "Tasks to do" derived from real
///   drafts and enquiries, Manage buttons;
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
    listings: [
      const ProviderListing(
        id: 1755,
        title: 'Riverside Promenade – Unit 01',
        address: 'Kuala Lumpur, Federal Territory of Kuala Lumpur',
        status: 'approved',
        isPublished: true,
        rent: 12000,
        imageUrl: 'https://example.test/photo.jpg',
      ),
      const ProviderListing(
        id: 1760,
        title: 'Maple Court – Unit B2-05',
        address: 'Penang, Pulau Pinang',
        status: 'pending',
        isPublished: false,
        rent: 9800,
      ),
    ],
    enquiryMetrics: const ProviderEnquiryMetrics(
      total: 5,
      byStatus: {'new': 5, 'replied': 2},
    ),
    recentEnquiries: [
      ProviderEnquiry(
        id: 9,
        propertyId: 1755,
        propertyTitle: 'Riverside Promenade – Unit 01',
        propertyAddress: 'Kuala Lumpur',
        enquirerName: 'Alicia Tan',
        enquirerEmail: 'alicia@example.test',
        message: 'Is this unit still available for viewing next week?',
        status: ProviderEnquiryStatus.incoming,
      ),
    ],
    tasks: const [],
    performance: null,
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
      enquiryMetrics: const ProviderEnquiryMetrics(
        total: 5,
        byStatus: {'new': 2, 'replied': 3},
      ),
      recentEnquiries: const [],
      tasks: buildOwnerTasks(listings, const [
        ProviderEnquiry(
          id: 11,
          propertyId: 1802,
          propertyTitle: 'Maple Court – Unit B2-05',
          propertyAddress: 'Penang',
          enquirerName: 'Marcus Lee',
          enquirerEmail: 'marcus@example.test',
          message: 'What is the minimum lease term?',
          status: ProviderEnquiryStatus.incoming,
        ),
      ]),
      performance: null,
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
        'Manage your assigned properties, client enquiries, and viewings.',
      ),
      findsOneWidget,
    );

    // Overview metrics from the bundle. The response rate IS calculable
    // (2 replied of 5 → 40%); viewings are honestly untracked.
    expect(find.text('Agent overview'), findsOneWidget);
    expect(find.text('Your agency activity at a glance.'), findsOneWidget);
    expect(find.text('2'), findsOneWidget); // assigned properties
    expect(find.text('5'), findsOneWidget); // new leads
    expect(find.text('40%'), findsOneWidget);
    expect(find.text('—'), findsWidgets); // at least Viewings Today
    expect(find.text('Not tracked'), findsOneWidget);

    // Quick actions.
    expect(find.text('Assigned Listings'), findsOneWidget);
    expect(find.text('Schedule'), findsOneWidget);

    // Schedule is an honest empty state: no scheduling backend exists.
    expect(find.text("Today's schedule"), findsOneWidget);
    expect(find.text('No schedule yet'), findsOneWidget);

    // Assigned property cards with the real record. (Section headers above
    // the scrolled target are not asserted — a ListView builds and lays out
    // lazily, so a header may sit just above the viewport edge while the
    // card it titles is centred.)
    await _scrollUntilVisible(tester, find.text('Riverside Promenade – Unit 01'));
    // Twice: the property card title AND the lead row's property reference
    // (the sample enquiry is about that listing).
    expect(find.text('Riverside Promenade – Unit 01'), findsNWidgets(2));
    expect(find.text('RM 12000 / month'), findsOneWidget);
    expect(find.text('Open'), findsWidgets);

    // Recent leads come from the enquiries API.
    await _scrollUntilVisible(tester, find.text('Alicia Tan'));
    expect(find.text('Alicia Tan'), findsOneWidget);
    expect(find.text('New'), findsOneWidget);

    // Weekly performance with the honest no-comparison note.
    await _scrollUntilVisible(tester, find.text('Closed Deals'));
    expect(find.text('Performance this week'), findsOneWidget);
    expect(find.text('Compared to last week'), findsOneWidget);
    expect(find.text('Closed Deals'), findsOneWidget);
    expect(find.text('Not recorded'), findsWidgets);
    expect(
      find.textContaining('SiteWise stores no weekly history'),
      findsOneWidget,
    );
  });

  testWidgets('the owner dashboard renders portfolio, tasks and properties', (
    tester,
  ) async {
    await tester.pumpWidget(host(user: ownerUser, data: ownerBundle()));
    await tester.pumpAndSettle();

    expect(find.text('Welcome back, Maria'), findsOneWidget);
    expect(
      find.text(
        'Manage your F&B properties, listings, and enquiries in one place.',
      ),
      findsOneWidget,
    );

    expect(find.text('Portfolio overview'), findsOneWidget);
    // 3 total, 1 published, 1 pending, 2 new enquiries.
    expect(find.text('3'), findsOneWidget); // total properties
    expect(find.text('1'), findsNWidgets(2)); // published + pending
    expect(find.text('2'), findsOneWidget); // new enquiries

    // Quick actions for the owner dock vocabulary.
    expect(find.text('Add Property'), findsOneWidget);
    expect(find.text('My Properties'), findsOneWidget);
    expect(find.text('Messages'), findsOneWidget);

    // Property cards with Manage (the strip is scrollable; two cards fit the
    // first viewport, the rest build lazily as the list scrolls). "Pending
    // Review" appears twice — the overview metric label AND the Maple Court
    // card's compact pill.
    await _scrollUntilVisible(tester, find.text('Your properties'));
    expect(find.text('Manage'), findsWidgets);
    await _scrollUntilVisible(tester, find.text('Pending Review'));
    expect(find.text('Pending Review'), findsNWidgets(2));

    // Tasks derived ONLY from real records: one draft without photos →
    // upload task; one new enquiry → respond task. The pending listing is
    // NOT a task (nothing for the owner to do about it).
    await _scrollUntilVisible(tester, find.text('Upload property photos'));
    expect(find.text('Upload property photos'), findsOneWidget);
    expect(find.text('Respond to new enquiry'), findsOneWidget);
    expect(find.textContaining('Maple Court'), findsWidgets);

    // Weekly performance card closes the owner layout.
    await _scrollUntilVisible(tester, find.text('Property Views'));
    expect(find.text('Performance this week'), findsOneWidget);
    expect(find.text('Property Views'), findsOneWidget);
    expect(find.text('Not tracked'), findsWidgets);
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
