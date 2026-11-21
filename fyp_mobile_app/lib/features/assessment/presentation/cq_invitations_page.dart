import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';
import '../../../core/routing/app_routes.dart';
import '../../../core/config/dev_auth_bypass.dart';
import '../../../core/config/cq_development_access.dart';
import 'package:fyp/features/assessment/presentation/viewmodels/cq_view_model.dart';
import 'package:fyp/features/assessment/presentation/widgets/cq_ui_primitives.dart';

/// UI-only refresh of the existing authenticated invitation workflow.
/// Never constructs invitations or authorizes customer fielding on the client.
class CqInvitationsPage extends ConsumerStatefulWidget {
  const CqInvitationsPage({super.key});

  @override
  ConsumerState<CqInvitationsPage> createState() => _CqInvitationsPageState();
}

class _CqInvitationsPageState extends ConsumerState<CqInvitationsPage> {
  bool busy = true;
  String? message;
  List<CqInvitation> invitations = [];
  List<Map<String, dynamic>> developerRuns = [];

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      busy = true;
      message = null;
      invitations = [];
    });
    try {
      final result = await ref.read(cqRepositoryProvider).invitations();
      if (!mounted) return;
      setState(() {
        invitations = result.invitations;
        message = result.state == 'held'
            ? 'Customer questionnaires are held pending scientific review and fielding authorization.'
            : result.state == 'empty'
            ? 'No authorized questionnaire invitations are available.'
            : null;
      });
    } on UnauthorizedFailure catch (e) {
      if (mounted) {
        setState(
          () => message = devAuthBypassEnabled
              ? 'Development access is active, but no authorized questionnaire test session is connected. The sign-in bypass opens screens; it does not create an API session. Connect the isolated test environment to load questionnaires.'
              : e.userMessage,
        );
      }
    } on AppFailure catch (e) {
      if (mounted) setState(() => message = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => message = 'Questionnaire invitations are unavailable.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
    // Separate optional capability. An ordinary account has no granted runs;
    // failure here never changes participation or its existing hold message.
    try {
      final runs = await ApiSyntheticInspectionRepository(
        ServiceLocator.apiClient,
      ).runs();
      if (mounted) setState(() => developerRuns = runs);
    } catch (_) {
      if (mounted) setState(() => developerRuns = []);
    }
  }

  Future<void> _open(CqInvitation invitation) async {
    setState(() => busy = true);
    try {
      final session = invitation.sessionId == null
          ? await ref.read(cqRepositoryProvider).start(invitation, 'EN')
          : await ref.read(cqRepositoryProvider).read(invitation.sessionId!);
      if (mounted) {
        await Navigator.of(
          context,
        ).pushNamed(AppRoutes.assessmentQuestionnaire, arguments: session.id);
      }
      await _load();
    } on AppFailure catch (e) {
      if (mounted) setState(() => message = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => message = 'This questionnaire is unavailable or held.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => CqPageFrame(
    children: [
      const CqHero(
        title: 'Questionnaire invitations',
        subtitle:
            'Select an authorized invitation to start or resume a questionnaire.',
      ),
      if (CqDevelopmentAccess.enabled)
        const CqNotice(
          message: 'Isolated development session — no customer fielding',
          tone: CqNoticeTone.warning,
          messageKey: Key('cq-development-session'),
        ),
      if (busy) const LinearProgressIndicator(),
      if (message != null)
        CqNotice(
          message: message!,
          tone: CqNoticeTone.warning,
          messageKey: const Key('cq-invitations-state'),
        ),
      for (final invitation in invitations)
        CqPanel(
          title: invitation.title,
          icon: Icons.assignment_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                invitation.sessionId == null
                    ? 'Ready to start when authorized.'
                    : 'Saved session available to resume.',
                style: const TextStyle(color: CqUiColors.secondary),
              ),
              const SizedBox(height: 14),
              CqFullWidthAction(
                text: invitation.sessionId == null ? 'Start' : 'Resume',
                icon: invitation.sessionId == null
                    ? Icons.play_arrow_rounded
                    : Icons.arrow_forward_rounded,
                onPressed: busy ? null : () => _open(invitation),
              ),
            ],
          ),
        ),
      for (final run in developerRuns)
        CqPanel(
          title: 'Developer-only synthetic inspection',
          child: Column(
            children: [
              const Text(
                'SYNTHETIC / NOT REPORTABLE — separate from participation',
              ),
              TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        SyntheticInspectionPage(runId: run['run_id'] as String),
                  ),
                ),
                child: const Text('Inspect stored test records'),
              ),
            ],
          ),
        ),
      Center(
        child: TextButton.icon(
          onPressed: busy ? null : _load,
          icon: const Icon(Icons.refresh_outlined),
          label: const Text('Refresh'),
        ),
      ),
    ],
  );
}
