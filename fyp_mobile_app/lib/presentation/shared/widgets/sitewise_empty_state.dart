import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';

class SitewiseEmptyState extends StatelessWidget {
  final String title;
  final String message;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  const SitewiseEmptyState({
    super.key,
    required this.title,
    required this.message,
    this.icon = Icons.inbox_outlined,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      // Scrollable so a tall empty state (icon + title + message + action) can
      // never overflow a short viewport — the previous fixed Column overflowed
      // by ~113px on a 390x844 surface and pushed the action out of reach.
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: const BoxDecoration(
                  color: SitewiseColors.geoWash,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 40, color: SitewiseColors.action),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              ),
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (actionLabel != null) ...[
                const SizedBox(height: 16),
                ElevatedButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
