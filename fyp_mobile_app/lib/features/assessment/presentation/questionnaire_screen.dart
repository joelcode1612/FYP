import 'package:flutter/material.dart';
import 'package:fyp/core/routing/app_routes.dart';
import 'package:fyp/shared/presentation/layouts/mobile_app_shell.dart';
import 'cq_session_page.dart';
import 'viewmodels/cq_view_model.dart';

/// Route compatibility: assessmentId now carries a persisted CQ session UUID.
/// Historical local preview drafts are deliberately not read or uploaded.
class QuestionnaireScreen extends StatelessWidget {
  final String assessmentId;
  final CqViewModel? viewModel;
  const QuestionnaireScreen({
    super.key,
    required this.assessmentId,
    this.viewModel,
  });
  @override
  Widget build(BuildContext context) => MobileAppShell(
    title: 'Questionnaire',
    // Opened from the invitation list, so the invitation tab stays selected
    // behind the questionnaire.
    currentRoute: AppRoutes.assessmentHome,
    body: CqSessionPage(sessionId: assessmentId, viewModel: viewModel),
  );
}
