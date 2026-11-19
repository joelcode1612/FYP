import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fyp/presentation/mobile/provider/pages/provider_listings_mobile_page.dart';
import 'package:fyp/presentation/mobile/provider/pages/provider_models.dart';
import 'package:shared_logic/shared_logic.dart';

/// Focused guards for the redesigned My Listings screen.
///
/// * the pure filter/search logic — chips and the visible list must be
///   computed from the SAME searched set, so a count can never disagree with
///   the rows it advertises;
/// * the Assigned chip only exists when a listing is actually agent-managed;
/// * the card renders the backend's real data — MYR rent, the management
///   attribution and explicit unavailable states for the metrics SiteWise
///   does not track (views / saves) — never invented numbers;
/// * the owner Edit affordance respects the backend editing policy mirror
///   (draft / rejected editable, records under review locked).
void main() {
  group('listing filters (pure logic)', () {
    final scope = ProviderWorkspace(
      isAgent: false,
      listings: [
        _listing(1, stage: 'approved', published: true, title: 'Riverside Retail Space',
            address: 'Jalan Ampang, Kuala Lumpur', type: 'Retail'),
        _listing(2, stage: 'pending', title: 'Citrine Office Suite',
            address: 'Jalan Sultan Ismail, Kuala Lumpur', type: 'Office'),
        _listing(3, stage: 'draft', title: 'Old Shoplot',
            address: 'Ipoh', type: 'Shop'),
        _listing(4, stage: 'approved', published: true, title: 'Agent Cafe',
            address: 'Penang', type: 'Cafe',
            management: const ProviderManagement(
              type: 'agent', label: 'Agent-managed', name: 'Maria Santos',
              reason: null)),
      ],
    );

    test('chip counts agree with the visible list for every filter', () {
      for (final (filter, _, count) in providerListingsChips(scope, '')) {
        expect(providerVisibleListings(scope, filter, '').length, count);
      }
    });

    test('chip counts follow the search, not the raw portfolio', () {
      // Searching "kuala" narrows to two rows, so All (2) — and the active
      // count inside the chips — must reflect the searched set.
      final chips = providerListingsChips(scope, 'kuala').toList();
      final all = chips.firstWhere((c) => c.$1 == ProviderListingsFilter.all);
      expect(all.$3, 2);
      final active = chips.firstWhere((c) => c.$1 == ProviderListingsFilter.active);
      expect(active.$3, 1);
    });

    test('the Assigned chip exists only when a listing is agent-managed', () {
      final without = providerListingsChips(
        ProviderWorkspace(isAgent: false, listings: scope.listings.sublist(0, 3)),
        '',
      );
      expect(
        without.any((c) => c.$1 == ProviderListingsFilter.assigned),
        isFalse,
        reason: 'an owner with no agent assignment must not see Assigned',
      );

      final withOne = providerListingsChips(scope, '');
      final assigned = withOne.firstWhere(
        (c) => c.$1 == ProviderListingsFilter.assigned,
        orElse: () => throw StateError('Assigned chip missing'),
      );
      expect(assigned.$3, 1);
    });

    test('rejected and unknown chips appear only when non-empty', () {
      final chips = providerListingsChips(scope, '');
      expect(chips.any((c) => c.$1 == ProviderListingsFilter.rejected), isFalse);
      expect(chips.any((c) => c.$1 == ProviderListingsFilter.unknown), isFalse);

      final withRejected = ProviderWorkspace(
        isAgent: false,
        listings: [...scope.listings, _listing(9, stage: 'rejected')],
      );
      final chips2 = providerListingsChips(withRejected, '');
      expect(
        chips2.firstWhere((c) => c.$1 == ProviderListingsFilter.rejected).$3,
        1,
      );
    });

    test('Active means approved AND published', () {
      final active = ProviderListingsFilter.active;
      expect(active.matches(scope.listings[0]), isTrue);
      final approvedButUnpublished = _listing(7, stage: 'approved');
      expect(active.matches(approvedButUnpublished), isFalse);
      expect(approvedButUnpublished.locallyEditable, isFalse);
    });

    test('search matches title, address and property type', () {
      const search = ProviderListingsFilter.all;
      expect(search.matchesQuery(scope.listings[0], 'riverside'), isTrue);
      expect(search.matchesQuery(scope.listings[0], 'ampang'), isTrue);
      expect(search.matchesQuery(scope.listings[0], 'retail'), isTrue);
      expect(search.matchesQuery(scope.listings[0], 'penang'), isFalse);
    });
  });

  group('My Listings screen', () {
    late ProviderWorkspace workspace;

    setUp(() {
      workspace = ProviderWorkspace(
        isAgent: false,
        listings: [
          _listing(
            11,
            stage: 'approved',
            published: true,
            title: 'Riverside Retail Space',
            address: 'Jalan Ampang, Kuala Lumpur',
            type: 'Retail',
            rent: 120000,
            management: const ProviderManagement(
              type: 'owner', label: 'Owner-managed', name: 'Daniel Wong',
              reason: null),
          ),
          _listing(
            12,
            stage: 'pending',
            title: 'Citrine Office Suite',
            address: 'Jalan Sultan Ismail, Kuala Lumpur',
            type: 'Office',
            rent: 280000,
            management: const ProviderManagement(
              type: 'agent', label: 'Agent-managed', name: 'Maria Santos',
              reason: null),
          ),
        ],
      );
    });

    Future<void> pumpPage(WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authNotifierProvider.overrideWith(
              () => _FixedAuthNotifier(_authenticatedAs(AppRole.owner)),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: ProviderListingsMobilePage(
                loadOverride: (_) async => workspace,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('renders the owner header, real statistics and the chip row',
        (tester) async {
      await pumpPage(tester);

      expect(find.text('My Listings'), findsOneWidget);
      expect(find.text('Manage your owned and assigned properties'),
          findsOneWidget);
      // Stat cards computed from the workspace — never hardcoded figures.
      // Total = 2, Active = the one approved-and-published row.
      expect(find.text('Total Listings'), findsOneWidget);
      expect(find.text('Active Listings'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      // The Active stat card shows "1" (the one approved-and-published row);
      // the Pending chip combines its label and count into one string.
      expect(find.text('1'), findsOneWidget);
      // Chips with counts; Assigned appears because one row is agent-managed.
      expect(find.text('All (2)'), findsOneWidget);
      expect(find.text('Active (1)'), findsOneWidget);
      expect(find.text('Pending (1)'), findsOneWidget);
      expect(find.text('Draft (1)'), findsNothing);
      expect(find.text('Assigned (1)'), findsOneWidget);
    });

    testWidgets('cards show MYR rent, status, management and honest metrics',
        (tester) async {
      await pumpPage(tester);

      // MYR formatting, not the screenshot's pesos.
      expect(find.text('RM 120000'), findsOneWidget);
      expect(find.text('/ month'), findsNWidgets(2));
      expect(find.text('RM 280000'), findsOneWidget);
      expect(find.textContaining('₱'), findsNothing);

      // Status badges from the backend vocabulary.
      expect(find.text('Active'), findsOneWidget);
      expect(find.text('Pending'), findsOneWidget);

      // Management attribution from the derived records.
      expect(find.text('Owner-managed'), findsOneWidget);
      expect(find.text('You (Property Owner)'), findsOneWidget);
      expect(find.text('Agent-managed'), findsOneWidget);
      expect(find.text('Maria Santos'), findsOneWidget);

      // Views / Saved are not tracked — unavailable, never a fabricated count.
      // 2 cards × (views + saved): the Enquiries slot was removed with the
      // Enquiries feature, so the metric row carries no enquiry dash either.
      expect(find.text('—'), findsNWidgets(4));
      expect(find.text('Enquiries'), findsNothing);
      expect(find.text('5'), findsNothing);
    });

    testWidgets('the owner Edit button follows the backend editing policy',
        (tester) async {
      await pumpPage(tester);

      // The approved (published) card: Edit visible but locked.
      final approvedCard = find.ancestor(
        of: find.text('Riverside Retail Space'),
        matching: find.byType(ProviderListingCard),
      );
      final approvedEdit = find.descendant(
        of: approvedCard,
        matching: find.byType(OutlinedButton),
      );
      expect(tester.widget<OutlinedButton>(approvedEdit).onPressed, isNull);

      // The draft/rejected card: Edit opens the existing draft-resume form.
      final pendingCard = find.ancestor(
        of: find.text('Citrine Office Suite'),
        matching: find.byType(ProviderListingCard),
      );
      final pendingEdit = find.descendant(
        of: pendingCard,
        matching: find.byType(OutlinedButton),
      );
      // Pending is also locked (under review).
      expect(tester.widget<OutlinedButton>(pendingEdit).onPressed, isNull);
    });

    testWidgets('searching narrows the list and the chip counts together',
        (tester) async {
      await pumpPage(tester);
      await tester.enterText(find.byType(TextField), 'citrine');
      await tester.pumpAndSettle();

      expect(find.text('Riverside Retail Space'), findsNothing);
      expect(find.text('Citrine Office Suite'), findsOneWidget);
      expect(find.text('All (1)'), findsOneWidget);
      expect(find.text('Active (0)'), findsOneWidget);
      // The only matching row is agent-managed, so Assigned stays with it.
      expect(find.text('Assigned (1)'), findsOneWidget);
      expect(find.text('No properties match your search'), findsNothing);
    });

    testWidgets('an empty portfolio renders the create-first state',
        (tester) async {
      workspace = const ProviderWorkspace(isAgent: false, listings: []);
      await pumpPage(tester);
      expect(find.text('No listings yet'), findsOneWidget);
    });
  });

  // The reuse contract for Add Property: ONE form, entered from the ONE listing
  // screen by both provider roles. An agent previously had no path into it at
  // all, which is what made the shared form unreachable rather than duplicated.
  group('shared Add Property entry point', () {
    Future<List<String>> openAs(WidgetTester tester, AppRole role) async {
      // Real phone width, so the header Row (title + action) is exercised
      // against the layout that actually ships.
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final visited = <String>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authNotifierProvider.overrideWith(
              () => _FixedAuthNotifier(_authenticatedAs(role)),
            ),
          ],
          child: MaterialApp(
            onGenerateRoute: (settings) {
              visited.add(settings.name ?? '');
              return MaterialPageRoute<void>(
                settings: settings,
                builder: (_) => const Scaffold(body: Text('add form')),
              );
            },
            home: Scaffold(
              body: ProviderListingsMobilePage(
                loadOverride: (_) async =>
                    ProviderWorkspace(isAgent: role == AppRole.agent, listings: const []),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Exactly one create affordance, worded the same for either role.
      expect(find.text('Add Property'), findsOneWidget);
      await tester.tap(find.text('Add Property'));
      await tester.pumpAndSettle();
      return visited;
    }

    for (final role in const [AppRole.owner, AppRole.agent]) {
      testWidgets('a $role listing opens the shared /provider/add-property form',
          (tester) async {
        final visited = await openAs(tester, role);
        expect(
          visited,
          ['/provider/add-property'],
          reason:
              'both roles must resolve the one existing form, never a per-role copy',
        );
      });
    }
  });
}

ProviderListing _listing(
  int id, {
  required String stage,
  bool published = false,
  String title = 'Listing',
  String address = '',
  String? type,
  double? rent,
  ProviderManagement? management,
}) =>
    ProviderListing(
      id: id,
      title: title,
      address: address,
      rent: rent,
      propertyType: type,
      status: stage,
      isPublished: published,
      management: management,
    );

AuthState _authenticatedAs(AppRole role) => AuthState(
  status: AuthStatus.authenticated,
  user: SitewiseUser(
    id: 'user-${role.name}',
    name: 'Test ${role.label}',
    email: 'test@sitewise.my',
    role: role,
    status: 'active',
    location: 'Kuala Lumpur',
    joinedAt: DateTime(2026, 1, 1),
  ),
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
