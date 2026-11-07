import 'package:jaspr/jaspr.dart';
import 'package:jaspr_router/jaspr_router.dart';
import 'package:shared_logic/shared_logic.dart';

import 'data/auth_service.dart';
import 'data/ssr_service.dart';
import 'data/workspaces.dart';
import 'pages/auth_callback_page.dart';
import 'components/ui.dart';
import 'layouts/marketing_layout.dart';
import 'pages/landing_page.dart';
import 'pages/login_page.dart';
import 'pages/signup_page.dart';
import 'pages/forgot_password_page.dart';
import 'pages/staff_mfa_page.dart';
import 'pages/staff_verify_page.dart';
import 'pages/reset_password_page.dart';
import 'pages/entrepreneur/compare_page.dart';
import 'pages/entrepreneur/dashboard_page.dart' as e_dashboard;
import 'pages/entrepreneur/my_properties_page.dart' as e_my_properties;
import 'pages/entrepreneur/add_property_page.dart' as e_add_property;
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
import 'pages/admin/agents_page.dart';
import 'pages/agent/dashboard_page.dart';
import 'pages/agent/enquiries_page.dart';
import 'pages/agent/listings_page.dart';
import 'pages/agent/performance_page.dart';
import 'pages/agent/profile_page.dart';
import 'pages/agent/property_detail_page.dart';
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
/// * The active role is derived from the URL path, not from mutable client
///   state.
///
/// ## Where this router runs
///
/// Exclusively **on the server**. `SitewiseApp` is part of the document the
/// server renders, so `/entrepreneur/explore` returns that page's own HTML on
/// a cold request or a hard refresh; the browser never boots a second router
/// over the markup. The interactive leaves inside each page are `@client`
/// components hydrated in place by `main.client.dart`, and because no router
/// exists on the client, `Link` falls through to normal anchor navigation —
/// i.e. a genuine document request per page.
///
/// Consequence worth remembering: `redirect` and `errorBuilder` only ever run
/// during a render, so they can set a real status line (`302`, `404`) instead
/// of swapping a widget after the fact.
class SitewiseApp extends StatelessComponent {
  const SitewiseApp({super.key});

  @override
  Component build(BuildContext context) {
    return Router(
      redirect: (context, state) {
        final path = Uri.parse(state.location).path;
        final rolePath = RegExp(
          r'^/(entrepreneur|owner|admin|agent)(/|$)',
        ).firstMatch(path);
        if (rolePath == null) return null;
        // Server-side identity comes from the session cookie the browser
        // mirrors. The 302 itself is set by the document shell, which can also
        // keep the `?next=` destination the router would drop.
        final profile = WebAuth.profile;
        if (profile == null) return null;
        final assigned = profile['role'] as String;
        final requested = rolePath.group(1)!;
        // The server-assigned role always opens. Anything else needs an entry
        // in `Workspaces`, which only the in-session access request can add —
        // so a typed URL still cannot reach another role's data.
        if (requested == assigned) return null;
        final role = _roleNamed(requested);
        if (role != null && Workspaces.canOpen(role)) return null;
        // Unknown or ungranted: send the account to its own home rather than
        // inventing a destination for a role string the backend did not issue.
        final home = _roleNamed(assigned);
        return home == null ? '/login' : home.homeRoute;
      },
      errorBuilder: (context, state) {
        setStatusCode(context, 404);
        return _page(
          const MarketingLayout(
            child: EmptyState(
              title: 'Page not found',
              body: 'This address does not match a Sitewise page.',
              action: ActionLink('Back to home', href: '/'),
            ),
          ),
          title: 'Page not found — Sitewise',
          description: 'This address does not match a Sitewise page.',
        );
      },
      routes: [
        // --- Public ----------------------------------------------------------
        Route(
          path: '/',
          builder: (context, state) => _page(
            const LandingPage(),
            title: 'Sitewise — F&B Location Intelligence',
            description: kSiteDescription,
          ),
        ),
        Route(
          path: '/landing',
          builder: (context, state) => _page(
            const LandingPage(),
            title: 'Sitewise — F&B Location Intelligence',
            description: kSiteDescription,
          ),
        ),
        Route(
          path: '/login',
          builder: (context, state) => _page(
            LoginPage(portal: state.queryParams['portal']),
            title: 'Sign in — Sitewise',
            description:
                'Sign in to Sitewise to compare F&B commercial property by '
                'catchment, competition and affordability.',
          ),
        ),
        // Dedicated entry point for the Agent & Admin portal. Renders the same
        // enhanced sign-in page in staff mode — no second, divergent page.
        Route(
          path: '/staff/signin',
          builder: (context, state) => _page(
            const LoginPage(portal: 'staff'),
            title: 'Staff sign-in — Sitewise',
            description:
                'Agent and administrator sign-in. Staff accounts require '
                'two-factor authentication.',
          ),
        ),
        Route(
          path: '/auth/callback',
          builder: (context, state) => _page(
            const AuthCallbackPage(),
            title: 'Signing in — Sitewise',
          ),
        ),
        Route(
          path: '/signup',
          builder: (context, state) => _page(
            const SignupPage(),
            title: 'Create an account — Sitewise',
            description:
                'Create a Sitewise entrepreneur account and start comparing '
                'F&B commercial properties.',
          ),
        ),
        Route(
          path: '/forgot',
          builder: (context, state) => _page(
            const ForgotPasswordPage(),
            title: 'Reset password — Sitewise',
          ),
        ),
        Route(
          path: '/staff/verify',
          builder: (context, state) => _page(
            const StaffVerifyPage(),
            title: 'Verify your identity — SiteWise',
            description:
                'Enter your current six-digit staff authenticator code.',
          ),
        ),
        // Mandatory TOTP enrollment for staff accounts (first-time setup and
        // post-recovery re-enrollment). No public registration, no OAuth.
        Route(
          path: '/staff/mfa',
          builder: (context, state) => _page(
            const StaffMfaPage(),
            title: 'Secure your staff account — Sitewise',
            description:
                'Set up the authenticator app required for agent and '
                'administrator accounts.',
          ),
        ),
        // New-password screen for Supabase recovery / agent-invite links.
        Route(
          path: '/reset-password',
          builder: (context, state) => _page(
            const ResetPasswordPage(),
            title: 'Choose a new password — Sitewise',
          ),
        ),

        // --- Admin -----------------------------------------------------------
        Route(
          path: '/admin',
          builder: (context, state) => _page(
            const a_dashboard.DashboardPage(),
            title: 'Admin overview — Sitewise',
            description: 'Listing, verification and user activity at a glance.',
          ),
        ),
        Route(
          path: '/admin/users',
          builder: (context, state) => _page(
            const a_users.UsersPage(),
            title: 'Users — Sitewise admin',
            description: 'Every registered account, its role and its status.',
          ),
        ),
        Route(
          path: '/admin/agents',
          builder: (context, state) => _page(
            const AdminAgentsPage(),
            title: 'Agents — Sitewise admin',
            description: 'Issue agent accounts and manage staff access.',
          ),
        ),
        Route(
          path: '/admin/user-detail',
          builder: (context, state) => _page(
            a_user_detail.UserDetailPage(id: state.queryParams['id'] ?? ''),
            title: 'User detail — Sitewise admin',
          ),
        ),
        Route(
          path: '/admin/verification',
          builder: (context, state) => _page(
            const a_verification.VerificationPage(),
            title: 'Verification queue — Sitewise admin',
            description: 'Listing submissions waiting for an administrator.',
          ),
        ),
        Route(
          path: '/admin/verification-detail',
          builder: (context, state) => _page(
            a_verification_detail.VerificationDetailPage(
              id: state.queryParams['id'] ?? '',
            ),
            title: 'Verification detail — Sitewise admin',
          ),
        ),
        Route(
          path: '/admin/listings',
          builder: (context, state) => _page(
            const a_listings.ListingsPage(),
            title: 'Listings — Sitewise admin',
            description: 'Every listing on the platform and its state.',
          ),
        ),
        Route(
          path: '/admin/listing-detail',
          builder: (context, state) => _page(
            a_listing_detail.ListingDetailPage(
              id: state.queryParams['id'] ?? '',
            ),
            title: 'Listing detail — Sitewise admin',
          ),
        ),
        Route(
          path: '/admin/profile',
          builder: (context, state) => _page(
            const a_profile.ProfilePage(),
            title: 'Administrator profile — Sitewise',
          ),
        ),

        // --- Owner -----------------------------------------------------------
        Route(
          path: '/owner',
          builder: (context, state) => _page(
            const o_dashboard.DashboardPage(),
            title: 'Owner overview — Sitewise',
            description: 'Your units, tours and enquiries in one place.',
          ),
        ),
        Route(
          path: '/owner/properties',
          builder: (context, state) => _page(
            const o_properties.PropertiesPage(),
            title: 'Your properties — Sitewise',
          ),
        ),
        Route(
          path: '/owner/property-detail',
          builder: (context, state) => _page(
            o_property_detail.PropertyDetailPage(
              id: state.queryParams['id'] ?? '',
            ),
            title: 'Property — Sitewise owner',
          ),
        ),
        Route(
          path: '/owner/add-property',
          builder: (context, state) => _page(
            o_add_property.AddPropertyPage(editingId: state.queryParams['id']),
            title: 'List a property — Sitewise',
          ),
        ),
        Route(
          path: '/owner/tours',
          builder: (context, state) => _page(
            const o_tours.ToursPage(),
            title: 'Virtual tours — Sitewise owner',
          ),
        ),
        Route(
          path: '/owner/tour-preview',
          builder: (context, state) => _page(
            o_tour_preview.TourPreviewPage(id: state.queryParams['id'] ?? ''),
            title: 'Tour preview — Sitewise owner',
          ),
        ),
        Route(
          path: '/owner/profile',
          builder: (context, state) => _page(
            const o_profile.ProfilePage(),
            title: 'Owner profile — Sitewise',
          ),
        ),

        // --- Entrepreneur ----------------------------------------------------
        Route(
          path: '/entrepreneur',
          builder: (context, state) => _page(
            const e_dashboard.DashboardPage(),
            title: 'Home — Sitewise',
            description:
                'Saved properties, shortlists and recommendations for your '
                'F&B search.',
          ),
        ),
        Route(
          path: '/entrepreneur/preferences',
          builder: (context, state) => _page(
            const e_preferences.PreferencesPage(),
            title: 'Search preferences — Sitewise',
            description:
                'Budget, floor area and property type used to rank listings.',
          ),
        ),
        Route(
          path: '/entrepreneur/explore',
          builder: (context, state) => _page(
            e_explore.ExplorePage(startInMap: state.queryParams['id'] == 'map'),
            title: 'Explore commercial properties — Sitewise',
            description:
                'Filter F&B commercial property by rent, floor area, type and '
                'location, then read the surroundings of each unit.',
          ),
        ),
        Route(
          path: '/entrepreneur/map',
          builder: (context, state) => _page(
            e_map.MapPage(initialId: state.queryParams['id']),
            title: 'Map — Sitewise',
          ),
        ),
        Route(
          path: '/entrepreneur/explanation',
          builder: (context, state) => _page(
            e_explanation.ExplanationPage(
              propertyId: state.queryParams['property'] ?? '',
            ),
            title: 'Why this property — Sitewise',
          ),
        ),
        Route(
          path: '/entrepreneur/property-detail',
          builder: (context, state) => _page(
            e_property_detail.PropertyDetailPage(
              id: state.queryParams['id'] ?? '',
            ),
            title: 'Property detail — Sitewise',
          ),
        ),
        Route(
          path: '/entrepreneur/tour',
          builder: (context, state) => _page(
            e_tour.TourPage(id: state.queryParams['id'] ?? ''),
            title: '360° tour — Sitewise',
          ),
        ),
        Route(
          path: '/entrepreneur/recommendations',
          builder: (context, state) => _page(
            const e_recommendations.RecommendationsPage(),
            title: 'Recommendations — Sitewise',
            description: 'Listings ranked against your stated preferences.',
          ),
        ),
        Route(
          path: '/entrepreneur/compare',
          builder: (context, state) => _page(
            const ComparePage(),
            title: 'Compare properties — Sitewise',
          ),
        ),
        Route(
          path: '/entrepreneur/saved',
          builder: (context, state) => _page(
            const e_saved.SavedPage(),
            title: 'Saved properties — Sitewise',
          ),
        ),
        Route(
          path: '/entrepreneur/my-properties',
          builder: (context, state) => _page(
            const e_my_properties.MyPropertiesPage(),
            title: 'My Properties — Sitewise',
            description: 'Properties you register for your own F&B business.',
          ),
        ),
        Route(
          path: '/entrepreneur/add-property',
          builder: (context, state) => _page(
            const e_add_property.AddPropertyPage(),
            title: 'Register a property — Sitewise',
          ),
        ),
        Route(
          path: '/entrepreneur/report',
          builder: (context, state) => _page(
            e_report.ReportPage(id: state.queryParams['id'] ?? ''),
            title: 'Assessment report — Sitewise',
          ),
        ),
        Route(
          path: '/entrepreneur/profile',
          builder: (context, state) => _page(
            const e_profile.ProfilePage(),
            title: 'Your profile — Sitewise',
          ),
        ),

        // --- Agent -----------------------------------------------------------
        // The staff workspace. Reachable only through `Workspaces`; grants now
        // survive navigation through the selection cookie.
        Route(
          path: '/agent',
          builder: (context, state) => _page(
            const AgentDashboardPage(),
            title: 'Agent overview — Sitewise',
            description: 'Assigned listings, enquiries and performance.',
          ),
        ),
        Route(
          path: '/agent/listings',
          builder: (context, state) => _page(
            const AgentListingsPage(),
            title: 'Assigned listings — Sitewise agent',
          ),
        ),
        Route(
          path: '/agent/property-detail',
          builder: (context, state) => _page(
            AgentPropertyDetailPage(id: state.queryParams['id'] ?? ''),
            title: 'Listing — Sitewise agent',
          ),
        ),
        Route(
          path: '/agent/enquiries',
          builder: (context, state) => _page(
            const AgentEnquiriesPage(),
            title: 'Enquiries — Sitewise agent',
          ),
        ),
        Route(
          path: '/agent/performance',
          builder: (context, state) => _page(
            const AgentPerformancePage(),
            title: 'Performance — Sitewise agent',
          ),
        ),
        Route(
          path: '/agent/profile',
          builder: (context, state) => _page(
            const AgentProfilePage(),
            title: 'Agent profile — Sitewise',
          ),
        ),

        // Unknown browser routes use errorBuilder above.
      ],
    );
  }
}

/// Default meta description, reused by every public route.
const String kSiteDescription =
    'Sitewise — evidence-based F&B commercial property selection. Compare '
    'locations by population, accessibility, competition and demand before '
    'you commit.';

/// Wraps [child] with the document head for that route.
///
/// `Document.head` merges into the `<head>` the server entry point renders, so
/// the title, description and canonical URL are part of the first response
/// instead of being set by script afterwards.
Component _page(
  Component child, {
  required String title,
  String? description,
}) => Component.fragment([
  Document.head(
    title: title,
    meta: {'description': ?description},
  ),
  child,
]);

/// Resolves a role name from the URL or the profile claim.
///
/// Returns null for anything the enum does not define, which is what keeps a
/// forged `role` claim from mapping onto a workspace: the guard treats null as
/// "not authorised" rather than defaulting to the most permissive role.
AppRole? _roleNamed(String? name) {
  if (name == null) return null;
  for (final role in AppRole.values) {
    if (role.name == name) return role;
  }
  return null;
}
