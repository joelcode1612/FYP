import 'package:flutter/material.dart';

import 'package:fyp/core/theme/sitewise_m3.dart';
import 'package:fyp/core/theme/sitewise_theme.dart';
import 'package:fyp/features/property_management/domain/entities/provider_models.dart';
import 'package:fyp/shared/presentation/components/provider_ui.dart';

// SITEWISE_OWNER_PERFORMANCE_COMPACT_V1
// Presentation-only. Values come from the existing ProviderPerformance report.
// Agent performance remains on the original report view above.
class OwnerPerformanceCompact extends StatelessWidget {
  const OwnerPerformanceCompact({super.key, required this.report});

  final ProviderPerformance report;

  void _openSheet(BuildContext context, {required bool engagement}) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: SitewiseM3.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _OwnerPerformanceDetailsSheet(
        report: report,
        engagement: engagement,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final inReview = report.stateCount('pending') +
        report.stateCount('under_review');
    final draft = report.stateCount('draft');
    final approved = report.stateCount('approved');
    final rejected = report.stateCount('rejected');
    final publicationShare = report.total == 0
        ? 0.0
        : (report.published / report.total).clamp(0.0, 1.0).toDouble();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'PROPERTY OWNER',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.1,
            color: SitewiseColors.action,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Performance',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 26,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.6,
            color: SitewiseM3.ink,
          ),
        ),
        const SizedBox(height: 5),
        const Text(
          'Your property portfolio at a glance.',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 15,
            height: 1.5,
            color: SitewiseM3.muted,
          ),
        ),
        const SizedBox(height: 18),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: SitewiseM3.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: SitewiseM3.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: const Color(0xFFEAF1FF),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.apartment_rounded,
                      size: 24,
                      color: SitewiseColors.action,
                    ),
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${report.total} ${report.total == 1 ? 'property' : 'properties'}',
                          style: const TextStyle(
                            fontFamily: kFontFamily,
                            fontSize: 23,
                            fontWeight: FontWeight.w800,
                            color: SitewiseM3.ink,
                          ),
                        ),
                        const Text(
                          'In your portfolio',
                          style: TextStyle(
                            fontFamily: kFontFamily,
                            fontSize: 13,
                            color: SitewiseM3.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: SitewiseM3.greenWash,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '${report.published} live',
                      style: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: SitewiseM3.green,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Published listings',
                      style: TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: SitewiseM3.ink,
                      ),
                    ),
                  ),
                  Text(
                    '${report.published} of ${report.total}',
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: SitewiseM3.muted,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 9),
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  value: publicationShare,
                  minHeight: 7,
                  color: SitewiseColors.action,
                  backgroundColor: const Color(0xFFE8EDF5),
                  semanticsLabel: 'Published listings: ${report.published} of ${report.total}',
                ),
              ),
            ],
          ),
        ),
        if (report.total == 0) ...[
          const SizedBox(height: 16),
          const ProviderMessage(
            icon: Icons.storefront_outlined,
            title: 'No properties yet',
            body: 'Add a property to see your listing progress here.',
          ),
        ] else ...[
          const SizedBox(height: 22),
          const _OwnerPerformanceSectionTitle('Review status'),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _OwnerPerformanceStatusTile(
                  count: draft,
                  label: 'Draft',
                  color: const Color(0xFF52657E),
                  wash: const Color(0xFFF2F5F9),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _OwnerPerformanceStatusTile(
                  count: inReview,
                  label: 'In review',
                  color: SitewiseM3.amber,
                  wash: SitewiseM3.amberWash,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _OwnerPerformanceStatusTile(
                  count: approved,
                  label: 'Approved',
                  color: SitewiseM3.green,
                  wash: SitewiseM3.greenWash,
                ),
              ),
            ],
          ),
          if (rejected > 0) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
              decoration: BoxDecoration(
                color: SitewiseColors.dangerWash,
                borderRadius: BorderRadius.circular(13),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.info_outline_rounded,
                    color: SitewiseColors.danger,
                    size: 20,
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      '$rejected ${rejected == 1 ? 'listing needs' : 'listings need'} attention',
                      style: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: SitewiseColors.danger,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
        const SizedBox(height: 22),
        const _OwnerPerformanceSectionTitle('More details'),
        const SizedBox(height: 10),
        Material(
          color: SitewiseM3.surface,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: SitewiseM3.line),
          ),
          child: Column(
            children: [
              _OwnerPerformanceActionRow(
                icon: Icons.bar_chart_rounded,
                title: 'Portfolio details',
                subtitle: 'Rental, size and all listing statuses',
                onTap: () => _openSheet(context, engagement: false),
              ),
              const Divider(height: 1, color: SitewiseM3.line),
              _OwnerPerformanceActionRow(
                icon: Icons.visibility_outlined,
                title: 'Activity insights',
                subtitle: report.engagementTracked
                    ? 'View available engagement information'
                    : 'Not tracked yet',
                onTap: () => _openSheet(context, engagement: true),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        const Text(
          'Based on your recorded listings. Approval and publication are separate steps.',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 12,
            height: 1.5,
            color: SitewiseM3.muted,
          ),
        ),
      ],
    );
  }
}

class _OwnerPerformanceSectionTitle extends StatelessWidget {
  const _OwnerPerformanceSectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Text(
    label,
    style: const TextStyle(
      fontFamily: kFontFamily,
      fontSize: 17,
      fontWeight: FontWeight.w800,
      color: SitewiseM3.ink,
    ),
  );
}

class _OwnerPerformanceStatusTile extends StatelessWidget {
  const _OwnerPerformanceStatusTile({
    required this.count,
    required this.label,
    required this.color,
    required this.wash,
  });

  final int count;
  final String label;
  final Color color;
  final Color wash;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minHeight: 94),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 13),
    decoration: BoxDecoration(
      color: SitewiseM3.surface,
      borderRadius: BorderRadius.circular(15),
      border: Border.all(color: SitewiseM3.line),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          decoration: BoxDecoration(
            color: wash,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '$count',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ),
        const SizedBox(height: 7),
        Text(
          label,
          maxLines: 2,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: SitewiseM3.ink,
          ),
        ),
      ],
    ),
  );
}

class _OwnerPerformanceActionRow extends StatelessWidget {
  const _OwnerPerformanceActionRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 70),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFFEAF1FF),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, size: 20, color: SitewiseColors.action),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: SitewiseM3.ink,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 13,
                      height: 1.35,
                      color: SitewiseM3.muted,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: SitewiseM3.muted),
          ],
        ),
      ),
    ),
  );
}

class _OwnerPerformanceDetailsSheet extends StatelessWidget {
  const _OwnerPerformanceDetailsSheet({
    required this.report,
    required this.engagement,
  });

  final ProviderPerformance report;
  final bool engagement;

  static const _states = <(String, String)>[
    ('draft', 'Draft'),
    ('pending', 'Pending verification'),
    ('under_review', 'Under review'),
    ('approved', 'Approved'),
    ('rejected', 'Rejected'),
  ];

  Widget _detailRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 14,
              color: SitewiseM3.muted,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: SitewiseM3.ink,
            ),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final items = engagement
        ? <Widget>[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(
                color: SitewiseM3.amberWash,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    report.engagementTracked
                        ? 'Available engagement information'
                        : 'Not tracked',
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: SitewiseM3.ink,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    report.engagementReason,
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 14,
                      height: 1.5,
                      color: SitewiseM3.ink,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            for (final metric in report.untrackedMetrics) ...[
              Text(
                metric.label,
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: SitewiseM3.ink,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                metric.reason,
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 14,
                  height: 1.5,
                  color: SitewiseM3.muted,
                ),
              ),
              const Divider(height: 24, color: SitewiseM3.line),
            ],
          ]
        : <Widget>[
            _detailRow('Total properties', '${report.total}'),
            _detailRow('Live listings', '${report.published}'),
            _detailRow('Median monthly rent', report.medianRentDisplay),
            _detailRow('Average floor area', report.averageSizeDisplay),
            const Divider(height: 26, color: SitewiseM3.line),
            const Text(
              'Listing review status',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: SitewiseM3.ink,
              ),
            ),
            const SizedBox(height: 6),
            for (final (wire, label) in _states)
              _detailRow(label, '${report.stateCount(wire)}'),
            if (report.otherState > 0)
              _detailRow('Other status', '${report.otherState}'),
            const SizedBox(height: 12),
            const Text(
              'Approval does not automatically publish a property. '
              'Figures are calculated from your stored listing records.',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 13,
                height: 1.5,
                color: SitewiseM3.muted,
              ),
            ),
          ];

    return FractionallySizedBox(
      heightFactor: 0.76,
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFC7D0DF),
                borderRadius: BorderRadius.circular(5),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      engagement ? 'Activity insights' : 'Portfolio details',
                      style: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: SitewiseM3.ink,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: SitewiseM3.line),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                children: items,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
// END SITEWISE_OWNER_PERFORMANCE_COMPACT_V1
