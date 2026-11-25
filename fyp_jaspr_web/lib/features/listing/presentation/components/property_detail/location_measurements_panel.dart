import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'package:shared_logic/shared_logic.dart';

/// "What has actually been measured here?" — the full measured surroundings of
/// one property, grouped by category.
///
/// The list is deliberately exhaustive rather than curated: an entrepreneur
/// who is told a location scores 72 deserves to see the 64 numbers behind it,
/// including the ones that are missing. Three rules drive the markup:
///
/// * A measurement that could not be calculated is shown as *not measured*
///   with the backend's own reason. It is never rendered as `0`, because a
///   zero is a measurement and "we could not measure this" is not.
/// * A measurement that was calculated but is not an input to the active model
///   is still shown as a real measurement, with the caveat attached. Hiding it
///   would make the page lie about how much is known; presenting it as a score
///   input would make the page lie about the score.
/// * Groups collapse with native `<details>`, so the page stays scannable and
///   the whole list works without JavaScript and from the keyboard.
///
/// Nothing here computes anything. Every figure, unit and state comes from the
/// analysis payload, so a rendering change can never change a number.
class LocationMeasurementsPanel extends StatelessComponent {
  /// The analysis whose measurement block is rendered.
  final LocationAnalysis analysis;

  /// Groups open on first paint. Population is the figure most people look for
  /// first; the rest stay collapsed so a 64-row list does not push the rest of
  /// the page away.
  final Set<String> initiallyExpanded;

  const LocationMeasurementsPanel({
    super.key,
    required this.analysis,
    this.initiallyExpanded = const {'population'},
  });

  /// Human wording for a measurement state.
  ///
  /// The distinction that matters on screen is "this number was measured"
  /// versus "there is no number". The pending/running states are worded as
  /// work in progress rather than as failures, because that is what they are.
  static String stateLabel(String state) {
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

  int get _measuredTotal => analysis.measuredValueCount;

  @override
  Component build(BuildContext context) {
    // No measurement block at all means the backend had nothing to say about
    // this location (for example a catalogue reference with no property
    // record). Rendering 64 "not measured" rows would invent a problem.
    if (!analysis.hasMeasurementReport) return Component.fragment(const []);

    final measured = _measuredTotal;
    return section(classes: 'sw-lm', [
      div(classes: 'sw-lm__head', [
        div([
          span(classes: 'sw-pd__eyebrow', [
            Component.text('Measured surroundings'),
          ]),
          h3([Component.text('What has been measured here')]),
          p(classes: 'sw-lm__lede', [
            Component.text(
              'Every figure below was calculated from this property\'s '
              'coordinates. A figure that could not be measured is shown as '
              'not measured — it is never replaced with zero.',
            ),
          ]),
        ]),
        span(classes: 'sw-lm__count', [
          Component.text('$measured measured'),
        ]),
      ]),
      if (measured == 0)
        p(classes: 'sw-lm__empty', [
          Component.text(
            'No measurements exist for this location yet. Run the location '
            'analysis to calculate them.',
          ),
        ])
      else
        div(classes: 'sw-lm__groups', [
          for (final group in analysis.measurementGroups) _groupBlock(group),
        ]),
    ]);
  }

  /// One collapsible category.
  ///
  /// The badge carries the count so the group can be judged without opening
  /// it; the reason is only shown when the group produced nothing, because a
  /// partially measured group explains itself row by row.
  Component _groupBlock(LocationMeasurementGroup group) {
    final unavailable = group.total - group.measuredCount;
    final badgeText = group.available
        ? '${group.measuredCount} of ${group.total}'
            '${unavailable > 0 ? ' · $unavailable not measured' : ''}'
        : stateLabel(group.status);
    return details(
      classes: 'sw-lm__group',
      open: initiallyExpanded.contains(group.key),
      [
        summary(classes: 'sw-lm__summary', [
          div([
            strong([Component.text(group.title)]),
            small([
              Component.text(
                group.available
                    ? '${group.measuredCount} of ${group.total} measured'
                        '${unavailable > 0 ? ' · $unavailable not measured' : ''}'
                    : stateLabel(group.status),
              ),
            ]),
          ]),
          span(classes: 'sw-lm__badge', [Component.text(badgeText)]),
        ]),
        div(classes: 'sw-lm__body', [
          if (!group.available && group.reason != null)
            p(classes: 'sw-lm__reason', [Component.text(group.reason!)]),
          for (final row in group.rows) _row(row),
        ]),
      ],
    );
  }

  /// One measurement: label, method, caveat, value.
  ///
  /// The method line is only shown for a measured value — it explains where
  /// the number came from, and there is nothing to explain when there is no
  /// number.
  Component _row(LocationMeasurement row) {
    final method = row.method;
    return div(classes: 'sw-lm__row', [
      div(classes: 'sw-lm__label', [
        span([Component.text(row.label)]),
        if (row.measured && method != null && method.isNotEmpty)
          small([Component.text(method)]),
        if (row.informationalOnly)
          small(classes: 'sw-lm__caveat', [
            Component.text('Not used by the recommendation model'),
          ]),
      ]),
      span(
        classes: row.measured ? 'sw-lm__value' : 'sw-lm__value sw-lm__value--empty',
        [
          Component.text(
            row.measured ? row.display : stateLabel(row.state),
          ),
        ],
      ),
    ]);
  }
}
