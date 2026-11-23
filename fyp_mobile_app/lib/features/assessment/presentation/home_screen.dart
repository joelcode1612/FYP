import 'package:flutter/material.dart';
import 'package:fyp/core/routing/app_routes.dart';
import 'package:fyp/shared/presentation/layouts/mobile_app_shell.dart';
import 'package:fyp/features/assessment/presentation/cq_invitations_page.dart';

/// Route compatibility: assessmentId now carries a persisted CQ session UUID.
/// Historical local preview drafts are deliberately not read or uploaded.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});
  @override
  Widget build(BuildContext context) => MobileAppShell(
    title: 'Questionnaire invitations',
    // Third tab. Inside `EntrepreneurTabHost` the shell returns the body only;
    // pushed as a standalone route it highlights that same tab.
    currentRoute: AppRoutes.assessmentHome,
    body: const CqInvitationsPage(),
  );
}
