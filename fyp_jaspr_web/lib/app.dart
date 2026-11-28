import 'package:jaspr/jaspr.dart';
import 'package:jaspr_router/jaspr_router.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:sitewise_jaspr_web/core/di/app_locator.dart';
import 'package:sitewise_jaspr_web/features/authentication/data/auth_service.dart';
import 'package:sitewise_jaspr_web/features/authentication/data/dev_auth_bypass.dart';
import 'package:sitewise_jaspr_web/core/routing/landing_routes.dart';
import 'package:sitewise_jaspr_web/core/routing/ssr_service.dart';
import 'package:sitewise_jaspr_web/features/authentication/application/workspaces.dart';
import 'package:sitewise_jaspr_web/features/authentication/presentation/pages/auth_callback_page.dart';
import 'package:sitewise_jaspr_web/shared/presentation/components/ui.dart';
import 'package:sitewise_jaspr_web/shared/presentation/layouts/marketing_layout.dart';
import 'package:sitewise_jaspr_web/shared/presentation/pages/landing_page.dart';
import 'package:sitewise_jaspr_web/features/authentication/presentation/pages/login_page.dart';
import 'package:sitewise_jaspr_web/features/authentication/presentation/pages/signup_page.dart';
import 'package:sitewise_jaspr_web/features/authentication/presentation/pages/forgot_password_page.dart';
import 'package:sitewise_jaspr_web/features/authentication/presentation/pages/staff_mfa_page.dart';
import 'package:sitewise_jaspr_web/features/authentication/presentation/pages/staff_verify_page.dart';
import 'package:sitewise_jaspr_web/features/authentication/presentation/pages/reset_password_page.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/pages/assessment_workspace_page.dart'
    as e_assessment;
import 'package:sitewise_jaspr_web/features/compare/presentation/pages/compare_page.dart';
import 'package:sitewise_jaspr_web/features/dashboard/presentation/pages/entrepreneur_dashboard_page.dart'
    as e_dashboard;
import 'package:sitewise_jaspr_web/features/property_management/presentation/pages/listing_management_denied_page.dart'
    as e_listing_denied;
import 'package:sitewise_jaspr_web/features/property_management/presentation/pages/owner_add_property_page.dart'
    as e_owner_add;
import 'package:sitewise_jaspr_web/features/property_management/presentation/pages/owner_properties_page.dart'
    as e_owner_properties;
import 'package:sitewise_jaspr_web/features/property_management/presentation/pages/owner_property_detail_page.dart'
    as e_owner_detail;
import 'package:sitewise_jaspr_web/features/property_management/presentation/pages/owner_dashboard_page.dart'
    as e_owner_dashboard;
import 'package:sitewise_jaspr_web/features/recommendations/presentation/pages/explanation_page.dart'
    as e_explanation;
import 'package:sitewise_jaspr_web/features/recommendations/presentation/pages/ai_recommendations_page.dart'
    as e_ai;
import 'package:sitewise_jaspr_web/features/listing/presentation/pages/commercial_listing_page.dart'
    as e_listing;
import 'package:sitewise_jaspr_web/features/listing/presentation/pages/explore_page.dart'
    as e_explore;
import 'package:sitewise_jaspr_web/features/recommendations/presentation/pages/preferences_page.dart'
    as e_preferences;
import 'package:sitewise_jaspr_web/features/profile/presentation/pages/entrepreneur_profile_page.dart'
    as e_profile;
import 'package:sitewise_jaspr_web/features/listing/presentation/pages/property_detail_page.dart'
    as e_property_detail;
import 'package:sitewise_jaspr_web/features/recommendations/presentation/pages/property_analysis_page.dart'
    as e_property_analysis;
import 'package:sitewise_jaspr_web/features/recommendations/presentation/pages/recommendations_page.dart'
    as e_recommendations;
import 'package:sitewise_jaspr_web/features/assessment/presentation/pages/report_page.dart'
    as e_report;
import 'package:sitewise_jaspr_web/features/assessment/presentation/pages/reports_page.dart'
    as e_reports;
import 'package:sitewise_jaspr_web/features/assessment/presentation/pages/assessment_report_selector_view.dart'
    as e_report_selector;
import 'package:sitewise_jaspr_web/features/assessment/presentation/pages/report_activity_views.dart'
    as e_report_activity;
import 'package:sitewise_jaspr_web/features/assessment/data/synthetic_preview_gate.dart'
    show syntheticPreviewEnabled, syntheticPreviewPath;
import 'package:sitewise_jaspr_web/features/assessment/presentation/pages/report_harness_page.dart'
    as e_report_harness;
import 'package:sitewise_jaspr_web/features/assessment/presentation/components/m2_workflow_panel.dart'
    show M2WorkflowPanel;
import 'package:sitewise_jaspr_web/features/listing/presentation/pages/saved_page.dart'
    as e_saved;
import 'package:sitewise_jaspr_web/features/panorama_viewer/presentation/pages/tour_page.dart'
    as e_tour;
import 'package:sitewise_jaspr_web/features/administration/presentation/pages/agents_page.dart';
import 'package:sitewise_jaspr_web/features/property_management/presentation/pages/agent_retired_page.dart';
import 'package:sitewise_jaspr_web/features/property_management/presentation/pages/owner_retired_page.dart';
import 'package:sitewise_jaspr_web/features/administration/presentation/pages/campaigns_page.dart'
    as a_campaigns;
import 'package:sitewise_jaspr_web/features/administration/presentation/pages/dashboard_page.dart'
    as a_dashboard;
import 'package:sitewise_jaspr_web/features/administration/presentation/pages/activity_page.dart';
import 'package:sitewise_jaspr_web/features/administration/presentation/pages/listing_detail_page.dart'
    as a_listing_detail;
import 'package:sitewise_jaspr_web/features/administration/presentation/pages/listings_page.dart'
    as a_listings;
import 'package:sitewise_jaspr_web/features/profile/presentation/pages/admin_profile_page.dart'
    as a_profile;
import 'package:sitewise_jaspr_web/features/administration/presentation/pages/surveys_page.dart'
    as a_surveys;
import 'package:sitewise_jaspr_web/features/administration/presentation/pages/user_detail_page.dart'
    as a_user_detail;
import 'package:sitewise_jaspr_web/features/administration/presentation/pages/users_page.dart'
    as a_users;

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
/// ## State management
///
/// Shared state (saved/compare selections, active role, preview mode) lives in
/// the Riverpod notifiers from `shared_logic` — the same providers the mobile
/// app watches. The [ProviderScope] below mounts them with this app's
/// composition overrides (`AppLocator.webOverrides`) and a `UiPersistObserver`
/// that mirrors every saved/compare publish into the selection cookie. Pages
/// read slices with `context.watch(provider.select(…))` and act through
/// `context.read(provider.notifier)`.
///
/// ## Where this router runs
///
/// Entirely **in the browser** (`jaspr: mode: client`): `main.client.dart`
/// mounts `SitewiseApp` from `web/index.html`, and navigation happens
/// client-side through the History API. A hard refresh of a nested route is
/// answered by FastAPI's SPA fallback (it returns `web/index.html`), after
/// which this router boots at the requested URL. There is no server render.
///
/// `WebAuth.profile` is resolved before mounting (`WebAuth.initialize()` in
/// `main.client.dart`), so the redirect guard below never routes with a stale
/// or half-loaded identity: anonymous workspace requests go to
/// `/login?next=…`, role mismatches go to the account's own home, and staff
/// MFA state is enforced by the auth bundle's `enforceStaffAssurance` (with
/// FastAPI independently re-checking every protected API call).
class SitewiseApp extends StatelessComponent {
  const SitewiseApp({super.key});

  @override
  Component build(BuildContext context) {
    // The scope lives here, not in main.client.dart, so the dormant server
    // entry point (`main.server.dart` builds this same component per request)
    // re-seeds the cookie state for each render without its own wiring.
    return ProviderScope(
      overrides: AppLocator.webOverrides(),
      observers: [const UiPersistObserver()],
      child: Router(
        redirect: (context, state) {
          final path = Uri.parse(state.location).path;
          // Public landing sections are real paths, not fragments. `/` and the
          // legacy `/landing` alias are replaced rather than rendered, so the
          // back stack never holds two addresses for the same page and every
          // public navigation URL is a clean path. The query string is kept.
          if (path == '/' || path == '/landing') {
            final uri = Uri.parse(state.location);
            return uri.replace(path: LandingRoutes.home).toString();
          }
          // Retired verification pages (consolidated into Admin Listings and
          // its detail): old links land on the unified review queue, keeping
          // the listing id where one was present.
          if (path == '/admin/ownership' || path == '/admin/verification') {
            return '/admin/listings';
          }
          if (path == '/admin/verification-detail') {
            final id = Uri.parse(state.location).queryParameters['id'];
            return (id == null || id.isEmpty)
                ? '/admin/listings'
                : '/admin/listing-detail?id=${Uri.encodeComponent(id)}';
          }
          // Explore was replaced by Recommendations. Old bookmarks, in-app
          // links and shared URLs keep working: the query string is carried
          // over verbatim so `?q=`, `?id=` and filter parameters survive the
          // move instead of silently resetting the search.
          if (path == '/entrepreneur/explore' ||
              path == '/entrepreneur/explore/') {
            final uri = Uri.parse(state.location);
            return uri
                .replace(path: '/entrepreneur/recommendations')
                .toString();
          }
          final rolePath = RegExp(
            r'^/(entrepreneur|owner|admin|agent)(/|$)',
          ).firstMatch(path);
          if (rolePath == null) return null;
          // Development Demo Mode: render any workspace without a login.
          // FastAPI still authorizes every protected API call, so this grants
          // presentation only — no backend permission is changed.
          if (devAuthBypassEnabled) return null;
          // Anonymous request for a workspace: go to the sign-in screen and keep
          // the destination. FastAPI stays the authorization authority — every
          // protected API call is independently verified against the bearer
          // token, so this only prevents rendering an empty workspace shell.
          final profile = WebAuth.profile;
          if (profile == null) {
            return '/login?next=${Uri.encodeComponent(state.location)}';
          }
          final assigned = _canonicalRoleName(profile['role'] as String?);
          if (assigned == null) {
            // Unsupported or missing role: fail closed rather than inventing a
            // destination for a role string the backend did not issue.
            return '/login';
          }
          final requested = rolePath.group(1)!;
          // Workspace presentation is based on the backend-verified account
          // role. Client-controlled demo grants cannot authorize another role.
          //
          // `owner` is a workspace again, in the sense that matters: an owner
          // account is routed to `/owner`, which explains that the Owner
          // workspace is the SiteWise mobile app. It is NOT re-pointed at the
          // entrepreneur workspace, and an entrepreneur is no longer admitted
          // to it — the two roles have different property authority and must not
          // share a surface.
          if (requested == 'owner' &&
              assigned != 'owner' &&
              assigned != 'admin') {
            final home = _roleNamed(assigned);
            return home == null ? '/login' : home.homeRoute;
          }
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
                action: ActionLink('Back to home', href: LandingRoutes.home),
              ),
            ),
            title: 'Page not found — Sitewise',
            description: 'This address does not match a Sitewise page.',
          );
        },
        routes: [
          // --- Public ----------------------------------------------------------
          // One continuous landing page; each section URL is a real path.
          for (final path in LandingRoutes.paths) _landingRoute(path),
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
            builder: (context, state) =>
                _page(const AuthCallbackPage(), title: 'Signing in — Sitewise'),
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
              description:
                  'Listing, verification and user activity at a glance.',
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
              AdminAgentsPage(
                openInvitation:
                    Uri.parse(state.location).queryParameters['invite'] == '1',
              ),
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
          // --- Administrator operations (five-screen suite) ------------------
          // Ownership reviews, Survey campaigns and
          // Community surveys — the new screens of the five-screen admin
          // suite. Agent management keeps its pre-existing `/admin/agents`
          // route and page class, so no bookmarked URL is replaced.
          Route(
            path: '/admin/campaigns',
            builder: (context, state) => _page(
              const a_campaigns.AdminCampaignsPage(),
              title: 'Survey campaigns — Sitewise admin',
              description:
                  'Area research campaign lifecycles (backend not yet '
                  'provisioned).',
            ),
          ),
          Route(
            path: '/admin/surveys',
            builder: (context, state) => _page(
              const a_surveys.AdminSurveysPage(),
              title: 'Community surveys — Sitewise admin',
              description:
                  'Participant screening and questionnaire preview (no '
                  'response capture).',
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
            builder: (context, state) {
              final id = state.queryParams['id'] ?? '';
              // Keyed by id: navigating between two detail pages must rebuild
              // the state (jaspr reuses the State when the runtime type and
              // position match, and has no didUpdateWidget hook).
              return _page(
                a_listing_detail.ListingDetailPage(
                  key: ValueKey('listing-detail-$id'),
                  id: id,
                ),
                title: 'Listing detail — Sitewise admin',
              );
            },
          ),
          Route(
            path: '/admin/activity',
            builder: (context, state) => _page(
              const AdminActivityPage(),
              title: 'System activity — Sitewise admin',
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
          // Listing drafts and details use the canonical owner API. Capture,
          // tours and profile flows remain in the existing mobile workspace.
          for (final retiredOwnerPath in const [
            '/owner/tours',
            '/owner/tour-preview',
            '/owner/profile',
            '/owner/capture',
          ])
            Route(
              path: retiredOwnerPath,
              builder: (context, state) => _page(
                const OwnerRetiredPage(),
                title: 'Your workspace is in the SiteWise app',
                description:
                    'The SiteWise Owner / Agent workspace moved to the '
                    'SiteWise mobile application.',
              ),
            ),
          Route(
            path: '/owner',
            builder: (context, state) => _page(
              const e_owner_dashboard.DashboardPage(),
              title: 'Owner dashboard — Sitewise',
              description:
                  'Manage commercial property listings and their review status.',
            ),
          ),
          Route(
            path: '/owner/add-property',
            builder: (context, state) => _page(
              e_owner_add.AddPropertyPage(
                key: ValueKey(state.queryParams['id']),
                editingId: state.queryParams['id'],
              ),
              title: 'Add commercial property — Sitewise',
              description: 'Create or update an owner property draft.',
            ),
          ),
          Route(
            path: '/owner/properties',
            builder: (context, state) => _page(
              const e_owner_properties.PropertiesPage(),
              title: 'My commercial properties — Sitewise',
            ),
          ),
          Route(
            path: '/owner/property-detail',
            builder: (context, state) => _page(
              e_owner_detail.PropertyDetailPage(
                id: state.queryParams['id'] ?? '',
              ),
              title: 'Property detail — Sitewise',
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
          // Combined Explore: filters → Leaflet map + listings → radius →
          // nearby + transport. `?id=map` scrolls to the map section (legacy
          // deep link); any other `?id=` preselects that property on entry.
          // Keyed by id so navigating between two preselected entries rebuilds
          // the state (jaspr reuses the State when type and position match).
          Route(
            path: '/entrepreneur/explore',
            builder: (context, state) {
              final id = state.queryParams['id'];
              return _page(
                e_explore.ExplorePage(
                  key: ValueKey('explore-${id ?? ''}'),
                  startInMap: id == 'map',
                  initialPropertyId: (id == null || id == 'map') ? null : id,
                ),
                title: 'Explore commercial properties — Sitewise',
                description:
                    'Filter F&B commercial property by rent, floor area, type and '
                    'location, then read the surroundings of each unit.',
              );
            },
          ),
          // Backward compatibility: the retired standalone map screen now
          // resolves to the combined Explore page with the property (when one
          // was linked) preselected, so old links never break.
          Route(
            path: '/entrepreneur/map',
            builder: (context, state) {
              final id = state.queryParams['id'];
              return _page(
                e_explore.ExplorePage(
                  key: ValueKey('explore-map-${id ?? ''}'),
                  startInMap: true,
                  initialPropertyId: (id == null || id == 'map') ? null : id,
                ),
                title: 'Explore commercial properties — Sitewise',
              );
            },
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
          // AI recommendations: the personalised Layer 2/3 pipeline
          // (saved preferences, durable batches, optional SHAP section).
          Route(
            path: '/entrepreneur/ai-recommendations',
            builder: (context, state) => _page(
              e_ai.AiRecommendationsPage(
                resultId: state.queryParams['result'] ?? '',
              ),
              title: 'AI recommendations — Sitewise',
            ),
          ),
          // The verified commercial listing behind a recommendation, keyed by
          // the NUMERIC rental id (`fyp.rental_properties.id`). Distinct from
          // `/entrepreneur/property-detail`, which is keyed by the canonical
          // research id. The backend serves 404 unless the listing is both
          // approved and published, so unpublished rentals never render.
          Route(
            path: '/entrepreneur/listing',
            builder: (context, state) => _page(
              e_listing.CommercialListingPage(
                key: ValueKey('listing-${state.queryParams['id'] ?? ''}'),
                id: state.queryParams['id'] ?? '',
              ),
              title: 'Commercial listing — Sitewise',
              description:
                  'The verified rental listing linked to a recommended property.',
            ),
          ),
          Route(
            path: '/entrepreneur/property-detail',
            builder: (context, state) => _page(
              e_property_detail.PropertyDetailPage(
                // The business type is part of the key: switching the
                // entrepreneur's selection must rebuild the insights future,
                // not reuse the previous category's explanation.
                key: ValueKey(
                  'property-detail-${state.queryParams['id'] ?? ''}'
                  '-${state.queryParams['businessType'] ?? ''}',
                ),
                id: state.queryParams['id'] ?? '',
                // Optional recommendation result: when present, the page also
                // explains why THIS unit matched the entrepreneur's saved
                // preferences, using the persisted Layer 2 result.
                resultId: state.queryParams['result'] ?? '',
                // The applied search filters, carried from Recommendations as
                // the raw `?filters=` JSON string (client components accept
                // only primitive parameters; the page parses it itself).
                // They power an honest "your filters vs this property" table;
                // a saved ?result= explanation always takes precedence.
                appliedFiltersJson: state.queryParams['filters'] ?? '',
                // The selected F&B business type, carried from Recommendations.
                businessType: state.queryParams['businessType'] ?? '',
              ),
              title: 'Property detail — Sitewise',
            ),
          ),
          // Source-backed evidence drill-down (Q1–Q5 perspectives) for one
          // catalogue property; keyed by id so navigating between two
          // properties rebuilds the futures instead of showing stale data.
          Route(
            path: '/entrepreneur/property-analysis',
            builder: (context, state) => _page(
              e_property_analysis.PropertyAnalysisPage(
                key: ValueKey(
                  'property-analysis-${state.queryParams['id'] ?? ''}',
                ),
                id: state.queryParams['id'] ?? '',
              ),
              title: 'Location analysis — Sitewise',
              description:
                  'Source-backed property competition, accessibility, customer '
                  'demand, built environment and price context.',
            ),
          ),
          Route(
            path: '/entrepreneur/tour',
            builder: (context, state) => _page(
              e_tour.TourPage(id: state.queryParams['id'] ?? ''),
              title: '360° tour — Sitewise',
            ),
          ),
          // Canonical discovery destination (replaced Explore). `?id=<catalogue
          // id>` is honoured so the old `/entrepreneur/explore?id=...` links
          // still open with that unit selected; `?id=map` simply lands on the
          // list, because the location panel is always on screen here.
          Route(
            path: '/entrepreneur/recommendations',
            builder: (context, state) {
              final id = state.queryParams['id'];
              return _page(
                e_recommendations.RecommendationsPage(
                  key: ValueKey('recommendations-${id ?? ''}'),
                  initialPropertyId: (id == null || id == 'map') ? null : id,
                ),
                title: 'Recommendations — Sitewise',
                description:
                    'Listings ranked against your stated preferences, with '
                    'requirement-level match reasons and location intelligence.',
              );
            },
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
          // My Properties LEFT the Entrepreneur workspace. Registering and
          // managing listings is the Provider (Owner / Agent) job and runs in
          // the SiteWise mobile app. Both routes stay registered as a denied,
          // explanatory landing: an old bookmark cannot reach a management
          // form, and nothing here reads a listing id or another account's
          // data. The sidebar destination is gone with them (navigation.dart).
          for (final retiredListingPath in const [
            '/entrepreneur/my-properties',
            '/entrepreneur/add-property',
          ])
            Route(
              path: retiredListingPath,
              builder: (context, state) => _page(
                const e_listing_denied.ListingManagementDeniedPage(),
                title: 'My Properties — Sitewise',
                description:
                    'Listing management is a Property Owner / Agent capability '
                    'in the SiteWise mobile application.',
              ),
            ),
          Route(
            path: '/entrepreneur/reports',
            builder: (context, state) => _page(
              const e_reports.ReportsPage(),
              title: 'Reports — Sitewise',
              description: 'Your saved property assessment reports.',
            ),
          ),
          Route(
            path: '/entrepreneur/cafe-report/view',
            builder: (context, state) => _page(
              e_report_activity.CafeReportView(
                assessmentId: state.queryParams['assessment'] ?? '',
              ),
              title: 'Café demand suitability report — Sitewise',
            ),
          ),
          Route(
            path: '/entrepreneur/cafe-report',
            builder: (context, state) => _page(
              const e_report_selector.AssessmentReportSelectorView(),
              title: 'Select assessment to view report — Sitewise',
            ),
          ),
          Route(
            path: '/entrepreneur/activity-history',
            builder: (context, state) => _page(
              e_report_activity.ActivityHistoryView(
                assessmentId: state.queryParams['assessment'] ?? '',
              ),
              title: 'Activity history — Sitewise',
            ),
          ),
          // --- Development-only --------------------------------------------
          // Present only in a build that opted in AND is served from a local
          // origin. In any other build the whole branch is compiled out, so the
          // path falls through to the not-found page. This route mounts the
          // real report component with synthetic inputs; it grants no report
          // authority, and the Q01 chart it shows stays SYNTHETIC_PREVIEW_ONLY
          // with a HELD admission block.
          if (syntheticPreviewEnabled)
            Route(
              path: syntheticPreviewPath,
              builder: (context, state) => _page(
                const e_report_harness.ReportHarnessPage(),
                title: 'Assessment report — Sitewise (development harness)',
                description:
                    'Development harness. Synthetic inputs, real report layout.',
              ),
            ),
          Route(
            path: '/entrepreneur/assessments/history',
            builder: (context, state) => _page(
              // The engine activity shell (M2ActivityPanel) is the history
              // surface now; ActivityHistoryPage is its embedded view and
              // needs fetched activities, so the route goes through the shell.
              e_report_activity.ActivityHistoryView(
                assessmentId: state.queryParams['assessment'] ?? '',
              ),
              title: 'Assessment history — Sitewise',
              description:
                  'Every location assessment saved to your account, with its '
                  'real progress and report availability.',
            ),
          ),
          // M2 research workflow (live API). The workspace above is the
          // location-assessment state machine; M2 assessments are separate
          // records in Dss, so they get their own route rather than being
          // faked inside the five-stage workspace.
          Route(
            path: '/entrepreneur/m2-workflow',
            builder: (context, state) => _page(
              M2WorkflowPanel(
                assessmentId: state.queryParams['assessment'] ?? '',
              ),
              title: 'M2 research workflow — Sitewise',
              description:
                  'Answer the authorized M2 instrument, run the candidate BDJ '
                  'evaluation, confirm the business understanding and record a '
                  'research objective against the live service.',
            ),
          ),
          // The **Assessment** top-bar destination (PROJECT1 v1.5).
          //
          // With no `?id=` this is the four-step research flow: the assessment
          // overview list, or one of its steps via `?step=1..4`, scoped to the
          // assessment named by `?assessment=`.
          //
          // With `?id=` it is still the five-stage property workspace, byte for
          // byte the same page as before — every saved link, dashboard KPI and
          // Explore/Saved hand-off keeps working.
          Route(
            path: '/entrepreneur/assessments',
            builder: (context, state) => _page(
              e_assessment.AssessmentWorkspacePage(
                propertyId: state.queryParams['id'] ?? '',
                stage: state.queryParams['stage'] ?? '',
                businessType: state.queryParams['businessType'] ?? '',
              ),
              title: 'Assessment workspace — Sitewise',
              description:
                  'Select a property, record your business preferences, review '
                  'the location evidence and open the assessment report.',
            ),
          ),

          Route(
            path: '/entrepreneur/profile',
            builder: (context, state) => _page(
              const e_profile.ProfilePage(),
              title: 'Your profile — Sitewise',
            ),
          ),

          // --- Retired Agent workspace -----------------------------------------
          // Property management is the Flutter Owner / Agent app now. Every
          // former `/agent/*` path resolves to a static notice, so an old
          // bookmark can never reach a listing record, a draft or a manager
          // identity through the browser. No query parameter is read here.
          for (final retiredPath in const [
            '/agent',
            '/agent/listings',
            '/agent/property-detail',
            '/agent/profile',
          ])
            Route(
              path: retiredPath,
              builder: (context, state) => _page(
                const AgentRetiredPage(),
                title: 'Property management is in the SiteWise app',
                description:
                    'The Owner / Agent workspace moved to the SiteWise mobile '
                    'application.',
              ),
            ),

          Route(
            path: '/entrepreneur/report',
            builder: (context, state) => _page(
              e_report.ReportPage(id: state.queryParams['id'] ?? ''),
              title: 'Assessment report — Sitewise',
            ),
          ),
        ],
      ),
    );
  }
}

/// Default meta description, reused by every public route.
const String kSiteDescription =
    'Sitewise — evidence-based F&B commercial property selection. Compare '
    'locations by population, accessibility, competition and demand before '
    'you commit.';

/// Every public landing path renders the SAME component. No second landing
/// page and no second router: only the URL path changes, and `LandingPage`
/// uses it to scroll the matching section of the continuous page.
Route _landingRoute(String path) => Route(
      path: path,
      builder: (context, state) => _page(
        const LandingPage(),
        title: 'Sitewise — F&B Location Intelligence',
        description: kSiteDescription,
      ),
    );

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
  Document.head(title: title, meta: {'description': ?description}),
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

/// Mirrors the backend's legacy alias normalisation
/// (`sitewise.domain.rbac.canonical_role`) so a session mirror written before
/// canonicalisation still routes to the canonical workspace. Anything the
/// four-role model does not define returns null and fails closed.
///
/// `property_owner` resolves to `owner`, not `entrepreneur`: the two are
/// distinct roles now, and routing an owner into the entrepreneur workspace
/// would hand them a surface with no property authority.
String? _canonicalRoleName(String? name) => switch (name) {
  'administrator' => 'admin',
  'property_owner' || 'propertyowner' || 'landlord' => 'owner',
  'user' => 'entrepreneur',
  'owner' || 'entrepreneur' || 'agent' || 'admin' => name,
  _ => null,
};
