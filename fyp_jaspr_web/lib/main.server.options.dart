// dart format off
// ignore_for_file: type=lint

// GENERATED FILE, DO NOT MODIFY
// Generated with jaspr_builder

import 'package:jaspr/server.dart';
import 'package:sitewise_jaspr_web/pages/admin/agents_page.dart'
    as _agents_page;
import 'package:sitewise_jaspr_web/pages/admin/dashboard_page.dart'
    as _dashboard_page;
import 'package:sitewise_jaspr_web/pages/admin/listing_detail_page.dart'
    as _listing_detail_page;
import 'package:sitewise_jaspr_web/pages/admin/listings_page.dart'
    as _listings_page;
import 'package:sitewise_jaspr_web/pages/admin/profile_page.dart'
    as _profile_page;
import 'package:sitewise_jaspr_web/pages/admin/user_detail_page.dart'
    as _user_detail_page;
import 'package:sitewise_jaspr_web/pages/admin/users_page.dart' as _users_page;
import 'package:sitewise_jaspr_web/pages/admin/verification_detail_page.dart'
    as _verification_detail_page;
import 'package:sitewise_jaspr_web/pages/admin/verification_page.dart'
    as _verification_page;
import 'package:sitewise_jaspr_web/pages/agent/dashboard_page.dart'
    as _agent_dashboard_page;
import 'package:sitewise_jaspr_web/pages/agent/enquiries_page.dart'
    as _enquiries_page;
import 'package:sitewise_jaspr_web/pages/agent/listings_page.dart'
    as _agent_listings_page;
import 'package:sitewise_jaspr_web/pages/agent/performance_page.dart'
    as _performance_page;
import 'package:sitewise_jaspr_web/pages/agent/profile_page.dart'
    as _agent_profile_page;
import 'package:sitewise_jaspr_web/pages/agent/property_detail_page.dart'
    as _property_detail_page;
import 'package:sitewise_jaspr_web/pages/entrepreneur/add_property_page.dart'
    as _add_property_page;
import 'package:sitewise_jaspr_web/pages/entrepreneur/compare_page.dart'
    as _compare_page;
import 'package:sitewise_jaspr_web/pages/entrepreneur/dashboard_page.dart'
    as _entrepreneur_dashboard_page;
import 'package:sitewise_jaspr_web/pages/entrepreneur/explanation_page.dart'
    as _explanation_page;
import 'package:sitewise_jaspr_web/pages/entrepreneur/explore_page.dart'
    as _explore_page;
import 'package:sitewise_jaspr_web/pages/entrepreneur/map_page.dart'
    as _map_page;
import 'package:sitewise_jaspr_web/pages/entrepreneur/my_properties_page.dart'
    as _my_properties_page;
import 'package:sitewise_jaspr_web/pages/entrepreneur/preferences_page.dart'
    as _preferences_page;
import 'package:sitewise_jaspr_web/pages/entrepreneur/profile_page.dart'
    as _entrepreneur_profile_page;
import 'package:sitewise_jaspr_web/pages/entrepreneur/property_detail_page.dart'
    as _entrepreneur_property_detail_page;
import 'package:sitewise_jaspr_web/pages/entrepreneur/recommendations_page.dart'
    as _recommendations_page;
import 'package:sitewise_jaspr_web/pages/entrepreneur/report_page.dart'
    as _report_page;
import 'package:sitewise_jaspr_web/pages/entrepreneur/saved_page.dart'
    as _saved_page;
import 'package:sitewise_jaspr_web/pages/entrepreneur/tour_page.dart'
    as _tour_page;
import 'package:sitewise_jaspr_web/pages/owner/add_property_page.dart'
    as _owner_add_property_page;
import 'package:sitewise_jaspr_web/pages/owner/dashboard_page.dart'
    as _owner_dashboard_page;
import 'package:sitewise_jaspr_web/pages/owner/profile_page.dart'
    as _owner_profile_page;
import 'package:sitewise_jaspr_web/pages/owner/properties_page.dart'
    as _properties_page;
import 'package:sitewise_jaspr_web/pages/owner/property_detail_page.dart'
    as _owner_property_detail_page;
import 'package:sitewise_jaspr_web/pages/owner/tour_preview_page.dart'
    as _tour_preview_page;
import 'package:sitewise_jaspr_web/pages/owner/tours_page.dart' as _tours_page;
import 'package:sitewise_jaspr_web/pages/auth_callback_page.dart'
    as _auth_callback_page;
import 'package:sitewise_jaspr_web/pages/forgot_password_page.dart'
    as _forgot_password_page;
import 'package:sitewise_jaspr_web/pages/landing_page.dart' as _landing_page;
import 'package:sitewise_jaspr_web/pages/login_page.dart' as _login_page;
import 'package:sitewise_jaspr_web/pages/reset_password_page.dart'
    as _reset_password_page;
import 'package:sitewise_jaspr_web/pages/signup_page.dart' as _signup_page;
import 'package:sitewise_jaspr_web/pages/staff_mfa_page.dart'
    as _staff_mfa_page;
import 'package:sitewise_jaspr_web/pages/staff_verify_page.dart'
    as _staff_verify_page;

/// Default [ServerOptions] for use with your Jaspr project.
///
/// Use this to initialize Jaspr **before** calling [runApp].
///
/// Example:
/// ```dart
/// import 'main.server.options.dart';
///
/// void main() {
///   Jaspr.initializeApp(
///     options: defaultServerOptions,
///   );
///
///   runApp(...);
/// }
/// ```
ServerOptions get defaultServerOptions => ServerOptions(
  clientId: 'main.client.dart.js',
  clients: {
    _agents_page.AdminAgentsPage: ClientTarget<_agents_page.AdminAgentsPage>(
      'agents_page',
    ),
    _dashboard_page.DashboardPage: ClientTarget<_dashboard_page.DashboardPage>(
      'dashboard_page',
    ),
    _listing_detail_page.ListingDetailPage:
        ClientTarget<_listing_detail_page.ListingDetailPage>(
          'listing_detail_page',
          params: __listing_detail_pageListingDetailPage,
        ),
    _listings_page.ListingsPage: ClientTarget<_listings_page.ListingsPage>(
      'listings_page',
    ),
    _profile_page.ProfilePage: ClientTarget<_profile_page.ProfilePage>(
      'profile_page',
    ),
    _user_detail_page.UserDetailPage:
        ClientTarget<_user_detail_page.UserDetailPage>(
          'user_detail_page',
          params: __user_detail_pageUserDetailPage,
        ),
    _users_page.UsersPage: ClientTarget<_users_page.UsersPage>('users_page'),
    _verification_detail_page.VerificationDetailPage:
        ClientTarget<_verification_detail_page.VerificationDetailPage>(
          'verification_detail_page',
          params: __verification_detail_pageVerificationDetailPage,
        ),
    _verification_page.VerificationPage:
        ClientTarget<_verification_page.VerificationPage>('verification_page'),
    _agent_dashboard_page.AgentDashboardPage:
        ClientTarget<_agent_dashboard_page.AgentDashboardPage>(
          'agent/dashboard_page',
        ),
    _enquiries_page.AgentEnquiriesPage:
        ClientTarget<_enquiries_page.AgentEnquiriesPage>('enquiries_page'),
    _agent_listings_page.AgentListingsPage:
        ClientTarget<_agent_listings_page.AgentListingsPage>(
          'agent/listings_page',
        ),
    _performance_page.AgentPerformancePage:
        ClientTarget<_performance_page.AgentPerformancePage>(
          'performance_page',
        ),
    _agent_profile_page.AgentProfilePage:
        ClientTarget<_agent_profile_page.AgentProfilePage>(
          'agent/profile_page',
        ),
    _property_detail_page.AgentPropertyDetailPage:
        ClientTarget<_property_detail_page.AgentPropertyDetailPage>(
          'property_detail_page',
          params: __property_detail_pageAgentPropertyDetailPage,
        ),
    _auth_callback_page.AuthCallbackPage:
        ClientTarget<_auth_callback_page.AuthCallbackPage>(
          'auth_callback_page',
        ),
    _add_property_page.AddPropertyPage:
        ClientTarget<_add_property_page.AddPropertyPage>('add_property_page'),
    _compare_page.ComparePage: ClientTarget<_compare_page.ComparePage>(
      'compare_page',
    ),
    _entrepreneur_dashboard_page.DashboardPage:
        ClientTarget<_entrepreneur_dashboard_page.DashboardPage>(
          'entrepreneur/dashboard_page',
        ),
    _explanation_page.ExplanationPage:
        ClientTarget<_explanation_page.ExplanationPage>(
          'explanation_page',
          params: __explanation_pageExplanationPage,
        ),
    _explore_page.ExplorePage: ClientTarget<_explore_page.ExplorePage>(
      'explore_page',
      params: __explore_pageExplorePage,
    ),
    _map_page.MapPage: ClientTarget<_map_page.MapPage>(
      'map_page',
      params: __map_pageMapPage,
    ),
    _my_properties_page.MyPropertiesPage:
        ClientTarget<_my_properties_page.MyPropertiesPage>(
          'my_properties_page',
        ),
    _preferences_page.PreferencesPage:
        ClientTarget<_preferences_page.PreferencesPage>('preferences_page'),
    _entrepreneur_profile_page.ProfilePage:
        ClientTarget<_entrepreneur_profile_page.ProfilePage>(
          'entrepreneur/profile_page',
        ),
    _entrepreneur_property_detail_page.PropertyDetailPage:
        ClientTarget<_entrepreneur_property_detail_page.PropertyDetailPage>(
          'entrepreneur/property_detail_page',
          params: __entrepreneur_property_detail_pagePropertyDetailPage,
        ),
    _recommendations_page.RecommendationsPage:
        ClientTarget<_recommendations_page.RecommendationsPage>(
          'recommendations_page',
        ),
    _report_page.ReportPage: ClientTarget<_report_page.ReportPage>(
      'report_page',
      params: __report_pageReportPage,
    ),
    _saved_page.SavedPage: ClientTarget<_saved_page.SavedPage>('saved_page'),
    _tour_page.TourPage: ClientTarget<_tour_page.TourPage>(
      'tour_page',
      params: __tour_pageTourPage,
    ),
    _forgot_password_page.ForgotPasswordPage:
        ClientTarget<_forgot_password_page.ForgotPasswordPage>(
          'forgot_password_page',
        ),
    _landing_page.LandingPage: ClientTarget<_landing_page.LandingPage>(
      'landing_page',
    ),
    _login_page.LoginPage: ClientTarget<_login_page.LoginPage>(
      'login_page',
      params: __login_pageLoginPage,
    ),
    _owner_add_property_page.AddPropertyPage:
        ClientTarget<_owner_add_property_page.AddPropertyPage>(
          'owner/add_property_page',
          params: __owner_add_property_pageAddPropertyPage,
        ),
    _owner_dashboard_page.DashboardPage:
        ClientTarget<_owner_dashboard_page.DashboardPage>(
          'owner/dashboard_page',
        ),
    _owner_profile_page.ProfilePage:
        ClientTarget<_owner_profile_page.ProfilePage>('owner/profile_page'),
    _properties_page.PropertiesPage:
        ClientTarget<_properties_page.PropertiesPage>('properties_page'),
    _owner_property_detail_page.PropertyDetailPage:
        ClientTarget<_owner_property_detail_page.PropertyDetailPage>(
          'owner/property_detail_page',
          params: __owner_property_detail_pagePropertyDetailPage,
        ),
    _tour_preview_page.TourPreviewPage:
        ClientTarget<_tour_preview_page.TourPreviewPage>(
          'tour_preview_page',
          params: __tour_preview_pageTourPreviewPage,
        ),
    _tours_page.ToursPage: ClientTarget<_tours_page.ToursPage>('tours_page'),
    _reset_password_page.ResetPasswordPage:
        ClientTarget<_reset_password_page.ResetPasswordPage>(
          'reset_password_page',
        ),
    _signup_page.SignupPage: ClientTarget<_signup_page.SignupPage>(
      'signup_page',
    ),
    _staff_mfa_page.StaffMfaPage: ClientTarget<_staff_mfa_page.StaffMfaPage>(
      'staff_mfa_page',
    ),
    _staff_verify_page.StaffVerifyPage:
        ClientTarget<_staff_verify_page.StaffVerifyPage>('staff_verify_page'),
  },
);

Map<String, Object?> __listing_detail_pageListingDetailPage(
  _listing_detail_page.ListingDetailPage c,
) => {'id': c.id};
Map<String, Object?> __user_detail_pageUserDetailPage(
  _user_detail_page.UserDetailPage c,
) => {'id': c.id};
Map<String, Object?> __verification_detail_pageVerificationDetailPage(
  _verification_detail_page.VerificationDetailPage c,
) => {'id': c.id};
Map<String, Object?> __property_detail_pageAgentPropertyDetailPage(
  _property_detail_page.AgentPropertyDetailPage c,
) => {'id': c.id};
Map<String, Object?> __explanation_pageExplanationPage(
  _explanation_page.ExplanationPage c,
) => {'propertyId': c.propertyId};
Map<String, Object?> __explore_pageExplorePage(_explore_page.ExplorePage c) => {
  'startInMap': c.startInMap,
};
Map<String, Object?> __map_pageMapPage(_map_page.MapPage c) => {
  'initialId': c.initialId,
};
Map<String, Object?> __entrepreneur_property_detail_pagePropertyDetailPage(
  _entrepreneur_property_detail_page.PropertyDetailPage c,
) => {'id': c.id};
Map<String, Object?> __report_pageReportPage(_report_page.ReportPage c) => {
  'id': c.id,
};
Map<String, Object?> __tour_pageTourPage(_tour_page.TourPage c) => {'id': c.id};
Map<String, Object?> __login_pageLoginPage(_login_page.LoginPage c) => {
  'portal': c.portal,
};
Map<String, Object?> __owner_add_property_pageAddPropertyPage(
  _owner_add_property_page.AddPropertyPage c,
) => {'editingId': c.editingId};
Map<String, Object?> __owner_property_detail_pagePropertyDetailPage(
  _owner_property_detail_page.PropertyDetailPage c,
) => {'id': c.id};
Map<String, Object?> __tour_preview_pageTourPreviewPage(
  _tour_preview_page.TourPreviewPage c,
) => {'id': c.id};
