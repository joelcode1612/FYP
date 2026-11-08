import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../../application/services/service_locator.dart';
import '../../../shared/widgets/sitewise_button.dart';
import '../../../shared/widgets/sitewise_evidence_score.dart';
import '../../../shared/widgets/sitewise_factor_row.dart';
import '../../../shared/widgets/sitewise_loading_state.dart';
import '../../shell/mobile_app_shell.dart';

/// Mobile evaluation report: full-width document card.

class EntrepreneurReportMobilePage extends StatelessWidget {
  final String propertyId;
  const EntrepreneurReportMobilePage({super.key, required this.propertyId});

  @override
  Widget build(BuildContext context) {
    return MobileAppShell(
      title: 'Evaluation report',
      currentRoute: '/entrepreneur/saved',
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: FutureBuilder<CommercialProperty?>(
          future: ServiceLocator.properties.detail(propertyId),
          builder: (ctx, propSnap) {
            if (!propSnap.hasData || propSnap.data == null) {
              return const SitewiseLoadingState(message: 'Generating report…');
            }
            final p = propSnap.data!;
            return FutureBuilder<LocationAnalysis>(
              future: ServiceLocator.recommendations.analysis(propertyId),
              builder: (c2, aSnap) {
                if (!aSnap.hasData) {
                  return const SitewiseLoadingState(
                    message: 'Generating report…',
                  );
                }
                return _reportCard(context, p, aSnap.data!);
              },
            );
          },
        ),
      ),
    );
  }

  Widget _reportCard(
    BuildContext context,
    CommercialProperty p,
    LocationAnalysis a,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Site evaluation — ${p.title}',
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
            ),
            Text(
              '${p.address}, ${p.city} · RM${p.rentalRm.toStringAsFixed(0)} · ${p.sizeSqft.toStringAsFixed(0)} sq ft',
            ),
            const Divider(height: 32),
            SitewiseEvidenceScore(score: a.suitabilityScore),
            const Divider(height: 24),
            Text(a.demandSummary),
            const Divider(height: 24),
            for (final f in a.factors) SitewiseFactorRow(factor: f),
            const Divider(height: 24),
            Text(
              'Verdict: ${a.verdict}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            SitewiseButton(
              label: 'Back to property',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}
