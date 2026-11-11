import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';

/// One-line inline failure notice with a retry.
///
/// Used where a section can still render *some* data after a failed read (a
/// shortlist that failed to load while the catalogue resolved, a stale count on
/// the dashboard, a secondary property card on the tour screen). The rule these
/// screens follow: a failed read is never rendered as an empty or zero state —
/// the reason is stated next to the data that survived, with a retry that
/// re-runs the real request.
///
/// A failure that leaves nothing to show belongs in a full
/// `SitewiseErrorState` (or `AsyncSection`'s error branch) instead.
class SitewiseInlineNotice extends StatelessWidget {
  const SitewiseInlineNotice({
    super.key,
    required this.message,
    required this.onRetry,
    this.busy = false,
    this.icon = Icons.cloud_off_rounded,
  });

  final String message;

  /// Re-invokes the failed operation. Never a `setState` no-op.
  final VoidCallback onRetry;

  /// True while the retry is in flight — the button is disabled, not hidden, so
  /// the control does not jump.
  final bool busy;

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: SitewiseColors.danger.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: SitewiseColors.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 11.5,
                height: 1.35,
                color: SitewiseColors.danger,
              ),
            ),
          ),
          TextButton(
            onPressed: busy ? null : onRetry,
            child: const Text('Retry', style: TextStyle(fontSize: 11.5)),
          ),
        ],
      ),
    );
  }
}
