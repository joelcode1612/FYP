import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../core/theme/sitewise_m3.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../widgets/m3_kit.dart';
import 'provider_models.dart';
import 'provider_ui.dart';
import 'provider_workspace_service.dart';

/// Shared performance report for Property Owners and Agents.
///
/// Two kinds of number appear here and they are never mixed:
///
/// * **Measured** — arithmetic over the listings the signed-in account manages.
///   They come from the same authorized scope as the dashboard, so no two
///   screens can disagree.
/// * **Not tracked** — impressions, views and contact clicks. SiteWise logs no
///   event for any of them, so they are listed with the reason. Reporting them
///   as `0` would be indistinguishable from "measured, and it was zero".
///
/// The Enquiries figures the backend still computes are deliberately not
/// rendered: the Enquiries feature was removed from the mobile Provider
/// workspace. The server payload is untouched.
class ProviderPerformanceMobilePage extends ConsumerStatefulWidget {
  const ProviderPerformanceMobilePage({super.key});

  @override
  ConsumerState<ProviderPerformanceMobilePage> createState() =>
      _ProviderPerformanceMobilePageState();
}

class _ProviderPerformanceMobilePageState
    extends ConsumerState<ProviderPerformanceMobilePage> {
  Future<ProviderPerformance>? _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final request = ProviderWorkspaceService.performance();
    if (!mounted) return;
    // A block body is required: an arrow-bodied assignment returns the Future
    // itself, and Flutter's setState rejects that with a red error screen.
    setState(() {
      _future = request;
    });
    await settleRefresh(request);
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      color: SitewiseColors.action,
      onRefresh: _load,
      child: FutureBuilder<ProviderPerformance>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return providerLoadingView();
          }
          if (snapshot.hasError) {
            final error = snapshot.error!;
            return providerContent(
              children: [
                if (isMfaRequired(error))
                  ProviderMfaGate(onReload: _load)
                else
                  ProviderMessage(
                    icon: Icons.insights_outlined,
                    title: 'Your performance report could not be loaded',
                    body: error is AppFailure
                        ? error.userMessage
                        : 'The backend did not answer. Please retry.',
                    onRetry: _load,
                  ),
              ],
            );
          }
          final report = snapshot.data!;
          return providerContent(
            children: [
              const M3ScreenHeading(
                eyebrow: 'Portfolio report',
                title: 'Performance.',
                lead:
                    'Measured from the listings this account is authorized '
                    'to manage.',
              ),
              if (report.total == 0) ...[
                const M3SectionRow(title: 'Overview'),
                ProviderMessage(
                  icon: Icons.insights_outlined,
                  title: 'Nothing to measure yet',
                  body: report.isAgent
                      ? 'No property is assigned to this agent account, so '
                            'there is no portfolio to report on.'
                      : 'No property is registered to this account yet. '
                            'Create a listing to start a portfolio.',
                ),
              ] else ...[
                M3SectionRow(
                  title: 'Your overview',
                  overline: 'MEASURED',
                ),
                Text(
                  report.isAgent
                      ? 'Across the ${report.total} listings assigned to you.'
                      : 'Across the ${report.total} listings you registered.',
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 12,
                    height: 1.5,
                    color: SitewiseM3.muted,
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: M3MetricTile(
                        label: 'Managed properties',
                        value: '${report.managedProperties}',
                        caption: 'In this authorized scope',
                        icon: Icons.storefront_outlined,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: M3MetricTile(
                        label: 'Live listings',
                        value: '${report.published}',
                        caption: 'Published on the public site',
                        icon: Icons.public_rounded,
                        teal: true,
                      ),
                    ),
                  ],
                ),
                M3DataNote(
                  text:
                      'Figures are computed from stored listing records. '
                      'Metrics SiteWise does not capture are listed as '
                      '"Not tracked" below, never as zero.',
                ),
                const M3SectionRow(title: 'Property details'),
                _ManagedProperties(report: report),
                const SizedBox(height: 14),
                _Listings(report: report),
                const SizedBox(height: 14),
                _Engagement(report: report),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _ManagedProperties extends StatelessWidget {
  const _ManagedProperties({required this.report});

  final ProviderPerformance report;

  @override
  Widget build(BuildContext context) => ProviderCard(
    title: 'Rent and floor area',
    child: Row(
      children: [
        Expanded(
          child: _Stat(
            label: 'Median rent',
            value: report.medianRentDisplay,
            note: report.medianRent == null
                ? 'No rental recorded'
                : 'Across this portfolio',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _Stat(
            label: 'Average floor area',
            value: report.averageSizeDisplay,
            note: report.averageSizeSqft == null
                ? 'No floor area recorded'
                : 'Across this portfolio',
          ),
        ),
      ],
    ),
  );
}

class _Listings extends StatelessWidget {
  const _Listings({required this.report});

  final ProviderPerformance report;

  /// The server's own `verification_status` vocabulary, in lifecycle order.
  static const List<(String, String)> _states = [
    ('draft', 'Draft'),
    ('pending', 'Pending verification'),
    ('under_review', 'Under review'),
    ('approved', 'Approved'),
    ('rejected', 'Rejected'),
  ];

  @override
  Widget build(BuildContext context) {
    final rows = [
      for (final (wire, label) in _states)
        if (report.stateCount(wire) > 0) (label, report.stateCount(wire)),
      if (report.otherState > 0) ('Unrecognised state', report.otherState),
    ];
    return ProviderCard(
      title: 'Listings by review state',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (label, count) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 9),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 12.5,
                        color: SitewiseM3.ink,
                      ),
                    ),
                  ),
                  Text(
                    '$count',
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: SitewiseM3.ink,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 3),
          Text(
            'Publication is separate from approval: '
            '${report.published} of ${report.total} listings are live on the '
            'public site.',
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 11,
              height: 1.5,
              color: SitewiseM3.muted,
            ),
          ),
        ],
      ),
    );
  }
}

/// The engagement funnel. Every stage is declared NOT CAPTURED rather than
/// zero, because a zero would read as a measurement.
class _Engagement extends StatelessWidget {
  const _Engagement({required this.report});

  final ProviderPerformance report;

  @override
  Widget build(BuildContext context) => ProviderCard(
    title: 'Engagement',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Not tracked',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: SitewiseM3.amber,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: SitewiseM3.amberWash,
                borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
              ),
              child: const Text(
                'No events stored',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: SitewiseM3.amber,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 9),
        Text(
          report.engagementReason,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 11.5,
            height: 1.5,
            color: SitewiseM3.muted,
          ),
        ),
        const SizedBox(height: 12),
        for (final metric in report.untrackedMetrics)
          Padding(
            padding: const EdgeInsets.only(bottom: 11),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(
                  width: 30,
                  child: Text(
                    '—',
                    style: TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 13,
                      color: SitewiseM3.muted,
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        metric.label,
                        style: const TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: SitewiseM3.ink,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        metric.reason,
                        style: const TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 11,
                          height: 1.45,
                          color: SitewiseM3.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, required this.note});

  final String label;
  final String value;
  final String note;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
    decoration: BoxDecoration(
      color: providerSoft,
      borderRadius: BorderRadius.circular(15),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: SitewiseM3.ink,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: SitewiseM3.ink,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          note,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 10,
            height: 1.35,
            color: SitewiseM3.muted,
          ),
        ),
      ],
    ),
  );
}
