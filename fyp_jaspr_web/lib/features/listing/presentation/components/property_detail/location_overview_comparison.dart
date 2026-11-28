import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'package:sitewise_jaspr_web/features/listing/data/location_evidence_api.dart';
import 'package:sitewise_jaspr_web/core/utils/metric_format.dart';
import 'package:sitewise_jaspr_web/shared/presentation/components/ui.dart';

/// Radius-consistent location overview for the entrepreneur property-detail tab.
///
/// The parent provides the existing PropertyEvidence from its cached future.
/// This component does NOT request data, score a property, or change any data.
/// All missing readings stay missing; a measured zero is displayed as zero.
///
/// Circle radii (500 m / 1 km) are not travel distances. Walking-network
/// metrics are therefore displayed only in the separate Access & walkability
/// section, with their own scopes named explicitly.
class LocationOverviewComparison extends StatelessComponent {
  final PropertyEvidence? evidence;
  final bool loading;
  final Object? error;

  const LocationOverviewComparison({
    super.key,
    required this.evidence,
    this.loading = false,
    this.error,
  });

  Map<String, EvidenceMetric> _measurements(PropertyEvidence result) => {
    for (final group in result.groups)
      for (final metric in group.metrics) metric.key: metric,
  };

  String _reading(
    Map<String, EvidenceMetric> metrics,
    String key, {
    String singular = '',
    String plural = '',
    bool residents = false,
    bool distance = false,
  }) {
    final value = metrics[key];
    if (value == null || !value.available) return 'Not measured';
    if (residents) return fmtResidents(value.value) ?? 'Not measured';
    if (distance) return fmtDistance(value.value) ?? 'Not measured';
    if (singular.isNotEmpty) {
      return fmtCount(value.value, singular: singular, plural: plural) ??
          'Not measured';
    }
    return fmtEvidenceValue(value.value, value.unit) ?? 'Not measured';
  }

  Component _metric({
    required String icon,
    required String label,
    required String value,
    String? note,
  }) => div(classes: 'sw-loccmp__metric', [
    span(classes: 'sw-loccmp__metric-icon', [Icon(icon, size: 'sm')]),
    div(classes: 'sw-loccmp__metric-content', [
      span(classes: 'sw-loccmp__metric-label', [Component.text(label)]),
      strong(
        classes: 'sw-loccmp__metric-value${value == 'Not measured' ? ' is-missing' : ''}',
        [Component.text(value)],
      ),
      if (note != null)
        span(classes: 'sw-loccmp__metric-note', [Component.text(note)]),
    ]),
  ]);

  Component _nearestCompetitor(EvidenceMetric metric) => _metric(
    icon: 'storefront',
    label: 'Nearest F&B competitor',
    value: metric.available ? metric.displayValue : 'Unavailable',
    note: metric.note,
  );

  Component _distanceGroup({
    required String radius,
    required String subtitle,
    required bool farther,
    required Map<String, EvidenceMetric> metrics,
  }) {
    final suffix = farther ? '1000m' : '500m';
    final parkingKey = farther ? 'parking_facilities_1km' : 'parking_facilities_500m';
    final retailKey = farther ? 'retail_pois_1000m' : 'retail_pois_500m';
    return section(classes: 'sw-loccmp__radius-panel', [
      div(classes: 'sw-loccmp__radius-head', [
        span(classes: 'sw-loccmp__radius-mark', [
          const Icon('distance', size: 'sm'),
          Component.text(radius),
        ]),
        div([
          h3([Component.text('Within $radius')]),
          p([Component.text(subtitle)]),
        ]),
      ]),
      div(classes: 'sw-loccmp__metric-grid', [
        _metric(
          icon: 'groups',
          label: 'Estimated residents',
          value: _reading(metrics, 'pop_$suffix', residents: true),
          note: 'Residential population estimate',
        ),
        _metric(
          icon: 'storefront',
          label: 'F&B competition',
          value: _reading(
            metrics,
            'competitor_count_$suffix',
            singular: 'outlet',
            plural: 'outlets',
          ),
          note: 'Other mapped F&B businesses',
        ),
        _metric(
          icon: 'local_parking',
          label: 'Parking facilities',
          value: _reading(
            metrics,
            parkingKey,
            singular: 'facility',
            plural: 'facilities',
          ),
          note: 'Mapped facilities, not free spaces',
        ),
        _metric(
          icon: 'shopping_bag',
          label: 'Retail shops',
          value: _reading(
            metrics,
            retailKey,
            singular: 'shop',
            plural: 'shops',
          ),
          note: 'Mapped retail businesses',
        ),
      ]),
      div(classes: 'sw-loccmp__radius-bottom', [
        const Icon('info', size: 'sm'),
        if (farther)
          Component.text(
            'Offices: ${_reading(metrics, 'office_pois_1000m', singular: 'office', plural: 'offices')}. '
            'These counts are within a 1 km radius, not a walking catchment.',
          )
        else
          const Component.text(
            'Nearby counts use a 500 m radius, not a 500 m walking route.',
          ),
      ]),
    ]);
  }

  Component _accessTile({
    required String icon,
    required String title,
    required String value,
    required String explanation,
  }) => div(classes: 'sw-loccmp__access-tile', [
    span(classes: 'sw-loccmp__access-icon', [Icon(icon)]),
    div([
      span(classes: 'sw-loccmp__access-title', [Component.text(title)]),
      strong(classes: 'sw-loccmp__access-value', [Component.text(value)]),
      p(classes: 'sw-loccmp__access-description', [Component.text(explanation)]),
    ]),
  ]);

  Component _accessPanel(Map<String, EvidenceMetric> metrics) =>
      section(classes: 'sw-loccmp__access', [
        div(classes: 'sw-loccmp__access-head', [
          div([
            h3([const Component.text('Access & walkability')]),
            p([
              const Component.text(
                'Travel distances and walking reach are shown separately from the radius totals.',
              ),
            ]),
          ]),
        ]),
        div(classes: 'sw-loccmp__access-grid', [
          _accessTile(
            icon: 'directions_bus',
            title: 'Nearest public transport',
            value: _reading(metrics, 'nearest_transit_walk_m', distance: true),
            explanation:
                '${_reading(metrics, 'bus_stops_500m_walk', singular: 'bus stop', plural: 'bus stops')} within a 500 m walk · '
                '${_reading(metrics, 'rail_stations_1km_walk', singular: 'rail station', plural: 'rail stations')} within a 1 km walk',
          ),
          _accessTile(
            icon: 'local_parking',
            title: 'Nearest parking facility',
            value: _reading(metrics, 'nearest_parking_distance_m', distance: true),
            explanation: 'Distance to the nearest mapped parking location',
          ),
          _accessTile(
            icon: 'directions_walk',
            title: '10-minute walking reach',
            value: _reading(metrics, 'walk_isochrone_area_10min_km2'),
            explanation: 'Area reachable on foot, not a population count',
          ),
        ]),
      ]);

  @override
  Component build(BuildContext context) {
    if (loading) {
      return section(classes: 'sw-loccmp', [
        h2([const Component.text('Location overview')]),
        div(classes: 'loading', [
          const Component.text('Loading location measurements…'),
        ]),
      ]);
    }
    final result = evidence;
    if (result?.nearestCompetitor case final nearest?) {
      return _nearestCompetitor(nearest);
    }
    if (error != null || result == null || !result.available) {
      return section(classes: 'sw-loccmp', [
        h2([const Component.text('Location overview')]),
        p(classes: 'sw-loccmp__empty', [
          Component.text(error != null
              ? 'Location measurements could not be loaded for this property.'
              : result?.reason ?? 'Location measurements are not available for this property.'),
        ]),
      ]);
    }
    final metrics = _measurements(result);
    return section(classes: 'sw-loccmp', [
      div(classes: 'sw-loccmp__header', [
        div([
          span(classes: 'sw-loccmp__eyebrow', [
            const Component.text('PROPERTY SURROUNDINGS'),
          ]),
          h2([const Component.text('Location overview')]),
          p([
            const Component.text(
              'Compare what is around this property at 500 m and 1 km.',
            ),
          ]),
        ]),
        span(classes: 'sw-loccmp__scope', [
          const Icon('check_circle', size: 'sm'),
          const Component.text('Based on recorded area measurements'),
        ]),
      ]),
      div(classes: 'sw-loccmp__radii', [
        _distanceGroup(
          radius: '500 m',
          subtitle: 'The immediate area around this property',
          farther: false,
          metrics: metrics,
        ),
        _distanceGroup(
          radius: '1 km',
          subtitle: 'The wider surrounding area',
          farther: true,
          metrics: metrics,
        ),
      ]),
      _accessPanel(metrics),
      if (metrics['nearest_competitor_distance_m'] case final nearest?)
        _nearestCompetitor(nearest),
      p(classes: 'sw-loccmp__footer', [
        const Icon('info', size: 'sm'),
        Component.text(
          '500 m and 1 km are circular distance bands. Bus and rail figures '
          'use their stated walking distances. Missing measurements are shown '
          'as “Not measured”, not zero.'
          '${result.snapshotAt == null || result.snapshotAt!.length < 10 ? '' : ' Last measured ${result.snapshotAt!.substring(0, 10)}.'}',
        ),
      ]),
    ]);
  }
}
