import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/core/config/site_content.dart';
import 'package:sitewise_jaspr_web/core/routing/navigation.dart';

void main() {
  group('web parentShellRoute', () {
    test('detail routes resolve to the intended sidebar destination', () {
      expect(parentShellRoute('/entrepreneur/preferences'), '/entrepreneur/profile');
      expect(parentShellRoute('/entrepreneur/explore'), '/entrepreneur/recommendations');
      expect(parentShellRoute('/entrepreneur/property-detail'), '/entrepreneur/recommendations');
      expect(parentShellRoute('/entrepreneur/assessment'), '/entrepreneur/assessments');
      expect(parentShellRoute('/entrepreneur/activity-history'), '/entrepreneur/assessments/history');
      expect(parentShellRoute('/admin/user-detail'), '/admin/users');
      expect(parentShellRoute('/admin/listing-detail'), '/admin/listings');
      expect(parentShellRoute('/admin/agent-detail'), '/admin/agents');
    });

    test('report surfaces resolve to the report gate, not discovery', () {
      expect(parentShellRoute('/entrepreneur/report'), '/entrepreneur/cafe-report');
      expect(parentShellRoute('/entrepreneur/cafe-report/view'), '/entrepreneur/cafe-report');
      expect(parentShellRoute('/entrepreneur/reports'), '/entrepreneur/cafe-report');
    });

    test('unknown and platform-specific routes remain unchanged', () {
      expect(parentShellRoute('/entrepreneur/unknown'), '/entrepreneur/unknown');
      // These are mobile shell routes; the web shell must not claim them.
      expect(parentShellRoute('/provider/add-property'), '/provider/add-property');
      expect(parentShellRoute('/entrepreneur/customer-assessments'),
          '/entrepreneur/customer-assessments');
    });

    test('sidebar destinations for the active roles are intact', () {
      final entrepreneurRoutes = webDestinationsFor(AppRole.entrepreneur)
          .map((d) => d.route)
          .toSet();
      expect(entrepreneurRoutes, contains('/entrepreneur/assessments'));
      expect(entrepreneurRoutes, contains('/entrepreneur/assessments/history'));
      expect(entrepreneurRoutes, contains('/entrepreneur/recommendations'));
      expect(entrepreneurRoutes, contains('/entrepreneur/profile'));

      final adminRoutes = webDestinationsFor(AppRole.admin).map((d) => d.route).toSet();
      expect(adminRoutes, contains('/admin/users'));
      expect(adminRoutes, contains('/admin/listings'));
      expect(adminRoutes, contains('/admin/agents'));

      // Retired web roles have no sidebar; their URLs redirect elsewhere.
      expect(webDestinationsFor(AppRole.owner), isEmpty);
      expect(webDestinationsFor(AppRole.agent), isEmpty);
    });

    test('role is derived from the route, independently of shell selection', () {
      expect(roleForPath('/admin/user-detail'), AppRole.admin);
      expect(roleForPath('/entrepreneur/property-detail'), AppRole.entrepreneur);
      expect(roleForPath('/owner/legacy'), AppRole.owner);
      expect(roleForPath('/agent/legacy'), AppRole.agent);
      // Mapping a detail route to its parent never changes the role.
      expect(roleForPath(parentShellRoute('/admin/user-detail')), AppRole.admin);
    });
  });
}
