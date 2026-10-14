import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/sitewise_theme.dart';
import 'sitewise_progress_indicator.dart';

/// One explainable location factor row (name, score bar, evidence).

class SitewiseFactorRow extends StatelessWidget {
  final LocationFactor factor;

  const SitewiseFactorRow({super.key, required this.factor});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  factor.name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: SitewiseColors.geoWash,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  factor.impact,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: SitewiseColors.accent,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SitewiseProgressIndicator(value: factor.score, compact: true),
          const SizedBox(height: 4),
          Text(factor.evidence, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
