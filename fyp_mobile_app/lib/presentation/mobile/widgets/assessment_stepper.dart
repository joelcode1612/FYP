import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_m3.dart';
import '../../../core/theme/sitewise_theme.dart';

/// The Option A assessment stepper — 1 Business / 2 Evidence / 3 Summary.
///
/// [step] is the zero-based current step; earlier steps render a check mark.
class AssessmentStepper extends StatelessWidget {
  final int step;

  const AssessmentStepper({super.key, required this.step});

  static const _labels = ['Business', 'Evidence', 'Summary'];

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Assessment step ${step + 1} of 3: ${_labels[step]}',
      child: Row(
        children: [
          for (var i = 0; i < _labels.length; i++) ...[
            if (i > 0)
              Expanded(
                child: Container(
                  height: 2,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  color: i <= step
                      ? SitewiseM3.brandBorder
                      : SitewiseM3.divider,
                ),
              ),
            _StepNode(label: _labels[i], done: i < step, current: i == step),
          ],
        ],
      ),
    );
  }
}

/// The small in-page back link the Option A flow screens use under the header.
class FlowBackLink extends StatelessWidget {
  final String label;

  const FlowBackLink({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () => Navigator.of(context).pop(),
        icon: const Icon(Icons.arrow_back_rounded, size: 16),
        label: Text(label),
        style: TextButton.styleFrom(
          foregroundColor: SitewiseM3.muted,
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          textStyle: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _StepNode extends StatelessWidget {
  final String label;
  final bool done;
  final bool current;

  const _StepNode({
    required this.label,
    required this.done,
    required this.current,
  });

  @override
  Widget build(BuildContext context) {
    final active = done || current;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? SitewiseM3.primary : SitewiseM3.quiet,
            shape: BoxShape.circle,
            border: Border.all(
              color: active ? SitewiseM3.primary : SitewiseM3.line,
            ),
          ),
          child: Text(
            done ? '✓' : label[0],
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: active ? Colors.white : SitewiseM3.muted,
            ),
          ),
        ),
        const SizedBox(width: 6),
        // Cap the label width and shrink to fit so a very narrow stepper row
        // can never overflow; real label widths stay below the cap.
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 56),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 11,
                fontWeight: current ? FontWeight.w800 : FontWeight.w600,
                color: active ? SitewiseM3.ink : SitewiseM3.muted,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
