import 'package:flutter/material.dart';

import 'package:fyp/core/routing/auth_route_guard.dart';
import 'package:fyp/features/assessment/presentation/home_screen.dart';
import 'package:fyp/features/assessment/presentation/questionnaire_screen.dart';
import 'package:fyp/features/assessment/presentation/review_screen.dart';
import 'package:fyp/features/authentication/presentation/pages/forgot_password_mobile_page.dart';
import 'package:fyp/features/authentication/presentation/pages/mobile_auth_page.dart';
import 'package:fyp/features/authentication/presentation/pages/signup_mobile_page.dart';
import 'package:fyp/features/authentication/presentation/widgets/auth_tabs.dart';
import 'package:fyp/features/onboarding/presentation/pages/onboarding_flow_page.dart';
import 'package:fyp/core/routing/app_start_gate.dart';
import 'package:fyp/shared/presentation/layouts/entrepreneur_tab_host.dart';
import 'package:fyp/features/assessment/presentation/pages/entrepreneur_assessment_summary_mobile_page.dart';
import 'package:fyp/features/recommendations/presentation/pages/entrepreneur_ai_recommendations_mobile_page.dart';
import 'package:fyp/features/compare/presentation/pages/entrepreneur_compare_mobile_page.dart';
import 'package:fyp/features/assessment/presentation/pages/entrepreneur_evidence_mobile_page.dart';
import 'package:fyp/shared/presentation/components/landing_mobile_page.dart';
import 'package:fyp/features/profile/presentation/pages/entrepreneur_preferences_mobile_page.dart';
import 'package:fyp/features/listing/presentation/pages/entrepreneur_property_detail_mobile_page.dart';
import 'package:fyp/features/listing/presentation/pages/entrepreneur_explore_mobile_page.dart';
import 'package:fyp/features/assessment/presentation/pages/entrepreneur_report_mobile_page.dart';
import 'package:fyp/features/profile/presentation/pages/entrepreneur_favourites_mobile_page.dart';
import 'package:fyp/features/panorama_viewer/presentation/pages/entrepreneur_tour_mobile_page.dart';
import 'package:fyp/features/panorama_viewer/presentation/pages/property_panorama_mobile_page.dart';
import 'package:fyp/features/property_management/presentation/pages/sitewise_add_property_mobile_page.dart';
import 'package:fyp/features/authentication/presentation/pages/provider_mfa_mobile_page.dart';
import 'package:fyp/features/property_management/presentation/pages/provider_property_detail_mobile_page.dart';
import 'package:fyp/features/property_management/presentation/pages/provider_submission_success_page.dart';
import 'package:fyp/features/property_verification/presentation/pages/provider_verification_mobile_page.dart';
import 'package:fyp/features/property_management/presentation/pages/property_management_moved_page.dart';
import 'package:fyp/shared/presentation/layouts/provider_tab_host.dart';
import 'package:fyp/shared/presentation/components/not_found_mobile_page.dart';
import 'package:fyp/features/capture_360/presentation/pages/ar_capture_mobile_page.dart';
import 'package:fyp/features/panorama_viewer/presentation/pages/tour_preview_mobile_page.dart';

/// Centralised route table for the Flutter app (mobile tree only).
///
/// The web tree that used to share this table lives in the Jaspr app
/// (`fyp_jaspr_web`) — its routes are declared in `lib/app.dart` there. This
/// table now maps every route straight to its mobile page; detail ids still
/// travel as `settings.arguments`.
/// Maps a route to the shell entry that should appear selected.
///
/// Detail and capture routes highlight their parent section, so the bottom
/// nav still shows where you are when you drill into a record. (The Jaspr
/// web app carries its own copy in `navigation.dart` — shells do not share
/// code across the two apps.)
String parentShellRoute(String route) {
  const parents = {
    // Provider workspace. Add is a real dock destination now, so the form
    // highlights Add rather than Home; a property is opened from Listings.
    // Performance is a Dashboard shortcut, not a tab, so Home stays selected.
    '/provider/add-property': '/provider/add-property',
    '/provider/property-detail': '/provider/listings',
    '/provider/inspection': '/provider/listings',
    '/provider/requests': '/provider/requests',
    '/provider/performance': '/provider',
    // Verification is reached from Profile, and MFA is a step of whichever
    // protected staff flow pushed it — both keep Profile selected.
    '/provider/verification': '/provider/profile',
    '/provider/mfa': '/provider/profile',
    // Detail routes highlight their owning tab in the five-tab model. The
    // shortlist and the property-record shortcuts all belong to Favourites,
    // which is what the retired `/entrepreneur/spaces` tab became.
    '/entrepreneur/preferences': '/entrepreneur/profile',
    '/entrepreneur/saved': '/entrepreneur/favourites',
    '/entrepreneur/spaces': '/entrepreneur/favourites',
    '/entrepreneur/add-property': '/entrepreneur/favourites',
    '/owner/capture': '/entrepreneur/favourites',
    '/entrepreneur/compare': '/entrepreneur/favourites',
    // Discovery is the Recommendations tab. Every retired discovery route
    // (Explore, property detail, tour) highlights it, and the legacy
    // `/entrepreneur/explore` path maps onto it so an old link never lands on
    // a tab that no longer exists.
    '/entrepreneur/explore': '/entrepreneur/recommendations',
    '/entrepreneur/property-detail': '/entrepreneur/recommendations',
    '/entrepreneur/tour': '/entrepreneur/recommendations',
    '/entrepreneur/panorama': '/entrepreneur/recommendations',
    '/entrepreneur/report': '/entrepreneur/assess',
    // The Option A assessment flow keeps the Assess tab highlighted.
    '/entrepreneur/assessment-setup': '/entrepreneur/assess',
    '/entrepreneur/assessment-evidence': '/entrepreneur/assess',
    '/entrepreneur/assessment-summary': '/entrepreneur/assess',
    AppRoutes.assessmentHome: '/entrepreneur/assess',
    AppRoutes.assessmentQuestionnaire: '/entrepreneur/assess',
    AppRoutes.assessmentReview: '/entrepreneur/assess',
    // The 360° preview flow is role-neutral shared work; it is entered from
    // a property tour, so it highlights the discovery tab.
    '/tour-preview': '/entrepreneur/recommendations',
  };
  // Normalise a trailing slash or query string before lookup, so a deep link
  // cannot silently fall through to "no tab selected".
  final normalized = Uri.parse(route).path;
  final path = normalized.length > 1 && normalized.endsWith('/')
      ? normalized.substring(0, normalized.length - 1)
      : normalized;
  return parents[path] ?? path;
}

abstract final class AppRoutes {
  static final pageObserver = RouteObserver<PageRoute<dynamic>>();
  static const assessmentHome = '/entrepreneur/customer-assessments';
  static const assessmentQuestionnaire = '$assessmentHome/questionnaire';
  static const assessmentReview = '$assessmentHome/review';

  /// Every route is generated behind [AuthGuard] except the public ones, so a
  /// manual `pushNamed`, a restored deep link and an expired session all
  /// reach the same decision — `AppStartGate` alone could never cover them.
  ///
  /// No state is threaded through here: the root `MultiProvider` sits above
  /// the navigator, so every page and guard resolves the shared view models
  /// from the widget tree.
  static Route<dynamic>? onGenerateRoute(RouteSettings settings) {
    final (RouteAccess access, Widget Function() page) entry = switch (settings
        .name) {
      // Startup decision point: verify session -> auth / onboarding / home.
      '/' => (RouteAccess.public, () => const AppStartGate()),
      // Public landing (kept reachable for demos and deep links).
      '/landing' => (RouteAccess.public, () => const LandingMobilePage()),
      // Authentication. `arguments` = 'login' | 'signUp'.
      // Registration is the three-step funnel. Mapping the existing
      // 'signUp' argument here keeps every current entry point (landing,
      // onboarding and deep links) working without changing those screens or
      // adding a second navigation stack.
      '/auth' => (
        RouteAccess.public,
        () => settings.arguments == 'signUp'
            ? const SignupMobilePage()
            : const MobileAuthPage(initialTab: AuthTab.login),
      ),
      // Direct deep link to the funnel. Kept as its own public route so a
      // pending-verification link or a restored session can target it.
      '/signup' => (RouteAccess.public, () => const SignupMobilePage()),
      '/forgot-password' => (
        RouteAccess.public,
        () => const ForgotPasswordMobilePage(),
      ),
      // Onboarding belongs AFTER sign-in: it is part of the workspace, not
      // the pre-registration funnel.
      '/onboarding' => (
        RouteAccess.workspace,
        () => const OnboardingFlowPage(),
      ),
      '/tour-preview' => (
        RouteAccess.workspace,
        () =>
            TourPreviewMobilePage(tourId: settings.arguments as String? ?? ''),
      ),
      // Guided 360° capture for one of the owner's listings. Arguments carry
      // the listing id and name; a bare id (deep link) still resolves.
      '/owner/capture' => (
        RouteAccess.workspace,
        () => ArCaptureMobilePage(
          request: settings.arguments is ArCaptureRequest
              ? settings.arguments as ArCaptureRequest
              : ArCaptureRequest(
                  propertyId: settings.arguments as String? ?? '',
                ),
        ),
      ),
      // Owner / Agent provider workspace. This is the ONLY place property
      // management lives now: the Jaspr web agent workspace is retired.
      '/provider' => (
        RouteAccess.workspace,
        () => const ProviderTabHost(initialRoute: '/provider'),
      ),
      '/provider/listings' => (
        RouteAccess.workspace,
        () => const ProviderTabHost(initialRoute: '/provider/listings'),
      ),
      '/provider/requests' => (
        RouteAccess.workspace,
        () => const ProviderTabHost(initialRoute: '/provider/requests'),
      ),
      '/provider/profile' => (
        RouteAccess.workspace,
        () => const ProviderTabHost(initialRoute: '/provider/profile'),
      ),
      '/provider/performance' => (
        RouteAccess.workspace,
        () => const ProviderTabHost(initialRoute: '/provider/performance'),
      ),
      // The Agent task queue — the third destination of the agent dock, built
      // from the assignments and verification records this agent actually
      // holds. `ProviderTabHost` resolves a non-agent here to the dashboard:
      // the projection behind it is the agent's assignment view, so there is
      // nothing honest to show another role.
      '/provider/tasks' => (
        RouteAccess.workspace,
        () => const ProviderTabHost(initialRoute: '/provider/tasks'),
      ),
      // `/provider/enquiries` and `/provider/schedule` are deliberately NOT
      // registered: the Enquiries and Schedule screens were removed from the
      // mobile Provider workspace, and an old deep link falls through to the
      // catch-all not-found page below instead of resurrecting a removed
      // screen. The backend enquiry endpoints and records are untouched.
      // Account-level provider verification. Distinct from per-listing
      // verification: this is the provider's own standing with SiteWise, and
      // the screen renders the real server status rather than a placeholder.
      '/provider/verification' => (
        RouteAccess.workspace,
        () => const ProviderVerificationMobilePage(),
      ),
      // Second-factor step for the staff (Agent) workspace. An
      // `MfaEntryRequest` argument means it is a SIGN-IN / session-restore
      // step that must hand off to the dashboard; without one it is an
      // in-workspace step-up that pops back to the refused request.
      '/provider/mfa' => (
        RouteAccess.workspace,
        () => ProviderMfaMobilePage(
          entry: settings.arguments is MfaEntryRequest
              ? settings.arguments as MfaEntryRequest
              : null,
        ),
      ),
      // The single Add Property form for BOTH provider roles — same screen,
      // fields, validation and endpoints, and the same draft, photo,
      // enrichment and submission flow the owner experience already used.
      // Ownership vs. agent assignment is decided by the backend from the
      // verified token, so no per-role create route exists.
      '/provider/add-property' => (
        RouteAccess.workspace,
        () => SitewiseAddPropertyMobilePage(
          // Resume a saved draft: arguments = fyp.rental_properties id.
          initialDraftId: settings.arguments as String?,
        ),
      ),
      '/provider/property-detail' || '/provider/inspection' => (
        RouteAccess.workspace,
        () => ProviderPropertyDetailMobilePage(
          inspectionFirst: settings.name == '/provider/inspection',
          listingId: int.tryParse('${settings.arguments ?? ''}') ?? 0,
        ),
      ),
      // Post-submission confirmation for the Agent's Admin verification.
      // Arguments = fyp.rental_properties id. Reached ONLY after the backend
      // has confirmed a submission; the status line is the backend's stage.
      '/provider/submission-success' => (
        RouteAccess.workspace,
        () => ProviderSubmissionSuccessPage(
          propertyId: int.tryParse('${settings.arguments ?? ''}') ?? 0,
          stage: 'pending_admin_review',
        ),
      ),
      // Entrepreneur
      '/entrepreneur' => (
        RouteAccess.workspace,
        () => const EntrepreneurTabHost(initialRoute: '/entrepreneur'),
      ),
      // Material 3 five-tab workspace: Assess and Favourites.
      '/entrepreneur/assess' => (
        RouteAccess.workspace,
        () => const EntrepreneurTabHost(initialRoute: '/entrepreneur/assess'),
      ),
      '/entrepreneur/favourites' => (
        RouteAccess.workspace,
        () =>
            const EntrepreneurTabHost(initialRoute: '/entrepreneur/favourites'),
      ),
      // Retired tab path: it opens the tab that replaced it, so an old deep
      // link lands on Favourites instead of the not-found page.
      '/entrepreneur/spaces' => (
        RouteAccess.workspace,
        () =>
            const EntrepreneurTabHost(initialRoute: '/entrepreneur/favourites'),
      ),
      '/entrepreneur/add-property' => (
        RouteAccess.workspace,
        () => const PropertyManagementMovedPage(),
      ),
      assessmentHome => (RouteAccess.workspace, () => const HomeScreen()),
      assessmentQuestionnaire => (
        RouteAccess.workspace,
        () => QuestionnaireScreen(
          assessmentId: settings.arguments as String? ?? '',
        ),
      ),
      assessmentReview => (
        RouteAccess.workspace,
        () => ReviewScreen(
          assessmentId: settings.arguments as String? ?? '',
        ),
      ),
      '/entrepreneur/preferences' => (
        RouteAccess.workspace,
        () => const EntrepreneurPreferencesMobilePage(),
      ),
      // Legacy discovery path. Recommendations replaced Listing/Explore, but
      // the old path stays resolvable: `?map`-style arguments still open the
      // map surface, everything else opens the Recommendations tab.
      '/entrepreneur/explore' => (
        RouteAccess.workspace,
        () => settings.arguments == 'map'
            ? const EntrepreneurExploreMobilePage(startInMap: true)
            : const EntrepreneurTabHost(
                initialRoute: '/entrepreneur/recommendations',
              ),
      ),
      '/entrepreneur/property-detail' => (
        RouteAccess.workspace,
        () => EntrepreneurPropertyDetailMobilePage(
          propertyId: settings.arguments is Map
              ? '${(settings.arguments as Map)['propertyId'] ?? ''}'
              : (settings.arguments as String? ?? ''),
          resultId: settings.arguments is Map
              ? (settings.arguments as Map)['resultId']?.toString()
              : null,
        ),
      ),
      '/entrepreneur/tour' => (
        RouteAccess.workspace,
        () => EntrepreneurTourMobilePage(
          propertyId: settings.arguments as String? ?? '',
        ),
      ),
      // Immersive 360° viewer for a server-verified catalogue panorama.
      // arguments: {'url': <ready panorama URL>, 'title': <property title>}.
      '/entrepreneur/panorama' => (
        RouteAccess.workspace,
        () {
          final args = settings.arguments;
          final url = args is Map ? '${args['url'] ?? ''}' : '${args ?? ''}';
          final title = args is Map ? '${args['title'] ?? ''}' : '';
          return PropertyPanoramaMobilePage(
            panoramaUrl: url,
            propertyTitle: title,
          );
        },
      ),
      '/entrepreneur/recommendations' => (
        RouteAccess.workspace,
        () => EntrepreneurTabHost(
          initialRoute: '/entrepreneur/recommendations',
          initialArguments: settings.arguments,
        ),
      ),
      // AI recommendations: the personalised Layer 2/3 pipeline (saved
      // preferences + durable batches + SHAP-backed explanations).
      '/entrepreneur/ai-recommendations' => (
        RouteAccess.workspace,
        () => const EntrepreneurAiRecommendationsMobilePage(),
      ),
      '/entrepreneur/compare' => (
        RouteAccess.workspace,
        () => const EntrepreneurCompareMobilePage(),
      ),
      // Old shortlist path. It renders the Favourites tab's own screen rather
      // than a second list implementation, so there is exactly one saved
      // property list in the app.
      '/entrepreneur/saved' => (
        RouteAccess.workspace,
        () => const EntrepreneurFavouritesMobilePage(),
      ),
      '/entrepreneur/report' => (
        RouteAccess.workspace,
        () => EntrepreneurReportMobilePage(
          propertyId: settings.arguments as String? ?? '',
        ),
      ),
      // Legacy deep link kept resolvable. The old Option A setup page is gone;
      // the feature questionnaire home owns Start/Resume now, so an old link
      // (or a saved shortcut) lands there instead of on a not-found page.
      '/entrepreneur/assessment-setup' => (
        RouteAccess.workspace,
        () => const HomeScreen(),
      ),
      '/entrepreneur/assessment-evidence' => (
        RouteAccess.workspace,
        () => const EntrepreneurEvidenceMobilePage(),
      ),
      '/entrepreneur/assessment-summary' => (
        RouteAccess.workspace,
        () => const EntrepreneurAssessmentSummaryMobilePage(),
      ),
      '/entrepreneur/profile' => (
        RouteAccess.workspace,
        () => const EntrepreneurTabHost(initialRoute: '/entrepreneur/profile'),
      ),
      // Unknown deep links get a dedicated not-found destination instead of a
      // silent dashboard fallback: the user sees what failed and how to leave.
      // The page carries no sensitive content, so it is public.
      _ => (
        RouteAccess.public,
        () => NotFoundMobilePage(attemptedRoute: settings.name),
      ),
    };

    return MaterialPageRoute(
      settings: settings,
      builder: (_) => AuthGuard(
        access: entry.$1,
        // Named explicitly: the guard decides which workspace may paint this
        // route, and it must not have to guess the route from the widget tree.
        routeName: settings.name,
        builder: (_) => entry.$2(),
      ),
    );
  }

  /// Cold deep links boot straight into the requested route instead of
  /// stacking it on top of '/'. Flutter's default pushes a '/' route beneath
  /// every multi-segment initialRoute, which would leave the startup gate
  /// under the not-found page and wrongly offer "Go back" into it. Each
  /// route's [AuthGuard] already performs the session checks that gate would.
  static List<Route<dynamic>> generateInitialRoutes(String initialRoute) {
    // The table ends in a catch-all not-found entry, so every initialRoute
    // resolves.
    return [onGenerateRoute(RouteSettings(name: initialRoute))!];
  }
}
