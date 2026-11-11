import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../application/services/service_locator.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../../shared/widgets/sitewise_button.dart';
import '../../../shared/widgets/sitewise_evidence_score.dart';
import '../../../shared/widgets/sitewise_factor_row.dart';
import '../../shell/mobile_app_shell.dart';
import '../../widgets/async_section.dart';

/// Mobile evaluation report: full-width document card.
///
/// What used to be broken here:
///
///  * two nested `FutureBuilder`s were created *inside* `build()`, so the
///    property read and the analysis read were re-issued on every rebuild
///    (theme change, keyboard inset, the shell rebuilding) and the spinner
///    restarted each time;
///  * both used `!hasData`, which also matches the **error** case — a failed
///    request rendered a permanent "Generating report…" spinner with no way
///    out. [AsyncSection] owns the request and shows a real error with Retry;
///  * the analysis came from `DemoData.analysisFor`, which returns the *first
///    demo property's* figures for any id it does not recognise, so a live
///    listing produced a fabricated report. `ServiceLocator.analysisRepo` now
///    points at the API-backed analysis in a live build;
///  * the page reported `currentRoute: '/entrepreneur/saved'`, which lit the
///    wrong bottom-nav destination.
///
/// The report is built from the property row the user is looking at. Anything
/// the dataset does not record is labelled as not recorded — never invented.
class EntrepreneurReportMobilePage extends ConsumerStatefulWidget {
  final String propertyId;
  const EntrepreneurReportMobilePage({super.key, required this.propertyId});

  @override
  ConsumerState<EntrepreneurReportMobilePage> createState() =>
      _EntrepreneurReportMobilePageState();
}

class _EntrepreneurReportMobilePageState
    extends ConsumerState<EntrepreneurReportMobilePage> {
  final GlobalKey<AsyncSectionState<_ReportData>> _reportKey =
      GlobalKey<AsyncSectionState<_ReportData>>();

  Future<void> _refresh() =>
      _reportKey.currentState?.refresh() ?? Future<void>.value();

  /// Resolves the listing against the same dataset the property detail page
  /// used: the live Explore repository first (numeric `fyp.rental_properties`
  /// ids), then the shared property repository (catalogue refs, demo builds).
  /// A 404 means "not published" and becomes the honest unavailable state.
  Future<CommercialProperty?> _resolveProperty() async {
    final explore = ref.read(exploreRepositoryProvider);
    if (explore != null) {
      try {
        final detail = await explore.detail(widget.propertyId);
        return detail.property;
      } on NotFoundShape {
        return null;
      }
    }
    return ServiceLocator.properties.detail(widget.propertyId);
  }

  /// One request for the whole document, so pull-to-refresh re-reads both the
  /// property and its analysis from their authoritative sources.
  ///
  /// An analysis failure is reported *inside* the report rather than replacing
  /// it: the property facts are still valid and the user can retry the
  /// analysis without losing the document.
  Future<_ReportData> _load() async {
    final property = await _resolveProperty();
    if (property == null) {
      throw const NotFoundFailure(
        'This property is not published in the catalogue.',
      );
    }
    LocationAnalysis? analysis;
    String? analysisError;
    try {
      analysis = await ServiceLocator.recommendations.analysis(widget.propertyId);
    } on Object catch (error) {
      analysisError = readableFailure(
        error,
        fallback: 'Location analysis could not be loaded for this property.',
      );
    }
    return _ReportData(
      property: property,
      analysis: analysis,
      analysisError: analysisError,
    );
  }

  @override
  Widget build(BuildContext context) {
    return MobileAppShell(
      title: 'Evaluation report',
      currentRoute: '/entrepreneur/report',
      actions: [
        IconButton(
          tooltip: 'Refresh report',
          icon: const Icon(Icons.refresh_rounded),
          onPressed: _refresh,
        ),
      ],
      body: RefreshIndicator(
        color: SitewiseColors.action,
        onRefresh: _refresh,
        child: AsyncSection<_ReportData>(
          key: _reportKey,
          load: _load,
          errorTitle: 'The evaluation report could not be generated',
          builder: (context, data) => ListView(
            padding: const EdgeInsets.all(16),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [_reportCard(context, data)],
          ),
        ),
      ),
    );
  }

  Widget _reportCard(BuildContext context, _ReportData data) {
    final p = data.property;
    final a = data.analysis;
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
            const SizedBox(height: 4),
            Text(
              '${p.address}, ${p.city} · '
              '${p.rentalRm > 0 ? p.rentalDisplay : 'Rent on request'} · '
              '${p.sizeSqft > 0 ? '${p.sizeSqft.toStringAsFixed(0)} sq ft' : 'Size not listed'}',
              style: const TextStyle(fontSize: 12.5, color: SitewiseColors.muted),
            ),
            const Divider(height: 32),
            if (a != null) ...[
              SitewiseEvidenceScore(score: a.suitabilityScore),
              const SizedBox(height: 4),
              const Text(
                '(research index, not a success probability).',
                style: TextStyle(fontSize: 11, color: SitewiseColors.muted),
              ),
              const Divider(height: 24),
              Text(a.demandSummary),
              if (a.socioeconomicSummary.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  a.socioeconomicSummary,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: SitewiseColors.muted,
                  ),
                ),
              ],
              const Divider(height: 24),
              if (a.factors.isEmpty)
                const Text(
                  'No research factors are recorded for this property yet.',
                  style: TextStyle(fontSize: 12.5, color: SitewiseColors.muted),
                )
              else
                for (final f in a.factors) SitewiseFactorRow(factor: f),
              const Divider(height: 24),
              Text(
                'Verdict: ${a.verdict}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ] else
              _analysisUnavailable(data),
            const Divider(height: 32),
            _recordedFacts(p),
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

  /// Shown when the analysis could not be read. The failure stays visible with
  /// a Retry that re-runs the real request — it never degrades into an empty
  /// "no analysis" success state.
  Widget _analysisUnavailable(_ReportData data) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: SitewiseColors.danger.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.report_gmailerrorred_rounded,
            size: 18,
            color: SitewiseColors.danger,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              data.analysisError ??
                  'Location analysis is not available for this listing.',
              style: const TextStyle(
                fontSize: 12,
                height: 1.4,
                color: SitewiseColors.danger,
              ),
            ),
          ),
          TextButton(
            onPressed: _refresh,
            child: const Text('Retry', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  /// Only what the listing row actually records. A null field means the
  /// dataset has no value — it is listed as "not recorded" instead of a zero.
  Widget _recordedFacts(CommercialProperty p) {
    final rows = <String>[
      if (p.hasSuitabilityScore)
        'Research suitability index: ${p.suitabilityScore.toStringAsFixed(0)}/100'
      else
        'Research suitability index: not scored for this listing',
      if (p.competitorCount500m != null)
        'F&B competitors within 500 m: ${p.competitorCount500m}'
      else
        'F&B competitors within 500 m: not recorded',
      if (p.population1km != null)
        'Population within 1 km: ${p.population1km!.toStringAsFixed(0)}'
      else
        'Population within 1 km: not recorded',
      if (p.accessibilityScore != null)
        'Accessibility score: ${p.accessibilityScore!.toStringAsFixed(0)}/100'
      else
        'Accessibility score: not recorded',
      'Verification: '
          '${p.verification == VerificationStatus.verified ? 'verified' : 'not verified'}',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Recorded for this listing',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w800,
            color: SitewiseColors.ink,
          ),
        ),
        const SizedBox(height: 8),
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '· $row',
              style: const TextStyle(
                fontSize: 12,
                height: 1.4,
                color: SitewiseColors.muted,
              ),
            ),
          ),
      ],
    );
  }
}

/// Everything the document renders, resolved by one request.
class _ReportData {
  const _ReportData({
    required this.property,
    required this.analysis,
    required this.analysisError,
  });

  final CommercialProperty property;
  final LocationAnalysis? analysis;
  final String? analysisError;
}
