import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

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
  return parents[route] ?? route;
}

abstract final class AppRoutes {
  static Route<dynamic>? onGenerateRoute(
    RouteSettings settings,
    AppCubit appState,
  ) {
    return MaterialPageRoute(
      settings: settings,
      builder: (ctx) {
        final id = settings.arguments as String?;
        final Widget page = switch (settings.name) {
          // Startup decision point: onboarding / auth / role home.
          '/' => AppStartGate(appState: appState),
          // Public landing (kept reachable for demos and deep links).
          '/landing' => LandingMobilePage(appState: appState),
          // First-run onboarding.
          '/onboarding' => OnboardingFlowPage(appState: appState),
          // Authentication. `arguments` = 'login' | 'signUp'.
          '/auth' => MobileAuthPage(
            appState: appState,
            initialTab: id == 'signUp' ? AuthTab.signUp : AuthTab.login,
          ),
          // Shared 360° capture + preview flow (device-bound, no role namespace).
          '/capture' => PanoramaCapturePage(propertyId: id),
          '/tour-preview' => TourPreviewMobilePage(
            appState: appState,
            tourId: id ?? '',
          ),
          // Entrepreneur
          '/entrepreneur' => EntrepreneurDashboardMobilePage(
            appState: appState,
          ),
          // Material 3 five-tab workspace: Assess and Spaces.
          '/entrepreneur/assess' => EntrepreneurAssessMobilePage(
            appState: appState,
          ),
          '/entrepreneur/spaces' => EntrepreneurSpacesMobilePage(
            appState: appState,
          ),
          '/entrepreneur/preferences' => EntrepreneurPreferencesMobilePage(
            appState: appState,
          ),
          '/entrepreneur/explore' => EntrepreneurExploreMobilePage(
            appState: appState,
            startInMap: id == 'map',
          ),
          '/entrepreneur/property-detail' =>
            EntrepreneurPropertyDetailMobilePage(
              appState: appState,
              propertyId: id ?? '',
            ),
          '/entrepreneur/tour' => EntrepreneurTourMobilePage(
            appState: appState,
            propertyId: id ?? '',
          ),
          '/entrepreneur/recommendations' =>
            EntrepreneurRecommendationsMobilePage(appState: appState),
          '/entrepreneur/compare' => EntrepreneurCompareMobilePage(
            appState: appState,
          ),
          '/entrepreneur/saved' => EntrepreneurSavedMobilePage(
            appState: appState,
          ),
          '/entrepreneur/report' => EntrepreneurReportMobilePage(
            appState: appState,
            propertyId: id ?? '',
          ),
          // Option A assessment flow. The setup step receives the chosen
          // property id as arguments; the later steps read the session draft.
          '/entrepreneur/assessment-setup' =>
            EntrepreneurAssessmentSetupMobilePage(
              appState: appState,
              propertyId: id ?? '',
            ),
          '/entrepreneur/assessment-evidence' =>
            EntrepreneurEvidenceMobilePage(appState: appState),
          '/entrepreneur/assessment-summary' =>
            EntrepreneurAssessmentSummaryMobilePage(appState: appState),
          '/entrepreneur/profile' => EntrepreneurProfileMobilePage(
            appState: appState,
          ),
          _ => EntrepreneurDashboardMobilePage(appState: appState),
        };
        return page;
      },
    );
  }
}
