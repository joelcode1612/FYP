import 'package:flutter/material.dart';
import 'package:shared_logic/shared_logic.dart';
import '../../../../core/di/service_locator.dart';
import 'viewmodels/cq_view_model.dart';
import 'questionnaire_screen.dart';

/// Uses the existing questionnaire and VM with an explicit authorized binding.
class SyntheticSessionHost extends StatefulWidget {
  const SyntheticSessionHost({
    super.key,
    required this.runId,
    required this.sessionId,
    this.repository,
  });
  final String runId, sessionId;
  final ApiCustomerQuestionnaireRepository? repository;
  @override
  State<SyntheticSessionHost> createState() => _SyntheticSessionHostState();
}

class _SyntheticSessionHostState extends State<SyntheticSessionHost> {
  // The normal navigation container can own a family with this same UUID.
  // Bind this route explicitly, and retain its controller across shell rebuilds.
  late final controller = CqViewModel(
    widget.repository ??
        ApiCustomerQuestionnaireRepository.synthetic(
          ServiceLocator.apiClient,
          runId: widget.runId,
        ),
    widget.sessionId,
  );
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => QuestionnaireScreen(
    assessmentId: widget.sessionId,
    viewModel: controller,
  );
}
