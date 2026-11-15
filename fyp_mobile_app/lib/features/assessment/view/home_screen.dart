import 'package:flutter/material.dart';
import '../../../presentation/mobile/shell/mobile_app_shell.dart';
import 'cq_invitations_page.dart';

/// Route compatibility: assessmentId now carries a persisted CQ session UUID.
/// Historical local preview drafts are deliberately not read or uploaded.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});
  @override
  Widget build(BuildContext context) => MobileAppShell(
    title: 'Home',
    currentRoute: '/entrepreneur/assess',
    body: const CqInvitationsPage(),
  );
}
