import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_m3.dart';

/// Dedicated destination for deep links and bookmarks whose route no longer
/// exists. Previously unknown paths silently resolved to the entrepreneur
/// dashboard, so a broken link looked like a successful navigation and the
/// user lost all context about what had failed.
///
/// Shows the attempted route (when one was supplied) and offers the two honest
/// exits: back to the previous screen, or home.
class NotFoundMobilePage extends StatelessWidget {
  /// The route that could not be resolved — displayed for clarity, never
  /// trusted for navigation.
  final String? attemptedRoute;

  const NotFoundMobilePage({super.key, this.attemptedRoute});

  @override
  Widget build(BuildContext context) {
    final canGoBack = Navigator.of(context).canPop();
    return Scaffold(
      backgroundColor: SitewiseM3.paper,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: const BoxDecoration(
                    color: SitewiseM3.metricBlueBg,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.search_off_rounded,
                    size: 36,
                    color: SitewiseM3.primary,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Page not found',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: SitewiseM3.ink,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  'The link you opened no longer exists or is unavailable.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: SitewiseM3.muted,
                        height: 1.4,
                      ),
                ),
                if (attemptedRoute != null && attemptedRoute!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Requested: $attemptedRoute',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: SitewiseM3.stone,
                          fontFamily: 'monospace',
                        ),
                  ),
                ],
                const SizedBox(height: 24),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (canGoBack)
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: SitewiseM3.primary,
                          side: const BorderSide(color: SitewiseM3.line),
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed: () => Navigator.of(context).maybePop(),
                        child: const Text('Go back'),
                      ),
                    if (canGoBack) const SizedBox(width: 12),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: SitewiseM3.primary,
                        minimumSize: const Size(48, 48),
                      ),
                      onPressed: () => Navigator.of(context)
                          .popUntil((route) => route.isFirst),
                      child: const Text('Go home'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
