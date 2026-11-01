import 'package:jaspr/jaspr.dart';
import 'package:jaspr_router/jaspr_router.dart';

import 'data/app_locator.dart';
import 'data/auth_service.dart';
import 'pages/auth_callback_page.dart';
import 'components/ui.dart';
import 'layouts/marketing_layout.dart';
import 'pages/landing_page.dart';
import 'pages/login_page.dart';
import 'pages/signup_page.dart';
import 'pages/forgot_password_page.dart';
import 'pages/entrepreneur/compare_page.dart';
import 'pages/entrepreneur/dashboard_page.dart' as e_dashboard;
import 'pages/entrepreneur/explanation_page.dart' as e_explanation;
import 'pages/entrepreneur/explore_page.dart' as e_explore;
import 'pages/entrepreneur/map_page.dart' as e_map;
import 'pages/entrepreneur/preferences_page.dart' as e_preferences;
import 'pages/entrepreneur/profile_page.dart' as e_profile;
import 'pages/entrepreneur/property_detail_page.dart' as e_property_detail;
import 'pages/entrepreneur/recommendations_page.dart' as e_recommendations;
import 'pages/entrepreneur/report_page.dart' as e_report;
import 'pages/entrepreneur/saved_page.dart' as e_saved;
import 'pages/entrepreneur/tour_page.dart' as e_tour;
import 'pages/admin/dashboard_page.dart' as a_dashboard;
import 'pages/admin/listing_detail_page.dart' as a_listing_detail;
import 'pages/admin/listings_page.dart' as a_listings;
import 'pages/admin/profile_page.dart' as a_profile;
import 'pages/admin/user_detail_page.dart' as a_user_detail;
import 'pages/admin/users_page.dart' as a_users;
import 'pages/admin/verification_detail_page.dart' as a_verification_detail;
import 'pages/admin/verification_page.dart' as a_verification;
import 'pages/owner/add_property_page.dart' as o_add_property;
import 'pages/owner/dashboard_page.dart' as o_dashboard;
import 'pages/owner/profile_page.dart' as o_profile;
import 'pages/owner/properties_page.dart' as o_properties;
import 'pages/owner/property_detail_page.dart' as o_property_detail;
import 'pages/owner/tour_preview_page.dart' as o_tour_preview;
import 'pages/owner/tours_page.dart' as o_tours;

/// Route table — the Jaspr counterpart to
/// `lib/core/routing/app_routes.dart` in the Flutter app.
///
/// The Flutter version resolves one `onGenerateRoute` callback, picks a page
/// per presentation environment (web vs mobile tree) and passes detail ids as
/// `settings.arguments`. That machinery is unnecessary here: this app **is**
/// the web tree, so:
///
/// * Routes map one-to-one to pages (the mobile tree stays in Flutter);
/// * Detail ids travel as `?id=` query params, so links are shareable;
/// * The active role is derived from the URL path (`roleForPath`), not from
///   mutable client state.
///
/// The route list is explicit (one entry per Flutter route in
/// `app_routes.dart`); the sidebar in `navigation.dart` mirrors the same
/// path strings.
///
/// Mounted directly by main.client.dart; no server hydration anchors are needed.
class SitewiseApp extends StatelessComponent {
  const SitewiseApp({super.key});

  @override
  Component build(BuildContext context) {
    return Router(
      redirect: (context, state) {
        final path = Uri.parse(state.location).path;
        final rolePath = RegExp(
          r'^/(entrepreneur|owner|admin)(/|$)',
        ).firstMatch(path);
        if (rolePath == null) return null;
        final profile = WebAuth.profile;
        if (profile == null) {
          return '/login?next=${Uri.encodeComponent(state.location)}';
        }
        final role = profile['role'] as String;
        return rolePath.group(1) == role ? null : '/$role';
      },
      errorBuilder: (context, state) => const MarketingLayout(
        child: EmptyState(
          title: 'Page not found',
          body: 'This address does not match a Sitewise page.',
          action: ActionLink('Back to home', href: '/'),
        ),
      ),
      routes: [
        // --- Public ----------------------------------------------------------
        Route(path: '/', builder: (context, state) => const LandingPage()),
        Route(
          path: '/landing',
          builder: (context, state) => const LandingPage(),
        ),
        Route(path: '/login', builder: (context, state) => const LoginPage()),
        Route(
          path: '/auth/callback',
          builder: (context, state) => const AuthCallbackPage(),
        ),
        Route(path: '/signup', builder: (context, state) => const SignupPage()),
        Route(
          path: '/forgot',
          builder: (context, state) => const ForgotPasswordPage(),
        ),

        // --- Admin -----------------------------------------------------------
        Route(
          path: '/admin',
          builder: (context, state) => const a_dashboard.DashboardPage(),
        ),
        Route(
          path: '/admin/users',
          builder: (context, state) => const a_users.UsersPage(),
        ),
        Route(
          path: '/admin/user-detail',
          builder: (context, state) =>
              a_user_detail.UserDetailPage(id: state.queryParams['id'] ?? ''),
        ),
        Route(
          path: '/admin/verification',
          builder: (context, state) => const a_verification.VerificationPage(),
        ),
        Route(
          path: '/admin/verification-detail',
          builder: (context, state) =>
              a_verification_detail.VerificationDetailPage(
                id: state.queryParams['id'] ?? '',
              ),
        ),
        Route(
          path: '/admin/listings',
          builder: (context, state) => const a_listings.ListingsPage(),
        ),
        Route(
          path: '/admin/listing-detail',
          builder: (context, state) => a_listing_detail.ListingDetailPage(
            id: state.queryParams['id'] ?? '',
          ),
        ),
        Route(
          path: '/admin/profile',
          builder: (context, state) => const a_profile.ProfilePage(),
        ),

        // --- Owner -----------------------------------------------------------
        Route(
          path: '/owner',
          builder: (context, state) => const o_dashboard.DashboardPage(),
        ),
        Route(
          path: '/owner/properties',
          builder: (context, state) => const o_properties.PropertiesPage(),
        ),
        Route(
          path: '/owner/property-detail',
          builder: (context, state) => o_property_detail.PropertyDetailPage(
            id: state.queryParams['id'] ?? '',
          ),
        ),
        Route(
          path: '/owner/add-property',
          builder: (context, state) => o_add_property.AddPropertyPage(
            editingId: state.queryParams['id'],
          ),
        ),
        Route(
          path: '/owner/tours',
          builder: (context, state) => const o_tours.ToursPage(),
        ),
        Route(
          path: '/owner/tour-preview',
          builder: (context, state) =>
              o_tour_preview.TourPreviewPage(id: state.queryParams['id'] ?? ''),
        ),
        Route(
          path: '/owner/profile',
          builder: (context, state) => const o_profile.ProfilePage(),
        ),

        // --- Entrepreneur ----------------------------------------------------
        Route(
          path: '/entrepreneur',
          builder: (context, state) => const e_dashboard.DashboardPage(),
        ),
        Route(
          path: '/entrepreneur/preferences',
          builder: (context, state) => const e_preferences.PreferencesPage(),
        ),
        Route(
          path: '/entrepreneur/explore',
          builder: (context, state) => e_explore.ExplorePage(
            startInMap: state.queryParams['id'] == 'map',
          ),
        ),
        Route(
          path: '/entrepreneur/map',
          builder: (context, state) =>
              e_map.MapPage(initialId: state.queryParams['id']),
        ),
        Route(
          path: '/entrepreneur/explanation',
          builder: (context, state) => e_explanation.ExplanationPage(
            propertyId: state.queryParams['property'] ?? '',
          ),
        ),
        Route(
          path: '/entrepreneur/property-detail',
          builder: (context, state) => e_property_detail.PropertyDetailPage(
            id: state.queryParams['id'] ?? '',
          ),
        ),
        Route(
          path: '/entrepreneur/tour',
          builder: (context, state) =>
              e_tour.TourPage(id: state.queryParams['id'] ?? ''),
        ),
        Route(
          path: '/entrepreneur/recommendations',
          builder: (context, state) =>
              const e_recommendations.RecommendationsPage(),
        ),
        Route(
          path: '/entrepreneur/compare',
          builder: (context, state) =>
              ComparePage(appCubit: AppLocator.appCubit),
        ),
        Route(
          path: '/entrepreneur/saved',
          builder: (context, state) => const e_saved.SavedPage(),
        ),
        Route(
          path: '/entrepreneur/report',
          builder: (context, state) =>
              e_report.ReportPage(id: state.queryParams['id'] ?? ''),
        ),
        Route(
          path: '/entrepreneur/profile',
          builder: (context, state) => const e_profile.ProfilePage(),
        ),

        // Unknown browser routes use errorBuilder above.
      ],
    );
  }
}
