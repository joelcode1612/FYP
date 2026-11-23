import 'package:flutter/material.dart';

import 'package:fyp/core/theme/sitewise_theme.dart';
import 'package:fyp/shared/presentation/widgets/sitewise_button.dart';
import 'package:fyp/shared/presentation/widgets/sitewise_secondary_button.dart';

/// Post-submission confirmation for the Agent's Admin verification.
///
/// Shown ONLY after the backend has answered the submit call successfully —
/// the status line comes from the submission response (`stage`), never from
/// a client-side assumption. From here the Agent can review the submitted
/// property; the review lock is the backend's, so this screen only offers
/// navigation.
class ProviderSubmissionSuccessPage extends StatelessWidget {
  const ProviderSubmissionSuccessPage({
    super.key,
    required this.propertyId,
    required this.stage,
  });

  final int propertyId;

  /// The backend's submission stage, e.g. `pending_admin_review`.
  final String stage;

  String get _statusLabel => switch (stage) {
    'pending_admin_review' => 'Pending Admin Review',
    final other => other.replaceAll('_', ' '),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Submission complete')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    size: 72,
                    color: SitewiseColors.success,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Submitted Successfully',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Your property has been sent for Administrator '
                    'verification.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.78),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.hourglass_top_rounded,
                            size: 18,
                            color: SitewiseColors.warning,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Status: $_statusLabel',
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  SitewiseButton(
                    label: 'View Submission',
                    icon: Icons.visibility_outlined,
                    onPressed: () {
                      Navigator.of(context).pushNamedAndRemoveUntil(
                        '/provider/property-detail',
                        (route) => route.isFirst,
                        arguments: propertyId,
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  SitewiseSecondaryButton(
                    label: 'Back to My Properties',
                    icon: Icons.list_alt_rounded,
                    onPressed: () {
                      Navigator.of(context).popUntil((route) => route.isFirst);
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
