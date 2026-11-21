import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fyp/core/di/app_providers.dart';
import 'package:fyp/core/routing/app_routes.dart';
import 'package:fyp/core/theme/sitewise_theme.dart';
import 'package:fyp/features/assessment/domain/entities/assessment.dart';
import 'package:fyp/features/assessment/domain/entities/assessment_draft.dart';
import 'package:fyp/features/assessment/presentation/widgets/assessment_card.dart';

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
