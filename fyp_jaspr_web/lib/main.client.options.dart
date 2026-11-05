// dart format off
// ignore_for_file: type=lint

// GENERATED FILE, DO NOT MODIFY
// Generated with jaspr_builder

import 'package:jaspr/client.dart';

import 'package:sitewise_jaspr_web/pages/admin/agents_page.dart'
    deferred as _agents_page;
import 'package:sitewise_jaspr_web/pages/admin/dashboard_page.dart'
    deferred as _dashboard_page;
import 'package:sitewise_jaspr_web/pages/admin/listing_detail_page.dart'
    deferred as _listing_detail_page;
import 'package:sitewise_jaspr_web/pages/admin/listings_page.dart'
    deferred as _listings_page;
import 'package:sitewise_jaspr_web/pages/admin/profile_page.dart'
    deferred as _profile_page;
import 'package:sitewise_jaspr_web/pages/admin/user_detail_page.dart'
    deferred as _user_detail_page;
import 'package:sitewise_jaspr_web/pages/admin/users_page.dart'
    deferred as _users_page;
import 'package:sitewise_jaspr_web/pages/admin/verification_detail_page.dart'
    deferred as _verification_detail_page;
import 'package:sitewise_jaspr_web/pages/admin/verification_page.dart'
    deferred as _verification_page;
import 'package:sitewise_jaspr_web/pages/agent/dashboard_page.dart'
    deferred as _agent_dashboard_page;
import 'package:sitewise_jaspr_web/pages/agent/enquiries_page.dart'
    deferred as _enquiries_page;
import 'package:sitewise_jaspr_web/pages/agent/listings_page.dart'
    deferred as _agent_listings_page;
import 'package:sitewise_jaspr_web/pages/agent/performance_page.dart'
    deferred as _performance_page;
import 'package:sitewise_jaspr_web/pages/agent/profile_page.dart'
    deferred as _agent_profile_page;
import 'package:sitewise_jaspr_web/pages/agent/property_detail_page.dart'
    deferred as _property_detail_page;
import 'package:sitewise_jaspr_web/pages/entrepreneur/add_property_page.dart'
    deferred as _add_property_page;
import 'package:sitewise_jaspr_web/pages/entrepreneur/compare_page.dart'
    deferred as _compare_page;
import 'package:sitewise_jaspr_web/pages/entrepreneur/dashboard_page.dart'
    deferred as _entrepreneur_dashboard_page;
import 'package:sitewise_jaspr_web/pages/entrepreneur/explanation_page.dart'
    deferred as _explanation_page;
import 'package:sitewise_jaspr_web/pages/entrepreneur/explore_page.dart'
    deferred as _explore_page;
import 'package:sitewise_jaspr_web/pages/entrepreneur/map_page.dart'
    deferred as _map_page;
import 'package:sitewise_jaspr_web/pages/entrepreneur/my_properties_page.dart'
    deferred as _my_properties_page;
import 'package:sitewise_jaspr_web/pages/entrepreneur/preferences_page.dart'
    deferred as _preferences_page;
import 'package:sitewise_jaspr_web/pages/entrepreneur/profile_page.dart'
    deferred as _entrepreneur_profile_page;
import 'package:sitewise_jaspr_web/pages/entrepreneur/property_detail_page.dart'
    deferred as _entrepreneur_property_detail_page;
import 'package:sitewise_jaspr_web/pages/entrepreneur/recommendations_page.dart'
    deferred as _recommendations_page;
import 'package:sitewise_jaspr_web/pages/entrepreneur/report_page.dart'
    deferred as _report_page;
import 'package:sitewise_jaspr_web/pages/entrepreneur/saved_page.dart'
    deferred as _saved_page;
import 'package:sitewise_jaspr_web/pages/entrepreneur/tour_page.dart'
    deferred as _tour_page;
import 'package:sitewise_jaspr_web/pages/owner/add_property_page.dart'
    deferred as _owner_add_property_page;
import 'package:sitewise_jaspr_web/pages/owner/dashboard_page.dart'
    deferred as _owner_dashboard_page;
import 'package:sitewise_jaspr_web/pages/owner/profile_page.dart'
    deferred as _owner_profile_page;
import 'package:sitewise_jaspr_web/pages/owner/properties_page.dart'
    deferred as _properties_page;
import 'package:sitewise_jaspr_web/pages/owner/property_detail_page.dart'
    deferred as _owner_property_detail_page;
import 'package:sitewise_jaspr_web/pages/owner/tour_preview_page.dart'
    deferred as _tour_preview_page;
import 'package:sitewise_jaspr_web/pages/owner/tours_page.dart'
    deferred as _tours_page;
import 'package:sitewise_jaspr_web/pages/auth_callback_page.dart'
    deferred as _auth_callback_page;
import 'package:sitewise_jaspr_web/pages/forgot_password_page.dart'
    deferred as _forgot_password_page;
import 'package:sitewise_jaspr_web/pages/landing_page.dart'
    deferred as _landing_page;
import 'package:sitewise_jaspr_web/pages/login_page.dart'
    deferred as _login_page;
import 'package:sitewise_jaspr_web/pages/reset_password_page.dart'
    deferred as _reset_password_page;
import 'package:sitewise_jaspr_web/pages/signup_page.dart'
    deferred as _signup_page;
import 'package:sitewise_jaspr_web/pages/staff_mfa_page.dart'
    deferred as _staff_mfa_page;

/// Default [ClientOptions] for use with your Jaspr project.
///
/// Use this to initialize Jaspr **before** calling [runApp].
///
/// Example:
/// ```dart
/// import 'main.client.options.dart';
///
/// void main() {
///   Jaspr.initializeApp(
///     options: defaultClientOptions,
///   );
///
///   runApp(...);
/// }
/// ```
ClientOptions get defaultClientOptions => ClientOptions(
  clients: {
    'agents_page': ClientLoader(
      (p) => _agents_page.AdminAgentsPage(),
      loader: _agents_page.loadLibrary,
    ),
    'dashboard_page': ClientLoader(
      (p) => _dashboard_page.DashboardPage(),
      loader: _dashboard_page.loadLibrary,
    ),
    'listing_detail_page': ClientLoader(
      (p) => _listing_detail_page.ListingDetailPage(id: p['id'] as String),
      loader: _listing_detail_page.loadLibrary,
    ),
    'listings_page': ClientLoader(
      (p) => _listings_page.ListingsPage(),
      loader: _listings_page.loadLibrary,
    ),
    'profile_page': ClientLoader(
      (p) => _profile_page.ProfilePage(),
      loader: _profile_page.loadLibrary,
    ),
    'user_detail_page': ClientLoader(
      (p) => _user_detail_page.UserDetailPage(id: p['id'] as String),
      loader: _user_detail_page.loadLibrary,
    ),
    'users_page': ClientLoader(
      (p) => _users_page.UsersPage(),
      loader: _users_page.loadLibrary,
    ),
    'verification_detail_page': ClientLoader(
      (p) => _verification_detail_page.VerificationDetailPage(
        id: p['id'] as String,
      ),
      loader: _verification_detail_page.loadLibrary,
    ),
    'verification_page': ClientLoader(
      (p) => _verification_page.VerificationPage(),
      loader: _verification_page.loadLibrary,
    ),
    'agent/dashboard_page': ClientLoader(
      (p) => _agent_dashboard_page.AgentDashboardPage(),
      loader: _agent_dashboard_page.loadLibrary,
    ),
    'enquiries_page': ClientLoader(
      (p) => _enquiries_page.AgentEnquiriesPage(),
      loader: _enquiries_page.loadLibrary,
    ),
    'agent/listings_page': ClientLoader(
      (p) => _agent_listings_page.AgentListingsPage(),
      loader: _agent_listings_page.loadLibrary,
    ),
    'performance_page': ClientLoader(
      (p) => _performance_page.AgentPerformancePage(),
      loader: _performance_page.loadLibrary,
    ),
    'agent/profile_page': ClientLoader(
      (p) => _agent_profile_page.AgentProfilePage(),
      loader: _agent_profile_page.loadLibrary,
    ),
    'property_detail_page': ClientLoader(
      (p) =>
          _property_detail_page.AgentPropertyDetailPage(id: p['id'] as String),
      loader: _property_detail_page.loadLibrary,
    ),
    'auth_callback_page': ClientLoader(
      (p) => _auth_callback_page.AuthCallbackPage(),
      loader: _auth_callback_page.loadLibrary,
    ),
    'add_property_page': ClientLoader(
      (p) => _add_property_page.AddPropertyPage(),
      loader: _add_property_page.loadLibrary,
    ),
    'compare_page': ClientLoader(
      (p) => _compare_page.ComparePage(),
      loader: _compare_page.loadLibrary,
    ),
    'entrepreneur/dashboard_page': ClientLoader(
      (p) => _entrepreneur_dashboard_page.DashboardPage(),
      loader: _entrepreneur_dashboard_page.loadLibrary,
    ),
    'explanation_page': ClientLoader(
      (p) => _explanation_page.ExplanationPage(
        propertyId: p['propertyId'] as String,
      ),
      loader: _explanation_page.loadLibrary,
    ),
    'explore_page': ClientLoader(
      (p) => _explore_page.ExplorePage(startInMap: p['startInMap'] as bool),
      loader: _explore_page.loadLibrary,
    ),
    'map_page': ClientLoader(
      (p) => _map_page.MapPage(initialId: p['initialId'] as String?),
      loader: _map_page.loadLibrary,
    ),
    'my_properties_page': ClientLoader(
      (p) => _my_properties_page.MyPropertiesPage(),
      loader: _my_properties_page.loadLibrary,
    ),
    'preferences_page': ClientLoader(
      (p) => _preferences_page.PreferencesPage(),
      loader: _preferences_page.loadLibrary,
    ),
    'entrepreneur/profile_page': ClientLoader(
      (p) => _entrepreneur_profile_page.ProfilePage(),
      loader: _entrepreneur_profile_page.loadLibrary,
    ),
    'entrepreneur/property_detail_page': ClientLoader(
      (p) => _entrepreneur_property_detail_page.PropertyDetailPage(
        id: p['id'] as String,
      ),
      loader: _entrepreneur_property_detail_page.loadLibrary,
    ),
    'recommendations_page': ClientLoader(
      (p) => _recommendations_page.RecommendationsPage(),
      loader: _recommendations_page.loadLibrary,
    ),
    'report_page': ClientLoader(
      (p) => _report_page.ReportPage(id: p['id'] as String),
      loader: _report_page.loadLibrary,
    ),
    'saved_page': ClientLoader(
      (p) => _saved_page.SavedPage(),
      loader: _saved_page.loadLibrary,
    ),
    'tour_page': ClientLoader(
      (p) => _tour_page.TourPage(id: p['id'] as String),
      loader: _tour_page.loadLibrary,
    ),
    'forgot_password_page': ClientLoader(
      (p) => _forgot_password_page.ForgotPasswordPage(),
      loader: _forgot_password_page.loadLibrary,
    ),
    'landing_page': ClientLoader(
      (p) => _landing_page.LandingPage(),
      loader: _landing_page.loadLibrary,
    ),
    'login_page': ClientLoader(
      (p) => _login_page.LoginPage(portal: p['portal'] as String?),
      loader: _login_page.loadLibrary,
    ),
    'owner/add_property_page': ClientLoader(
      (p) => _owner_add_property_page.AddPropertyPage(
        editingId: p['editingId'] as String?,
      ),
      loader: _owner_add_property_page.loadLibrary,
    ),
    'owner/dashboard_page': ClientLoader(
      (p) => _owner_dashboard_page.DashboardPage(),
      loader: _owner_dashboard_page.loadLibrary,
    ),
    'owner/profile_page': ClientLoader(
      (p) => _owner_profile_page.ProfilePage(),
      loader: _owner_profile_page.loadLibrary,
    ),
    'properties_page': ClientLoader(
      (p) => _properties_page.PropertiesPage(),
      loader: _properties_page.loadLibrary,
    ),
    'owner/property_detail_page': ClientLoader(
      (p) =>
          _owner_property_detail_page.PropertyDetailPage(id: p['id'] as String),
      loader: _owner_property_detail_page.loadLibrary,
    ),
    'tour_preview_page': ClientLoader(
      (p) => _tour_preview_page.TourPreviewPage(id: p['id'] as String),
      loader: _tour_preview_page.loadLibrary,
    ),
    'tours_page': ClientLoader(
      (p) => _tours_page.ToursPage(),
      loader: _tours_page.loadLibrary,
    ),
    'reset_password_page': ClientLoader(
      (p) => _reset_password_page.ResetPasswordPage(),
      loader: _reset_password_page.loadLibrary,
    ),
    'signup_page': ClientLoader(
      (p) => _signup_page.SignupPage(),
      loader: _signup_page.loadLibrary,
    ),
    'staff_mfa_page': ClientLoader(
      (p) => _staff_mfa_page.StaffMfaPage(),
      loader: _staff_mfa_page.loadLibrary,
    ),
  },
);
