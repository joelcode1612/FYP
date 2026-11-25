import 'package:flutter/material.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:fyp/core/theme/sitewise_theme.dart';

/// Human wording for a measurement state.
///
/// The distinction that matters on screen is "this number was measured" versus
/// "there is no number". A measured value that the active model does not
/// consume is still a measurement, so it is labelled as measured with the
/// model caveat attached rather than hidden or blanked.
String sitewiseMeasurementStateLabel(String state) {
  switch (state) {
    case 'validated':
      return 'Measured';
    case 'calculated_unvalidated':
      return 'Measured · not a model input';
    case 'unavailable':
      return 'Not measured';
    case 'stale':
      return 'Out of date — recalculate';
    case 'not_calculated':
      return 'Not calculated yet';
    case 'failed':
      return 'Calculation failed';
    case 'pending':
      return 'Queued';
    case 'running':
      return 'Calculating…';
    default:
      return 'Not measured';
  }
}

/// The measured surroundings of one property, grouped by category.
///
/// Every row keeps its own state: a category that could not be measured is
/// shown with its reason and never suppresses the categories that succeeded,
/// and no unavailable value is ever rendered as a zero.
class SitewiseLocationMeasurements extends StatelessWidget {
  final LocationAnalysis analysis;

  /// Groups expanded on first paint. Population is the figure most people look
  /// for first, so it starts open; the rest stay collapsed to keep the page
  /// scannable.
  final Set<String> initiallyExpanded;

  const SitewiseLocationMeasurements({
    super.key,
    required this.analysis,
    this.initiallyExpanded = const {'population'},
  });

  @override
  Widget build(BuildContext context) {
    if (!analysis.hasMeasurementReport) return const SizedBox.shrink();

    final measured = analysis.measuredValueCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Measured surroundings',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: SitewiseColors.ink,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: SitewiseColors.geoWash,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '$measured measured',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: SitewiseColors.accent,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          'Calculated from this property\'s coordinates. A figure that could '
          'not be measured is shown as not measured — it is never replaced '
          'with zero.',
          style: TextStyle(
            fontSize: 11.5,
            height: 1.45,
            color: SitewiseColors.muted,
          ),
        ),
        const SizedBox(height: 8),
        if (measured == 0)
          const Text(
            'No measurements exist for this location yet. Run location '
            'analysis to calculate them.',
            style: TextStyle(
              fontSize: 12,
              height: 1.4,
              color: SitewiseColors.muted,
            ),
          )
        else
          for (final group in analysis.measurementGroups)
            _GroupTile(
              group: group,
              initiallyExpanded: initiallyExpanded.contains(group.key),
            ),
      ],
    );
  }
}

class _GroupTile extends StatelessWidget {
  final LocationMeasurementGroup group;
  final bool initiallyExpanded;

  const _GroupTile({required this.group, required this.initiallyExpanded});

  @override
  Widget build(BuildContext context) {
    final unavailable = group.total - group.measuredCount;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        title: Text(
          group.title,
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: SitewiseColors.ink,
          ),
        ),
        subtitle: Text(
          group.available
              ? '${group.measuredCount} of ${group.total} measured'
                    '${unavailable > 0 ? ' · $unavailable not measured' : ''}'
              : sitewiseMeasurementStateLabel(group.status),
          style: const TextStyle(fontSize: 11, color: SitewiseColors.muted),
        ),
        children: [
          if (!group.available && group.reason != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                group.reason!,
                style: const TextStyle(
                  fontSize: 11,
                  height: 1.4,
                  color: SitewiseColors.muted,
                ),
              ),
            ),
          for (final row in group.rows) _MeasurementRow(row: row),
        ],
      ),
    );
  }
}

class _MeasurementRow extends StatelessWidget {
  final LocationMeasurement row;

  const _MeasurementRow({required this.row});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.label,
                  style: TextStyle(
                    fontSize: 12,
                    color: row.measured
                        ? SitewiseColors.ink
                        : SitewiseColors.muted,
                  ),
                ),
                if (row.measured && row.method != null && row.method!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      row.method!,
                      style: const TextStyle(
                        fontSize: 10.5,
                        height: 1.35,
                        color: SitewiseColors.muted,
                      ),
                    ),
                  ),
                if (row.informationalOnly)
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Text(
                      'Not used by the recommendation model',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: SitewiseColors.muted,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            row.measured ? row.display : sitewiseMeasurementStateLabel(row.state),
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 12,
              fontWeight: row.measured ? FontWeight.w700 : FontWeight.w500,
              color: row.measured ? SitewiseColors.ink : SitewiseColors.muted,
            ),
          ),
        ],
      ),
    );
  }
}
