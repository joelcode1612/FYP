import 'package:flutter_test/flutter_test.dart';
import 'package:fyp/core/routing/app_routes.dart';

void main() {
  group('mobile parentShellRoute', () {
    test('provider detail routes resolve to the intended bottom-nav destination', () {
      expect(parentShellRoute('/provider/add-property'), '/provider/add-property');
      expect(parentShellRoute('/provider/property-detail'), '/provider/listings');
      expect(parentShellRoute('/provider/requests'), '/provider/requests');
      expect(parentShellRoute('/provider/performance'), '/provider');
      expect(parentShellRoute('/provider/verification'), '/provider/profile');
      expect(parentShellRoute('/provider/mfa'), '/provider/profile');
    });

    test('entrepreneur detail routes keep the correct tab selected', () {
      expect(parentShellRoute('/entrepreneur/preferences'), '/entrepreneur/profile');
      expect(parentShellRoute('/entrepreneur/saved'), '/entrepreneur/favourites');
      expect(parentShellRoute('/entrepreneur/compare'), '/entrepreneur/favourites');
      expect(parentShellRoute('/entrepreneur/property-detail'),
          '/entrepreneur/recommendations');
      expect(parentShellRoute('/entrepreneur/tour'), '/entrepreneur/recommendations');
      expect(parentShellRoute('/tour-preview'), '/entrepreneur/recommendations');
    });

    test('all assessment screens resolve to the assessment tab', () {
      expect(parentShellRoute('/entrepreneur/assessment-setup'), AppRoutes.assessmentHome);
      expect(parentShellRoute('/entrepreneur/assessment-summary'), AppRoutes.assessmentHome);
      expect(parentShellRoute('/entrepreneur/research-questions'), AppRoutes.assessmentHome);
      expect(parentShellRoute(AppRoutes.assessmentHome), AppRoutes.assessmentHome);
      expect(parentShellRoute(AppRoutes.assessmentQuestionnaire), AppRoutes.assessmentHome);
      expect(parentShellRoute(AppRoutes.assessmentReview), AppRoutes.assessmentHome);
    });

    test('trailing slash and query string are normalised before lookup', () {
      expect(parentShellRoute('/entrepreneur/property-detail/?tab=photos'),
          '/entrepreneur/recommendations');
      expect(parentShellRoute('${AppRoutes.assessmentQuestionnaire}/?step=2'),
          AppRoutes.assessmentHome);
      expect(parentShellRoute('/provider/property-detail/?id=abc'),
          '/provider/listings');
    });

    test('unknown and web-only routes remain unchanged', () {
      expect(parentShellRoute('/entrepreneur/unknown'), '/entrepreneur/unknown');
      // These are web shell routes; the mobile shell must not claim them.
      expect(parentShellRoute('/entrepreneur/assessments'),
          '/entrepreneur/assessments');
      expect(parentShellRoute('/admin/user-detail'), '/admin/user-detail');
      expect(parentShellRoute('/entrepreneur/cafe-report'),
          '/entrepreneur/cafe-report');
    });
  });
}
