import 'package:jaspr_test/jaspr_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:sitewise_jaspr_web/core/routing/navigation.dart';
import 'package:sitewise_jaspr_web/features/property_management/presentation/pages/owner_retired_page.dart';

/// The web role surfaces after the Provider migration.
///
/// Three rules are pinned here, because all three are one line away from
/// silently coming back:
///
/// * the **Entrepreneur** sidebar has no `My Properties` — listing management
///   is a Provider (Owner / Agent) capability in the mobile app, and a
///   destination that opens a denied page is worse than no destination;
/// * the **Owner** and **Agent** web workspaces are retired, so neither has any
///   sidebar destination at all;
/// * the **Admin** sidebar still has its four primary destinations, so
///   retiring the owner surface did not take the administrator portal with it.
void main() {
  group('entrepreneur web navigation', () {
    final routes = webDestinationsFor(
      AppRole.entrepreneur,
    ).map((d) => d.route).toList();

    test('no longer offers My Properties', () {
      expect(routes, isNot(contains('/entrepreneur/my-properties')));
      expect(
        webDestinationsFor(
          AppRole.entrepreneur,
        ).map((d) => d.label).toList(),
        isNot(contains('My Properties')),
      );
    });

    test('keeps every discovery, assessment and account destination', () {
      for (final route in const [
        '/entrepreneur',
        '/entrepreneur/recommendations',
        '/entrepreneur/assessments',
        '/entrepreneur/reports',
        '/entrepreneur/assessments/history',
        '/entrepreneur/compare',
        '/entrepreneur/saved',
        '/entrepreneur/profile',
      ]) {
        expect(routes, contains(route), reason: '$route must stay reachable');
      }
    });

    test('has no property-creation entry point left', () {
      expect(routes, isNot(contains('/entrepreneur/add-property')));
    });
  });

  group('retired web workspaces', () {
    test('the owner workspace has no destinations', () {
      expect(webDestinationsFor(AppRole.owner), isEmpty);
    });

    test('the agent workspace has no destinations', () {
      expect(webDestinationsFor(AppRole.agent), isEmpty);
    });

    test('the admin portal keeps its primary destinations', () {
      expect(
        webDestinationsFor(AppRole.admin).map((d) => d.route).toList(),
        containsAll(const [
          '/admin',
          '/admin/users',
          '/admin/agents',
          '/admin/listings',
        ]),
      );
    });
  });

  group('shell highlighting', () {
    test('retired owner routes no longer highlight an owner section', () {
      for (final path in const [
        '/owner',
        '/owner/properties',
        '/owner/property-detail',
        '/owner/tours',
      ]) {
        // No mapping exists, so the path is returned unchanged and no pill can
        // light up for a workspace that is gone.
        expect(parentShellRoute(path), path);
      }
    });

    test('retired entrepreneur listing routes do not point at a dead pill', () {
      expect(parentShellRoute('/entrepreneur/my-properties'), '/entrepreneur');
      expect(parentShellRoute('/entrepreneur/add-property'), '/entrepreneur');
    });

    test('discovery drill-ins still highlight Recommendations', () {
      expect(
        parentShellRoute('/entrepreneur/property-detail'),
        '/entrepreneur/recommendations',
      );
      expect(
        parentShellRoute('/entrepreneur/explore'),
        '/entrepreneur/recommendations',
      );
    });
  });

  group('retired owner page', () {
    testComponents('explains where the workspace went, with no data', (
      tester,
    ) async {
      tester.pumpComponent(const OwnerRetiredPage());

      // The copy has to name the destination, or the page is just a 200 OK
      // dead end.
      expect(find.text('Your workspace is in the SiteWise app'), findsOneComponent);
      expect(
        find.text(
          'Property Owners and Agents share one workspace in the SiteWise '
          'mobile application — listings, photographs, 360° capture, '
          'enquiries, performance and verification all live there under the '
          'same account.',
        ),
        findsOneComponent,
      );
      // And it must not leak a record: no listing table, no owner identity.
      expect(find.text('My Properties'), findsNothing);
    });
  });
}
