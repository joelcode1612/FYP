import 'package:flutter/material.dart';
import 'package:fyp/core/routing/app_routes.dart';
import 'package:fyp/shared/presentation/layouts/mobile_app_shell.dart';
import 'cq_session_page.dart';

/// Route compatibility: assessmentId now carries a persisted CQ session UUID.
/// Historical local preview drafts are deliberately not read or uploaded.
class ReviewScreen extends StatelessWidget {
  final String assessmentId;
  const ReviewScreen({super.key, required this.assessmentId});
  @override
  Widget build(BuildContext context) => MobileAppShell(
    title: 'Questionnaire',
    // Review is the last step of the questionnaire opened from the invitation
    // tab, so that tab stays selected behind it.
    currentRoute: AppRoutes.assessmentHome,
    body: CqSessionPage(sessionId: assessmentId),
  );
}
