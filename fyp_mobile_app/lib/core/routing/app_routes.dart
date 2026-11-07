import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import 'auth_route_guard.dart';
import '../../presentation/mobile/auth/pages/forgot_password_mobile_page.dart';
import '../../presentation/mobile/auth/pages/mobile_auth_page.dart';
import '../../presentation/mobile/auth/widgets/auth_tabs.dart';
import '../../presentation/mobile/onboarding/pages/onboarding_flow_page.dart';
import '../../presentation/mobile/start/app_start_gate.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_assess_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_assessment_setup_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_assessment_summary_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_compare_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_evidence_mobile_page.dart';
import '../../presentation/mobile/landing/pages/landing_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_spaces_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_dashboard_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_explore_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_preferences_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_profile_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_property_detail_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_recommendations_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_report_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_saved_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_tour_mobile_page.dart';
import '../../presentation/shared/capture/panorama_capture_page.dart';
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
  static Route<dynamic>? onGenerateRoute(
    RouteSettings settings,
    AppCubit appState,
    AuthCubit auth,
  ) {
    final (RouteAccess access, Widget Function() page) entry = switch (
      settings.name
    ) {
      // Startup decision point: verify session -> auth / onboarding / home.
      '/' => (
        RouteAccess.public,
        () => AppStartGate(appState: appState, auth: auth),
      ),
      // Public landing (kept reachable for demos and deep links).
      '/landing' => (
        RouteAccess.public,
        () => LandingMobilePage(appState: appState),
      ),
      // Authentication. `arguments` = 'login' | 'signUp'.
      '/auth' => (
        RouteAccess.public,
        () => MobileAuthPage(
          appState: appState,
          auth: auth,
          initialTab: settings.arguments == 'signUp'
              ? AuthTab.signUp
              : AuthTab.login,
        ),
      ),
      '/forgot-password' => (
        RouteAccess.public,
        () => ForgotPasswordMobilePage(auth: auth),
      ),
      // Onboarding belongs AFTER sign-in: it is part of the workspace, not
      // the pre-registration funnel.
      '/onboarding' => (
        RouteAccess.workspace,
        () => OnboardingFlowPage(appState: appState, auth: auth),
      ),
      // Shared 360° capture + preview flow (device-bound, no role namespace).
      '/capture' => (
        RouteAccess.workspace,
        () => PanoramaCapturePage(propertyId: settings.arguments as String?),
      ),
      '/tour-preview' => (
        RouteAccess.workspace,
        () => TourPreviewMobilePage(
          appState: appState,
          tourId: settings.arguments as String? ?? '',
        ),
      ),
      // Entrepreneur
      '/entrepreneur' => (
        RouteAccess.workspace,
        () => EntrepreneurDashboardMobilePage(appState: appState),
      ),
      // Material 3 five-tab workspace: Assess and Spaces.
      '/entrepreneur/assess' => (
        RouteAccess.workspace,
        () => EntrepreneurAssessMobilePage(appState: appState),
      ),
      '/entrepreneur/spaces' => (
        RouteAccess.workspace,
        () => EntrepreneurSpacesMobilePage(appState: appState),
      ),
      '/entrepreneur/preferences' => (
        RouteAccess.workspace,
        () => EntrepreneurPreferencesMobilePage(appState: appState),
      ),
      '/entrepreneur/explore' => (
        RouteAccess.workspace,
        () => EntrepreneurExploreMobilePage(
          appState: appState,
          startInMap: settings.arguments == 'map',
        ),
      ),
      '/entrepreneur/property-detail' => (
        RouteAccess.workspace,
        () => EntrepreneurPropertyDetailMobilePage(
          appState: appState,
          propertyId: settings.arguments as String? ?? '',
        ),
      ),
      '/entrepreneur/tour' => (
        RouteAccess.workspace,
        () => EntrepreneurTourMobilePage(
          appState: appState,
          propertyId: settings.arguments as String? ?? '',
        ),
      ),
      '/entrepreneur/recommendations' => (
        RouteAccess.workspace,
        () => EntrepreneurRecommendationsMobilePage(appState: appState),
      ),
      '/entrepreneur/compare' => (
        RouteAccess.workspace,
        () => EntrepreneurCompareMobilePage(appState: appState),
      ),
      '/entrepreneur/saved' => (
        RouteAccess.workspace,
        () => EntrepreneurSavedMobilePage(appState: appState),
      ),
      '/entrepreneur/report' => (
        RouteAccess.workspace,
        () => EntrepreneurReportMobilePage(
          appState: appState,
          propertyId: settings.arguments as String? ?? '',
        ),
      ),
      // Option A assessment flow. The setup step receives the chosen
      // property id as arguments; the later steps read the session draft.
      '/entrepreneur/assessment-setup' => (
        RouteAccess.workspace,
        () => EntrepreneurAssessmentSetupMobilePage(
          appState: appState,
          propertyId: settings.arguments as String? ?? '',
        ),
      ),
      '/entrepreneur/assessment-evidence' => (
        RouteAccess.workspace,
        () => EntrepreneurEvidenceMobilePage(appState: appState),
      ),
      '/entrepreneur/assessment-summary' => (
        RouteAccess.workspace,
        () => EntrepreneurAssessmentSummaryMobilePage(appState: appState),
      ),
      '/entrepreneur/profile' => (
        RouteAccess.workspace,
        () => EntrepreneurProfileMobilePage(appState: appState, auth: auth),
      ),
      // An unknown path is treated as protected and resolved to the
      // workspace root, never to a public page.
      _ => (
        RouteAccess.workspace,
        () => EntrepreneurDashboardMobilePage(appState: appState),
      ),
    };

    return MaterialPageRoute(
      settings: settings,
      builder: (_) => AuthGuard(
        auth: auth,
        access: entry.$1,
        appState: appState,
        builder: (_) => entry.$2(),
      ),
    );
  }
}
