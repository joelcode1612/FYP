import 'package:flutter/material.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../application/services/assessment_session.dart';
import '../../../../application/services/service_locator.dart';
import '../../../../core/theme/sitewise_m3.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/m3_kit.dart';
import '../../../shared/widgets/sitewise_bottom_sheet.dart';

/// **Assess** — the third tab of the consolidated five-tab navigation.
///
/// Option A assessment hub: the in-session draft (if any) with its progress,
/// a New action that opens the property picker, and honest state labels.
/// There is **no persisted assessment entity** in this app, so every record
/// shown here is explicitly marked session-only, and the draft store
/// ([AssessmentSessionStore]) keeps a single active assessment — reopening an
/// existing one resumes it instead of creating a duplicate.

class EntrepreneurAssessMobilePage extends StatelessWidget {
  final AppCubit appState;
  const EntrepreneurAssessMobilePage({super.key, required this.appState});

  @override
  Widget build(BuildContext context) {
    final draft = ServiceLocator.assessmentSession.draft;
    return MobileAppShell(
      appState: appState,
      title: 'Assess',
      currentRoute: '/entrepreneur/assess',
      body: M3Content(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(
                child: M3ScreenHeading(
                  eyebrow: 'Demand assessments',
                  title: 'Your assessments',
                  lead: 'Resume work or evaluate another property.',
                ),
              ),
              const SizedBox(width: 10),
              _NewAssessmentButton(onStart: () => _startNew(context)),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _SessionMetric(
                  value: draft == null || draft.saved ? '0' : '1',
                  label: 'In progress',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _SessionMetric(
                  value: draft?.saved == true ? '1' : '0',
                  label: 'Saved this session',
                ),
              ),
            ],
          ),
          const M3SectionRow(title: 'Recent activity', overline: 'THIS SESSION'),
          if (draft == null)
            M3EmptyState(
              icon: Icons.assignment_outlined,
              title: 'No assessments yet',
              message: 'Start from a listing, or pick a property with the '
                  'New button, to assess it for your business.',
              actionLabel: 'Find a location',
              onAction: () =>
                  Navigator.of(context).pushNamed('/entrepreneur/explore'),
            )
          else ...[
            _DraftCard(
              draft: draft,
              onOpen: () => _openDraft(context, draft),
            ),
          ],
          const M3Banner(
            text: 'Assessments are kept for this session only. Nothing is '
                'stored as history yet.',
          ),
          const M3DataNote(
            text: 'You can begin an assessment from a listing and return to '
                'it here without selecting the property again.',
          ),
        ],
      ),
    );
  }

  /// Resume at the right step: business details first, then evidence, then
  /// the saved summary.
  void _openDraft(BuildContext context, AssessmentDraft draft) {
    if (draft.saved) {
      Navigator.of(context).pushNamed('/entrepreneur/assessment-summary');
    } else if (draft.hasInputs) {
      Navigator.of(context).pushNamed('/entrepreneur/assessment-evidence');
    } else {
      Navigator.of(context).pushNamed('/entrepreneur/assessment-setup');
    }
  }

  /// New assessment → existing property-selection workflow: a bottom sheet
  /// listing real repository properties. The chosen id travels as route
  /// arguments; the setup screen links it to the draft.
  Future<void> _startNew(BuildContext context) async {
    await showSitewiseBottomSheet<void>(
      context,
      title: 'Choose a property',
      builder: (_) => FutureBuilder<List<CommercialProperty>>(
        future: ServiceLocator.properties.listings(),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final properties = snap.data ?? const <CommercialProperty>[];
          if (properties.isEmpty) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Text('No properties are available right now.'),
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final p in properties)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    p.title,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontWeight: FontWeight.w700,
                      color: SitewiseM3.ink,
                    ),
                  ),
                  subtitle: Text(
                    '${p.city} · ${p.rentalDisplay}',
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      color: SitewiseM3.muted,
                    ),
                  ),
                  trailing: const Icon(
                    Icons.arrow_forward_ios_rounded,
                    size: 15,
                    color: SitewiseM3.stone,
                  ),
                  onTap: () {
                    Navigator.of(context).pop();
                    Navigator.of(context).pushNamed(
                      '/entrepreneur/assessment-setup',
                      arguments: p.id,
                    );
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Compact header action (`.btn.primary` at pill size). Full-width
/// [M3PrimaryButton] would fight the heading for space.
class _NewAssessmentButton extends StatelessWidget {
  final VoidCallback onStart;

  const _NewAssessmentButton({required this.onStart});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Create new assessment',
      child: Material(
        color: SitewiseM3.primary,
        borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
        child: InkWell(
          borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
          onTap: onStart,
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
              border: Border.all(color: SitewiseM3.primary),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.add_rounded,
                  size: 17,
                  color: SitewiseM3.surface,
                ),
                const SizedBox(width: 5),
                Text(
                  'New',
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: SitewiseM3.surface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// `.metric` reduced to the big number + caption the hub needs. Session
/// counts only — they describe the draft store, never a stored history.
class _SessionMetric extends StatelessWidget {
  final String value;
  final String label;

  const _SessionMetric({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      decoration: BoxDecoration(
        color: SitewiseM3.metricBlueBg,
        borderRadius: BorderRadius.circular(SitewiseM3.radiusMetric),
        border: Border.all(color: SitewiseM3.metricBlueBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 26,
              fontWeight: FontWeight.w800,
              height: 1.05,
              letterSpacing: -1.1,
              color: SitewiseM3.metricValue,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 11,
              color: Color(0xFF3A5983),
            ),
          ),
        ],
      ),
    );
  }
}

class _DraftCard extends StatelessWidget {
  final AssessmentDraft draft;
  final VoidCallback onOpen;

  const _DraftCard({required this.draft, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final p = draft.property;
    final saved = draft.saved;
    final statusColor = saved ? SitewiseM3.green : SitewiseM3.primary;
    return M3Card(
      padding: const EdgeInsets.all(15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 7),
              Text(
                saved ? 'Saved in this session' : 'In progress',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: statusColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Text(
            draft.concept.isEmpty ? p.title : '${p.title} · ${draft.concept}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 14,
              fontWeight: FontWeight.w800,
              height: 1.25,
              color: SitewiseM3.rowTitle,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            saved ? 'Survey evidence not connected' : 'Linked property · ${p.id}',
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 11,
              color: SitewiseM3.rowDesc,
            ),
          ),
          if (!saved) ...[
            const SizedBox(height: 11),
            Semantics(
              label: 'Assessment progress: step ${draft.step + 1} of 3',
              child: Stack(
                children: [
                  Container(
                    height: 6,
                    decoration: BoxDecoration(
                      color: SitewiseM3.quiet,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  FractionallySizedBox(
                    widthFactor: (draft.step + 1) / 3,
                    child: Container(
                      height: 6,
                      decoration: BoxDecoration(
                        color: SitewiseM3.primary,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 11),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Local draft only',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 10.5,
                    color: SitewiseM3.stone,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: onOpen,
                icon: const Icon(Icons.arrow_forward_rounded, size: 14),
                label: Text(saved ? 'Open summary' : 'Continue'),
                style: TextButton.styleFrom(
                  foregroundColor: SitewiseM3.primary,
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  textStyle: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
