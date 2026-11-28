import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:fyp/core/theme/sitewise_m3.dart';
import 'package:fyp/core/theme/sitewise_theme.dart';
import 'package:fyp/shared/presentation/components/m3_kit.dart';
import 'package:fyp/features/property_management/domain/entities/provider_models.dart';
import 'package:fyp/shared/presentation/components/provider_ui.dart';
import 'package:fyp/features/property_management/data/provider_workspace_service.dart';
import 'package:fyp/features/dashboard/presentation/widgets/owner_performance_compact.dart';

/// Portfolio performance for Property Owners and Agents.
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
                        : 'Please try again.',
                    onRetry: _load,
                  ),
              ],
            );
          }
          final report = snapshot.data!;
          if (!report.isAgent) {
            return providerContent(
              children: [OwnerPerformanceCompact(report: report)],
            );
          }
          return providerContent(
            children: [
              const M3ScreenHeading(
                eyebrow: 'Portfolio report',
                title: 'Performance.',
                lead:
                    'Rent, floor area and progress for your assigned properties.',
              ),
              if (report.total == 0) ...[
                const M3SectionRow(title: 'Overview'),
                ProviderMessage(
                  icon: Icons.insights_outlined,
                  title: 'Nothing to measure yet',
                  body: 'Assigned properties will appear here.',
                ),
              ] else ...[
                const M3SectionRow(title: 'Your overview'),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: M3MetricTile(
                        label: 'Managed properties',
                        value: '${report.managedProperties}',
                        caption: 'Assigned to you',
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
                const M3SectionRow(title: 'Property details'),
                _ManagedProperties(report: report),
                const SizedBox(height: 14),
                _ListingStatusChart(report: report),
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
            label: 'Median monthly rent',
            value: report.medianRentDisplay,
            note: report.medianRent == null
                ? 'No rental recorded'
                : 'Properties with a recorded value',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _Stat(
            label: 'Average built-up area',
            value: report.averageSizeDisplay,
            note: report.averageSizeSqft == null
                ? 'No floor area recorded'
                : 'Properties with a recorded value',
          ),
        ),
      ],
    ),
  );
}

class _ListingStatusChart extends StatelessWidget {
  const _ListingStatusChart({required this.report});

  final ProviderPerformance report;

  static const _inspectionLabels = {
    'requested': 'Awaiting acceptance',
    'accepted': 'Accepted',
    'checklist_saved': 'Checklist saved',
    'needs_correction': 'Needs correction',
    'submitted': 'Submitted to Admin',
    'declined': 'Declined',
  };

  @override
  Widget build(BuildContext context) {
    final inspection = report.byInspection;
    final other = inspection.entries
        .where((entry) => !_inspectionLabels.containsKey(entry.key))
        .fold<int>(0, (total, entry) => total + entry.value);
    return ProviderCard(
      title: 'Inspection and publication',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _ChartHeading('Inspection'),
          if (inspection.isEmpty)
            const Text('Inspection status unavailable.')
          else ...[
            for (final entry in _inspectionLabels.entries)
              if ((inspection[entry.key] ?? 0) > 0)
                _bar(entry.value, inspection[entry.key]!, SitewiseM3.primary),
            if (other > 0) _bar('Other', other, SitewiseM3.primary),
          ],
          const SizedBox(height: 8),
          const _ChartHeading('Publication'),
          _bar('Published', report.published, SitewiseM3.green),
          _bar(
            'Unpublished',
            report.total - report.published,
            SitewiseM3.muted,
          ),
        ],
      ),
    );
  }

  Widget _bar(String label, int count, Color color) => Padding(
    padding: const EdgeInsets.only(bottom: 9),
    child: Column(
      children: [
        Row(
          children: [
            Expanded(child: Text(label)),
            const SizedBox(width: 8),
            Text('$count', style: const TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
        const SizedBox(height: 4),
        ExcludeSemantics(
          child: LinearProgressIndicator(
            value: (count / report.total).clamp(0.0, 1.0),
            color: color,
            backgroundColor: SitewiseM3.line,
            borderRadius: BorderRadius.circular(3),
            minHeight: 6,
          ),
        ),
      ],
    ),
  );
}

class _ChartHeading extends StatelessWidget {
  const _ChartHeading(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      label,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
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
