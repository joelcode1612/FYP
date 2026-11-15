import 'package:flutter/material.dart';

import '../../../../core/theme/sitewise_theme.dart';

/// The registration progress indicator.
///
/// Current = filled royal-blue circle with its number, completed = white
/// circle with a blue border and check, upcoming = outlined grey circle.
/// Connectors run exactly between circle centres, so the rule stays straight
/// on narrow phones and on tablets alike. All colours come from
/// [SitewiseColors]; no new palette is introduced.
///
/// The step list is passed in because the funnel is CONDITIONAL: Entrepreneur
/// registration is two steps (no email verification), while an Owner / Agent
/// account has a third security step (the authenticator screen). The old
/// hard-coded "Verify" step is only the default for callers that still want
/// the three-stage reference layout — the signup page never uses it.
class SignupStepIndicator extends StatelessWidget {
  const SignupStepIndicator({
    super.key,
    required this.currentStep,
    this.labels = defaultLabels,
  });

  /// Zero-based index of the current step.
  final int currentStep;

  final List<String> labels;

  /// The original three-stage reference layout, kept for previews/tests.
  static const List<String> defaultLabels = <String>[
    'Account Type',
    'Account Details',
    'Verify',
  ];

  /// Entrepreneur: two steps, no verification screen.
  static const List<String> entrepreneurLabels = <String>[
    'Account Type',
    'Account Details',
  ];

  /// Owner / Agent: the final stage is MFA, never email confirmation.
  static const List<String> providerLabels = <String>[
    'Account Type',
    'Account Details',
    'Authenticator',
  ];

  @override
  Widget build(BuildContext context) {
    final count = labels.length;
    final step = currentStep.clamp(0, count - 1);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // N equally wide columns put the circle centres at (i + 0.5)/N of the
        // available width. Insetting the connectors by 1/(2N) on each side
        // makes the segments meet exactly at the interior circles.
        final inset = constraints.maxWidth / (2 * count);
        return Semantics(
          label: 'Step ${step + 1} of $count: ${labels[step]}',
          child: SizedBox(
            height: 62,
            child: Stack(
              children: <Widget>[
                Positioned(
                  left: inset,
                  right: inset,
                  top: 14.5,
                  child: Row(
                    children: <Widget>[
                      for (var i = 0; i < count - 1; i++)
                        Expanded(child: _connector(done: step > i)),
                    ],
                  ),
                ),
                Row(
                  children: <Widget>[
                    for (var i = 0; i < count; i++)
                      Expanded(
                        child: Column(
                          children: <Widget>[
                            _circle(index: i, step: step),
                            const SizedBox(height: 7),
                            Text(
                              labels[i],
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: i == step
                                    ? FontWeight.w800
                                    : FontWeight.w600,
                                color: i == step
                                    ? SitewiseColors.action
                                    : SitewiseColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _connector({required bool done}) => Container(
    height: 1.5,
    color: done ? SitewiseColors.action : SitewiseColors.borderStrong,
  );

  Widget _circle({required int index, required int step}) {
    final completed = index < step;
    final current = index == step;
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: current ? SitewiseColors.action : SitewiseColors.surface,
        border: Border.all(
          color: completed || current
              ? SitewiseColors.action
              : SitewiseColors.borderStrong,
          width: 1.6,
        ),
      ),
      alignment: Alignment.center,
      child: completed
          ? const Icon(
              Icons.check_rounded,
              size: 17,
              color: SitewiseColors.action,
            )
          : Text(
              '${index + 1}',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: current ? Colors.white : SitewiseColors.muted,
              ),
            ),
    );
  }
}
