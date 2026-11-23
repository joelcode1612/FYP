import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';
import '../../../core/di/service_locator.dart';
import '../../../core/routing/app_routes.dart';
import '../../../core/config/dev_auth_bypass.dart';
import '../../../core/config/cq_development_access.dart';
import 'package:fyp/features/assessment/presentation/viewmodels/cq_view_model.dart';
import 'package:fyp/features/assessment/presentation/cq_error_message.dart';
import 'package:fyp/features/assessment/presentation/widgets/cq_ui_primitives.dart';
import 'synthetic_inspection_page.dart';

/// UI-only refresh of the existing authenticated invitation workflow.
/// Never constructs invitations or authorizes customer fielding on the client.
class CqInvitationsPage extends ConsumerStatefulWidget {
  const CqInvitationsPage({super.key});

  @override
  ConsumerState<CqInvitationsPage> createState() => _CqInvitationsPageState();
}

class _CqInvitationsPageState extends ConsumerState<CqInvitationsPage> {
  /// Fixed fallbacks. They never incorporate server, transport or decoder text.
  static const _genericLoadError =
      'We could not load your questionnaires. Pull down to try again.';
  static const _genericOpenError =
      'That questionnaire could not be opened. Pull down to try again.';

  bool busy = true;
  String? message;
  List<CqInvitation> invitations = [];
  List<Map<String, dynamic>> developerRuns = [];

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  /// Re-read invitations. [silent] is used by pull-to-refresh: the gesture
  /// already shows progress, so blanking the list first would make the page
  /// flash empty and jump under the user's finger.
  Future<void> _load({bool silent = false}) async {
    if (!mounted) return;
    setState(() {
      if (!silent) {
        busy = true;
        invitations = [];
        // Only a full load clears the notice. A pull-to-refresh keeps the last
        // known state on screen until the new result replaces it, so the banner
        // does not blink out and back.
        message = null;
      }
    });
    try {
      final result = await ref.read(cqRepositoryProvider).invitations();
      if (!mounted) return;
      setState(() {
        invitations = result.invitations;
        // Plain language on purpose. `reason` separates the two causes the API
        // used to collapse into one `held` state: the feature being switched off
        // versus this respondent not being authorized.
        message = result.state == 'held'
            ? result.reason == 'CQ_RUNTIME_DISABLED'
                  ? 'Questionnaires are not available right now. '
                        'Please try again later.'
                  : 'Questionnaires are not open yet. They will appear here '
                        'once they have been approved.'
            : result.state == 'empty'
            ? 'You have no questionnaires to answer right now.'
            : null;
      });
    } on UnauthorizedFailure catch (e) {
      if (mounted) {
        setState(
          () => message = devAuthBypassEnabled
              ? 'You are viewing the app without signing in, so your '
                    'questionnaires cannot be loaded. Sign in to see them.'
              : e.userMessage,
        );
      }
    } on AppFailure catch (e) {
      // Never render e.message: it is whatever the API or transport produced.
      logCqFailure('invitations load', e);
      if (mounted) {
        setState(
          () => message = cqErrorMessage(
            e,
            fallback: _genericLoadError,
          ),
        );
      }
    } catch (e) {
      logCqFailure('invitations load', e);
      if (mounted) {
        setState(
          () => message = _genericLoadError,
        );
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
      logCqFailure('invitation open', e);
      if (mounted) {
        setState(
          () => message = cqErrorMessage(e, fallback: _genericOpenError),
        );
      }
    } catch (e) {
      logCqFailure('invitation open', e);
      if (mounted) {
        setState(() => message = _genericOpenError);
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => CqPageFrame(
    // Pull down to re-read invitations. There is no Refresh button: the gesture
    // is the whole affordance, and the list is always scrollable so it works
    // even when the only child is the held/empty notice.
    onRefresh: () => _load(silent: true),
    children: [
      const CqHero(
        title: 'Questionnaire invitations',
        subtitle: 'Choose a questionnaire to start, or continue one you began.',
      ),
      if (CqDevelopmentAccess.enabled)
        const CqNotice(
          message: 'Test mode — these are not real customer responses',
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
                // A non-null sessionId proves a session exists, nothing more.
                // The API does not expose its state, so this must not say
                // "resume" — that would promise a resume for a questionnaire
                // the respondent has already submitted. Opening it is always
                // safe: the server returns whatever the session actually is.
                invitation.sessionId == null
                    ? 'Ready to start.'
                    : 'You have already opened this questionnaire.',
                style: const TextStyle(color: CqUiColors.secondary),
              ),
              const SizedBox(height: 14),
              CqFullWidthAction(
                text: invitation.sessionId == null ? 'Start' : 'Open',
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
    ],
  );
}
