import 'package:flutter/material.dart';

import 'package:fyp/core/theme/sitewise_m3.dart';
import 'package:fyp/core/theme/sitewise_theme.dart';
import 'package:fyp/shared/presentation/components/provider_ui.dart';

/// Role-specific instructions only. No statuses, assignments or inspection
/// outcomes are inferred or persisted by this widget.
///
/// All actions open EXISTING, authorized provider routes. The backend remains
/// the authority for every request, ownership check and submission.
class ProviderProcessOverview extends StatelessWidget {
  const ProviderProcessOverview({
    super.key,
    required this.isAgent,
    required this.onOpen,
  });

  final bool isAgent;
  final void Function(String route) onOpen;

  @override
  Widget build(BuildContext context) {
    final steps = isAgent ? _agentSteps : _ownerSteps;
    return ProviderCard(
      title: isAgent ? 'Your inspection workflow' : 'Your listing workflow',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isAgent
                ? 'Only properties assigned to you appear here. Verify the '
                      'physical details and record proposed corrections.'
                : 'Register your property once, keep ownership evidence ready, '
                      'and follow its review progress.',
            style: const TextStyle(
              fontFamily: kFontFamily,
              color: SitewiseM3.muted,
              fontSize: 14,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),
          for (var index = 0; index < steps.length; index++) ...[
            _ProcessStep(number: index + 1, step: steps[index]),
            if (index < steps.length - 1)
              const Padding(
                padding: EdgeInsets.only(left: 19),
                child: SizedBox(
                  height: 22,
                  child: VerticalDivider(
                    thickness: 1,
                    width: 1,
                    color: SitewiseM3.line,
                  ),
                ),
              ),
          ],
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => onOpen(
                isAgent ? '/provider/tasks' : '/provider/add-property',
              ),
              icon: Icon(isAgent ? Icons.fact_check_outlined : Icons.add_rounded),
              label: Text(isAgent ? 'Review inspection tasks' : 'Add a property'),
              style: FilledButton.styleFrom(
                backgroundColor: SitewiseColors.action,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(48),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProcessStep extends StatelessWidget {
  const _ProcessStep({required this.number, required this.step});

  final int number;
  final _ProcessStepData step;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        width: 38,
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: SitewiseM3.quiet,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: SitewiseM3.line),
        ),
        child: Text(
          number.toString().padLeft(2, '0'),
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontWeight: FontWeight.w800,
            color: SitewiseColors.action,
            fontSize: 15,
          ),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              step.title,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: SitewiseM3.ink,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              step.description,
              style: const TextStyle(
                fontFamily: kFontFamily,
                color: SitewiseM3.muted,
                fontSize: 13,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

class _ProcessStepData {
  const _ProcessStepData(this.title, this.description);
  final String title;
  final String description;
}

const _ownerSteps = <_ProcessStepData>[
  _ProcessStepData(
    'Create property',
    'Enter the rental details, verify the address, and add photographs.',
  ),
  _ProcessStepData(
    'Provide ownership proof',
    'Submit the required documents through the property verification flow.',
  ),
  _ProcessStepData(
    'Inspection and 360° evidence',
    'Only your assigned Agent performs the independent inspection and '
        'captures the virtual tour.',
  ),
  _ProcessStepData(
    'Administrator review',
    'Only Admin can approve the property and publish an eligible listing.',
  ),
];

const _agentSteps = <_ProcessStepData>[
  _ProcessStepData(
    'Review assigned property',
    'Open a property assigned to your Agent account. Do not create a duplicate.',
  ),
  _ProcessStepData(
    'Inspect the physical facts',
    'Compare floor area, condition, access and parking against the listing.',
  ),
  _ProcessStepData(
    'Capture the 360° tour',
    'Open the property and use its existing 360° capture action.',
  ),
  _ProcessStepData(
    'Submit inspection to Admin',
    'After checks and a completed 360° panorama, confirm and send the property for Admin review.',
  ),
];
