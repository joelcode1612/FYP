import 'package:flutter/material.dart';
import '../../../presentation/mobile/shell/mobile_app_shell.dart';
import 'cq_session_page.dart';
import '../viewmodel/cq_view_model.dart';

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
    currentRoute: '/entrepreneur/assess',
    body: CqSessionPage(sessionId: assessmentId, viewModel: viewModel),
  );
}
