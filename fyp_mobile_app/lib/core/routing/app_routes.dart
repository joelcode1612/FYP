import 'package:flutter/material.dart';

import 'auth_route_guard.dart';
import '../../presentation/mobile/auth/pages/forgot_password_mobile_page.dart';
import '../../presentation/mobile/auth/pages/mobile_auth_page.dart';
import '../../presentation/mobile/auth/widgets/auth_tabs.dart';
import '../../presentation/mobile/onboarding/pages/onboarding_flow_page.dart';
import '../../presentation/mobile/start/app_start_gate.dart';
import '../../presentation/mobile/shell/entrepreneur_tab_host.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_assessment_questions_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_assessment_summary_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_ai_recommendations_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_compare_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_evidence_mobile_page.dart';
import '../../presentation/mobile/landing/pages/landing_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_preferences_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_property_detail_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_recommendations_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_report_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_saved_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_tour_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/sitewise_add_property_mobile_page.dart';
import '../../presentation/shared/capture/panorama_capture_page.dart';
import '../../presentation/shared/pages/not_found_mobile_page.dart';
import '../../presentation/shared/tour/tour_preview_mobile_page.dart';

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
    // Detail routes highlight their owning tab in the five-tab model.
    '/entrepreneur/preferences': '/entrepreneur/profile',
    '/entrepreneur/saved': '/entrepreneur/spaces',
    '/entrepreneur/add-property': '/entrepreneur/spaces',
    '/entrepreneur/compare': '/entrepreneur/spaces',
    '/entrepreneur/recommendations': '/entrepreneur/explore',
    '/entrepreneur/property-detail': '/entrepreneur/explore',
    '/entrepreneur/tour': '/entrepreneur/explore',
    '/entrepreneur/report': '/entrepreneur/assess',
    // The Option A assessment flow keeps the Assess tab highlighted.
    '/entrepreneur/assessment-setup': '/entrepreneur/assess',
    '/entrepreneur/assessment-evidence': '/entrepreneur/assess',
    '/entrepreneur/assessment-summary': '/entrepreneur/assess',
    // The 360° capture and preview flow is role-neutral shared work; it is
    // entered from a property tour, so it highlights the Listing tab.
    '/capture': '/entrepreneur/explore',
    '/tour-preview': '/entrepreneur/explore',
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
      '/auth' => (
        RouteAccess.public,
        () => MobileAuthPage(
          initialTab: settings.arguments == 'signUp'
              ? AuthTab.signUp
              : AuthTab.login,
        ),
      ),
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
      // Shared 360° capture + preview flow (device-bound, no role namespace).
      '/capture' => (
        RouteAccess.workspace,
        () => PanoramaCapturePage(propertyId: settings.arguments as String?),
      ),
      '/tour-preview' => (
        RouteAccess.workspace,
        () =>
            TourPreviewMobilePage(tourId: settings.arguments as String? ?? ''),
      ),
      // Entrepreneur
      '/entrepreneur' => (
        RouteAccess.workspace,
        () => const EntrepreneurTabHost(initialRoute: '/entrepreneur'),
      ),
      // Material 3 five-tab workspace: Assess and Spaces.
      '/entrepreneur/assess' => (
        RouteAccess.workspace,
        () => const EntrepreneurTabHost(initialRoute: '/entrepreneur/assess'),
      ),
      '/entrepreneur/spaces' => (
        RouteAccess.workspace,
        () => const EntrepreneurTabHost(initialRoute: '/entrepreneur/spaces'),
      ),
      '/entrepreneur/add-property' => (
        RouteAccess.workspace,
        () => SitewiseAddPropertyMobilePage(
          // Resume a saved draft: arguments = fyp.rental_properties id.
          initialDraftId: settings.arguments as String?,
        ),
      ),
      '/entrepreneur/preferences' => (
        RouteAccess.workspace,
        () => const EntrepreneurPreferencesMobilePage(),
      ),
      '/entrepreneur/explore' => (
        RouteAccess.workspace,
        () => EntrepreneurTabHost(
          initialRoute: '/entrepreneur/explore',
          initialArguments: settings.arguments,
        ),
      ),
      '/entrepreneur/property-detail' => (
        RouteAccess.workspace,
        () => EntrepreneurPropertyDetailMobilePage(
          propertyId: settings.arguments as String? ?? '',
        ),
      ),
      '/entrepreneur/tour' => (
        RouteAccess.workspace,
        () => EntrepreneurTourMobilePage(
          propertyId: settings.arguments as String? ?? '',
        ),
      ),
      '/entrepreneur/recommendations' => (
        RouteAccess.workspace,
        () => const EntrepreneurRecommendationsMobilePage(),
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
      '/entrepreneur/saved' => (
        RouteAccess.workspace,
        () => const EntrepreneurSavedMobilePage(),
      ),
      '/entrepreneur/report' => (
        RouteAccess.workspace,
        () => EntrepreneurReportMobilePage(
          propertyId: settings.arguments as String? ?? '',
        ),
      ),
      // Option A assessment flow. The setup step receives the chosen
      // property id as arguments; the later steps read the session draft.
      '/entrepreneur/assessment-setup' => (
        RouteAccess.workspace,
        () => EntrepreneurAssessmentQuestionsPage(
          propertyId: settings.arguments as String? ?? '',
        ),
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
      builder: (_) => AuthGuard(access: entry.$1, builder: (_) => entry.$2()),
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
