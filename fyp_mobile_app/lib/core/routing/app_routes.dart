import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../presentation/mobile/auth/pages/mobile_auth_page.dart';
import '../../presentation/mobile/auth/widgets/auth_tabs.dart';
import '../../presentation/mobile/onboarding/pages/onboarding_flow_page.dart';
import '../../presentation/mobile/start/app_start_gate.dart';
import '../../presentation/mobile/admin/pages/admin_dashboard_mobile_page.dart';
import '../../presentation/mobile/admin/pages/admin_listing_detail_mobile_page.dart';
import '../../presentation/mobile/admin/pages/admin_listings_mobile_page.dart';
import '../../presentation/mobile/admin/pages/admin_profile_mobile_page.dart';
import '../../presentation/mobile/admin/pages/admin_user_detail_mobile_page.dart';
import '../../presentation/mobile/admin/pages/admin_users_mobile_page.dart';
import '../../presentation/mobile/admin/pages/admin_verification_detail_mobile_page.dart';
import '../../presentation/mobile/admin/pages/admin_verification_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_compare_mobile_page.dart';
import '../../presentation/mobile/landing/pages/landing_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_dashboard_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_explore_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_preferences_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_profile_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_property_detail_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_recommendations_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_report_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_saved_mobile_page.dart';
import '../../presentation/mobile/entrepreneur/pages/entrepreneur_tour_mobile_page.dart';
import '../../presentation/mobile/property_owner/pages/owner_add_property_mobile_page.dart';
import '../../presentation/mobile/property_owner/pages/owner_dashboard_mobile_page.dart';
import '../../presentation/mobile/property_owner/pages/owner_profile_mobile_page.dart';
import '../../presentation/mobile/property_owner/pages/owner_properties_mobile_page.dart';
import '../../presentation/mobile/property_owner/pages/owner_property_detail_mobile_page.dart';
import '../../presentation/mobile/property_owner/pages/owner_tours_mobile_page.dart';
import '../../presentation/mobile/property_owner/pages/tour_preview_mobile_page.dart';
import '../../presentation/shared/capture/panorama_capture_page.dart';

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
    '/entrepreneur/preferences': '/entrepreneur',
    '/entrepreneur/property-detail': '/entrepreneur/explore',
    '/entrepreneur/tour': '/entrepreneur/explore',
    '/entrepreneur/report': '/entrepreneur/explore',
    '/admin/user-detail': '/admin/users',
    '/admin/verification-detail': '/admin/verification',
    '/admin/listing-detail': '/admin/listings',
    '/owner/property-detail': '/owner/properties',
    '/owner/capture': '/owner/tours',
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
          // Admin
          '/admin' => AdminDashboardMobilePage(appState: appState),
          '/admin/users' => AdminUsersMobilePage(appState: appState),
          '/admin/user-detail' => AdminUserDetailMobilePage(
            appState: appState,
            userId: id ?? '',
          ),
          '/admin/verification' => AdminVerificationMobilePage(
            appState: appState,
          ),
          '/admin/verification-detail' => AdminVerificationDetailMobilePage(
            appState: appState,
            propertyId: id ?? '',
          ),
          '/admin/listings' => AdminListingsMobilePage(appState: appState),
          '/admin/listing-detail' => AdminListingDetailMobilePage(
            appState: appState,
            propertyId: id ?? '',
          ),
          '/admin/profile' => AdminProfileMobilePage(appState: appState),
          // Owner
          '/owner' => OwnerDashboardMobilePage(appState: appState),
          '/owner/properties' => OwnerPropertiesMobilePage(appState: appState),
          '/owner/property-detail' => OwnerPropertyDetailMobilePage(
            appState: appState,
            propertyId: id ?? '',
          ),
          '/owner/add-property' => OwnerAddPropertyMobilePage(
            appState: appState,
            editingId: id,
          ),
          '/owner/tours' => OwnerToursMobilePage(appState: appState),
          '/owner/profile' => OwnerProfileMobilePage(appState: appState),
          '/owner/tour-preview' => TourPreviewMobilePage(
            appState: appState,
            tourId: id ?? '',
          ),
          '/owner/capture' => PanoramaCapturePage(propertyId: id),
          // Entrepreneur
          '/entrepreneur' => EntrepreneurDashboardMobilePage(
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
