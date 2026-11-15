import 'package:flutter/material.dart';
import 'components/cq_ui_primitives.dart';

export '../../../core/config/assessment_build_mode.dart'
    show assessmentDemoAllowed, assessmentHoldActive;

/// Preserves the application's release hold. No demo offers or locally
/// invented questionnaires become available through this screen.
class AssessmentLiveHold extends StatelessWidget {
  const AssessmentLiveHold({super.key});

  @override
  Widget build(BuildContext context) => const CqPageFrame(
    children: [
      CqHero(
        title: 'Your questionnaires',
        subtitle: 'Start a questionnaire or continue where you stopped.',
      ),
      CqNotice(
        message: 'QUESTIONNAIRE COLLECTION ON HOLD · NO DEMO DATA',
        tone: CqNoticeTone.warning,
      ),
      CqPanel(
        title: 'Questionnaire unavailable',
        icon: Icons.lock_outline,
        child: Text(
          'The approved customer questionnaire backend is not available in this build. '
          'No questionnaire is being fielded and no synthetic demo content is shown here.',
          style: TextStyle(color: CqUiColors.ink, height: 1.45),
        ),
      ),
    ],
  );
}
