import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';

/// Small KPI card for dashboards.

class SitewiseStatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final String? delta;

  const SitewiseStatCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.delta,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: SitewiseColors.geoWash,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, size: 20, color: SitewiseColors.action),
                ),
                const Spacer(),
                if (delta != null)
                  Text(
                    delta!,
                    style: const TextStyle(
                      color: SitewiseColors.success,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              value,
              style: Theme.of(
                context,
              ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
