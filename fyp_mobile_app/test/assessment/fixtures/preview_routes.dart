// Isolated legacy UI regression harness; never installed by SitewiseApp.
import 'package:flutter/material.dart';
import 'package:fyp/core/routing/app_routes.dart';
import 'package:fyp/core/routing/auth_route_guard.dart';
import 'package:fyp/features/assessment/view/assessment_draft_loader.dart';
import 'home_screen.dart';
import 'questionnaire_screen.dart';
import 'review_screen.dart';

Route<dynamic>? previewRoute(RouteSettings settings) {
  Widget Function()? page;
  if (settings.name == AppRoutes.assessmentHome) {
    page = () => const HomeScreen();
  } else if (settings.name == AppRoutes.assessmentQuestionnaire ||
      settings.name == AppRoutes.assessmentReview) {
    page = () => AssessmentDraftLoader(
      assessmentId: settings.arguments as String? ?? '',
      builder: (id) => settings.name == AppRoutes.assessmentReview
          ? ReviewScreen(assessmentId: id) : QuestionnaireScreen(assessmentId: id),
    );
  }
  if (page == null) return AppRoutes.onGenerateRoute(settings);
  return MaterialPageRoute(settings: settings, builder: (_) => AuthGuard(
    access: RouteAccess.workspace, builder: (_) => page!(),
  ));
}
