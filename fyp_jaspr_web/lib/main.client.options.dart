// dart format off
// ignore_for_file: type=lint

// GENERATED FILE, DO NOT MODIFY
// Generated with jaspr_builder

import 'package:jaspr/client.dart';

import 'package:sitewise_jaspr_web/features/administration/presentation/components/agent_assignment_control.dart'
    deferred as _agent_assignment_control;
import 'package:sitewise_jaspr_web/features/administration/presentation/components/agent_change_requests_panel.dart'
    deferred as _agent_change_requests_panel;
import 'package:sitewise_jaspr_web/features/administration/presentation/pages/activity_page.dart'
    deferred as _activity_page;
import 'package:sitewise_jaspr_web/features/administration/presentation/pages/agents_page.dart'
    deferred as _agents_page;
import 'package:sitewise_jaspr_web/features/administration/presentation/pages/campaigns_page.dart'
    deferred as _campaigns_page;
import 'package:sitewise_jaspr_web/features/administration/presentation/pages/dashboard_page.dart'
    deferred as _dashboard_page;
import 'package:sitewise_jaspr_web/features/administration/presentation/pages/listing_detail_page.dart'
    deferred as _listing_detail_page;
import 'package:sitewise_jaspr_web/features/administration/presentation/pages/listings_page.dart'
    deferred as _listings_page;
import 'package:sitewise_jaspr_web/features/administration/presentation/pages/surveys_page.dart'
    deferred as _surveys_page;
import 'package:sitewise_jaspr_web/features/administration/presentation/pages/user_detail_page.dart'
    deferred as _user_detail_page;
import 'package:sitewise_jaspr_web/features/administration/presentation/pages/users_page.dart'
    deferred as _users_page;
import 'package:sitewise_jaspr_web/features/assessment/presentation/pages/assessment_workspace_page.dart'
    deferred as _assessment_workspace_page;
import 'package:sitewise_jaspr_web/features/assessment/presentation/pages/report_page.dart'
    deferred as _report_page;
import 'package:sitewise_jaspr_web/features/assessment/presentation/pages/reports_page.dart'
    deferred as _reports_page;
import 'package:sitewise_jaspr_web/features/authentication/presentation/pages/auth_callback_page.dart'
    deferred as _auth_callback_page;
import 'package:sitewise_jaspr_web/features/authentication/presentation/pages/forgot_password_page.dart'
    deferred as _forgot_password_page;
import 'package:sitewise_jaspr_web/features/authentication/presentation/pages/login_page.dart'
    deferred as _login_page;
import 'package:sitewise_jaspr_web/features/authentication/presentation/pages/reset_password_page.dart'
    deferred as _reset_password_page;
import 'package:sitewise_jaspr_web/features/authentication/presentation/pages/signup_page.dart'
    deferred as _signup_page;
import 'package:sitewise_jaspr_web/features/authentication/presentation/pages/staff_mfa_page.dart'
    deferred as _staff_mfa_page;
import 'package:sitewise_jaspr_web/features/authentication/presentation/pages/staff_verify_page.dart'
    deferred as _staff_verify_page;
import 'package:sitewise_jaspr_web/features/compare/presentation/pages/compare_page.dart'
    deferred as _compare_page;
import 'package:sitewise_jaspr_web/features/dashboard/presentation/pages/entrepreneur_dashboard_page.dart'
    deferred as _entrepreneur_dashboard_page;
import 'package:sitewise_jaspr_web/features/listing/presentation/components/property_detail/business_concept_panel.dart'
    deferred as _business_concept_panel;
import 'package:sitewise_jaspr_web/features/listing/presentation/pages/commercial_listing_page.dart'
    deferred as _commercial_listing_page;
import 'package:sitewise_jaspr_web/features/listing/presentation/pages/explore_page.dart'
    deferred as _explore_page;
import 'package:sitewise_jaspr_web/features/listing/presentation/pages/property_detail_page.dart'
    deferred as _property_detail_page;
import 'package:sitewise_jaspr_web/features/listing/presentation/pages/saved_page.dart'
    deferred as _saved_page;
import 'package:sitewise_jaspr_web/features/panorama_viewer/presentation/components/canonical_panorama_panel.dart'
    deferred as _canonical_panorama_panel;
import 'package:sitewise_jaspr_web/features/panorama_viewer/presentation/pages/tour_page.dart'
    deferred as _tour_page;
import 'package:sitewise_jaspr_web/features/profile/presentation/pages/admin_profile_page.dart'
    deferred as _admin_profile_page;
import 'package:sitewise_jaspr_web/features/profile/presentation/pages/entrepreneur_profile_page.dart'
    deferred as _entrepreneur_profile_page;
import 'package:sitewise_jaspr_web/features/property_management/presentation/pages/assessment_report_selector_view.dart'
    deferred as _assessment_report_selector_view;
import 'package:sitewise_jaspr_web/features/property_verification/presentation/components/verification_detail_view.dart'
    deferred as _verification_detail_view;
import 'package:sitewise_jaspr_web/features/recommendations/presentation/pages/ai_recommendations_page.dart'
    deferred as _ai_recommendations_page;
import 'package:sitewise_jaspr_web/features/recommendations/presentation/pages/explanation_page.dart'
    deferred as _explanation_page;
import 'package:sitewise_jaspr_web/features/recommendations/presentation/pages/preferences_page.dart'
    deferred as _preferences_page;
import 'package:sitewise_jaspr_web/features/recommendations/presentation/pages/property_analysis_page.dart'
    deferred as _property_analysis_page;
import 'package:sitewise_jaspr_web/features/recommendations/presentation/pages/recommendations_page.dart'
    deferred as _recommendations_page;
import 'package:sitewise_jaspr_web/shared/presentation/components/m2_activity_panel.dart'
    deferred as _m2_activity_panel;
import 'package:sitewise_jaspr_web/shared/presentation/components/project1_read_panel.dart'
    deferred as _project1_read_panel;
import 'package:sitewise_jaspr_web/shared/presentation/pages/landing_page.dart'
    deferred as _landing_page;

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
    'agent_assignment_control': ClientLoader(
      (p) => _agent_assignment_control.AgentAssignmentControl(
        propertyId: p['propertyId'] as String,
      ),
      loader: _agent_assignment_control.loadLibrary,
    ),
    'agent_change_requests_panel': ClientLoader(
      (p) => _agent_change_requests_panel.AgentChangeRequestsPanel(),
      loader: _agent_change_requests_panel.loadLibrary,
    ),
    'activity_page': ClientLoader(
      (p) => _activity_page.AdminActivityPage(),
      loader: _activity_page.loadLibrary,
    ),
    'agents_page': ClientLoader(
      (p) => _agents_page.AdminAgentsPage(),
      loader: _agents_page.loadLibrary,
    ),
    'campaigns_page': ClientLoader(
      (p) => _campaigns_page.AdminCampaignsPage(),
      loader: _campaigns_page.loadLibrary,
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
    'surveys_page': ClientLoader(
      (p) => _surveys_page.AdminSurveysPage(),
      loader: _surveys_page.loadLibrary,
    ),
    'user_detail_page': ClientLoader(
      (p) => _user_detail_page.UserDetailPage(id: p['id'] as String),
      loader: _user_detail_page.loadLibrary,
    ),
    'users_page': ClientLoader(
      (p) => _users_page.UsersPage(),
      loader: _users_page.loadLibrary,
    ),
    'assessment_workspace_page': ClientLoader(
      (p) => _assessment_workspace_page.AssessmentWorkspacePage(
        propertyId: p['propertyId'] as String,
        stage: p['stage'] as String,
        businessType: p['businessType'] as String,
      ),
      loader: _assessment_workspace_page.loadLibrary,
    ),
    'report_page': ClientLoader(
      (p) => _report_page.ReportPage(id: p['id'] as String),
      loader: _report_page.loadLibrary,
    ),
    'reports_page': ClientLoader(
      (p) => _reports_page.ReportsPage(),
      loader: _reports_page.loadLibrary,
    ),
    'auth_callback_page': ClientLoader(
      (p) => _auth_callback_page.AuthCallbackPage(),
      loader: _auth_callback_page.loadLibrary,
    ),
    'forgot_password_page': ClientLoader(
      (p) => _forgot_password_page.ForgotPasswordPage(),
      loader: _forgot_password_page.loadLibrary,
    ),
    'login_page': ClientLoader(
      (p) => _login_page.LoginPage(portal: p['portal'] as String?),
      loader: _login_page.loadLibrary,
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
    'staff_verify_page': ClientLoader(
      (p) => _staff_verify_page.StaffVerifyPage(),
      loader: _staff_verify_page.loadLibrary,
    ),
    'compare_page': ClientLoader(
      (p) => _compare_page.ComparePage(),
      loader: _compare_page.loadLibrary,
    ),
    'entrepreneur_dashboard_page': ClientLoader(
      (p) => _entrepreneur_dashboard_page.DashboardPage(),
      loader: _entrepreneur_dashboard_page.loadLibrary,
    ),
    'business_concept_panel': ClientLoader(
      (p) => _business_concept_panel.BusinessConceptPanel(
        propertyId: p['propertyId'] as String,
      ),
      loader: _business_concept_panel.loadLibrary,
    ),
    'commercial_listing_page': ClientLoader(
      (p) =>
          _commercial_listing_page.CommercialListingPage(id: p['id'] as String),
      loader: _commercial_listing_page.loadLibrary,
    ),
    'explore_page': ClientLoader(
      (p) => _explore_page.ExplorePage(
        startInMap: p['startInMap'] as bool,
        initialPropertyId: p['initialPropertyId'] as String?,
      ),
      loader: _explore_page.loadLibrary,
    ),
    'property_detail_page': ClientLoader(
      (p) => _property_detail_page.PropertyDetailPage(
        id: p['id'] as String,
        resultId: p['resultId'] as String,
        appliedFiltersJson: p['appliedFiltersJson'] as String,
        businessType: p['businessType'] as String,
      ),
      loader: _property_detail_page.loadLibrary,
    ),
    'saved_page': ClientLoader(
      (p) => _saved_page.SavedPage(),
      loader: _saved_page.loadLibrary,
    ),
    'canonical_panorama_panel': ClientLoader(
      (p) => _canonical_panorama_panel.CanonicalPanoramaPanel(
        propertyId: p['propertyId'] as String,
      ),
      loader: _canonical_panorama_panel.loadLibrary,
    ),
    'tour_page': ClientLoader(
      (p) => _tour_page.TourPage(id: p['id'] as String),
      loader: _tour_page.loadLibrary,
    ),
    'admin_profile_page': ClientLoader(
      (p) => _admin_profile_page.ProfilePage(),
      loader: _admin_profile_page.loadLibrary,
    ),
    'entrepreneur_profile_page': ClientLoader(
      (p) => _entrepreneur_profile_page.ProfilePage(),
      loader: _entrepreneur_profile_page.loadLibrary,
    ),
    'assessment_report_selector_view': ClientLoader(
      (p) => _assessment_report_selector_view.AssessmentReportSelectorView(),
      loader: _assessment_report_selector_view.loadLibrary,
    ),
    'verification_detail_view': ClientLoader(
      (p) => _verification_detail_view.VerificationDetailView(),
      loader: _verification_detail_view.loadLibrary,
    ),
    'ai_recommendations_page': ClientLoader(
      (p) => _ai_recommendations_page.AiRecommendationsPage(
        resultId: p['resultId'] as String,
      ),
      loader: _ai_recommendations_page.loadLibrary,
    ),
    'explanation_page': ClientLoader(
      (p) => _explanation_page.ExplanationPage(
        propertyId: p['propertyId'] as String,
      ),
      loader: _explanation_page.loadLibrary,
    ),
    'preferences_page': ClientLoader(
      (p) => _preferences_page.PreferencesPage(),
      loader: _preferences_page.loadLibrary,
    ),
    'property_analysis_page': ClientLoader(
      (p) =>
          _property_analysis_page.PropertyAnalysisPage(id: p['id'] as String),
      loader: _property_analysis_page.loadLibrary,
    ),
    'recommendations_page': ClientLoader(
      (p) => _recommendations_page.RecommendationsPage(
        initialPropertyId: p['initialPropertyId'] as String?,
      ),
      loader: _recommendations_page.loadLibrary,
    ),
    'm2_activity_panel': ClientLoader(
      (p) => _m2_activity_panel.M2ActivityPanel(
        assessmentId: p['assessmentId'] as String,
      ),
      loader: _m2_activity_panel.loadLibrary,
    ),
    'project1_read_panel': ClientLoader(
      (p) => _project1_read_panel.Project1ReadPanel(
        assessmentId: p['assessmentId'] as String,
        section: p['section'] as String,
      ),
      loader: _project1_read_panel.loadLibrary,
    ),
    'landing_page': ClientLoader(
      (p) => _landing_page.LandingPage(),
      loader: _landing_page.loadLibrary,
    ),
  },
);
