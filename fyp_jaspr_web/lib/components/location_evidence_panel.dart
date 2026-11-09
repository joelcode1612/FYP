import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../data/location_evidence_api.dart';
import 'ui.dart';

/// These are analysis sections, not independent model predictions or weighted
/// questionnaire scores. Metric values come from the backend's evidence API.
const evidenceSections = <(String, String, String)>[
  ('competition', '01 · F&B business concept', 'Competitor pressure'),
  ('accessibility', '02 · Service model', 'Access & movement'),
  ('demand', '03 · Target customers', 'Catchment demand'),
  ('built_environment', '04 · Location priorities', 'Buildings & parking'),
];

class LocationEvidencePreview extends StatelessComponent {
  final Future<PropertyEvidence>? future;
  final String propertyId;

  const LocationEvidencePreview({
    super.key,
    required this.future,
    required this.propertyId,
  });

  @override
  Component build(
    BuildContext context,
  ) => section(classes: 'panel sw-pd__evidence', [
    div(classes: 'sw-pd__section-title', [
      div([
        span(classes: 'sw-pd__eyebrow', [
          Component.text('LOCATION INTELLIGENCE'),
        ]),
        h2([Component.text('Surrounding area analysis')]),
      ]),
      ActionLink(
        'Full analysis',
        href:
            '/entrepreneur/property-analysis?id=${Uri.encodeComponent(propertyId)}',
        variant: 'secondary',
        icon: 'arrow_forward',
      ),
    ]),
    if (future == null)
      p(classes: 'small', [Component.text('Analysis source is unavailable.')])
    else
      FutureBuilder<PropertyEvidence>(
        future: future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return p(classes: 'small', [
              Component.text('Loading location evidence…'),
            ]);
          }
          if (snap.hasError) {
            return p(classes: 'small', [
              Component.text(
                'Could not retrieve the location analysis. Check the backend connection.',
              ),
            ]);
          }
          final evidence = snap.data;
          if (evidence == null || !evidence.available) {
            return p(classes: 'small', [
              Component.text(
                evidence?.reason ??
                    'No verified analytical feature row is available.',
              ),
            ]);
          }
          return div(classes: 'sw-pd__analysis-preview', [
            for (final (key, eyebrow, title) in evidenceSections)
              _miniSection(evidence.group(key), eyebrow, title),
            div(classes: 'sw-pd__evidence-tile', [
              span(classes: 'sw-pd__eyebrow', [
                Component.text('05 · PRICE POSITIONING'),
              ]),
              h3([Component.text('Price-market comparison')]),
              p(classes: 'small', [
                Component.text(
                  'Comparable F&B menu-price information is not provided by this evidence endpoint.',
                ),
              ]),
            ]),
          ]);
        },
      ),
    p(classes: 'sw-pd__footnote', [
      Component.text(
        'Research counts and distances are descriptive evidence, not a prediction of business success.',
      ),
    ]),
  ]);

  Component _miniSection(EvidenceGroup? group, String eyebrow, String title) {
    final metrics =
        group?.availableMetrics.take(2).toList() ?? const <EvidenceMetric>[];
    return div(classes: 'sw-pd__evidence-tile', [
      span(classes: 'sw-pd__eyebrow', [Component.text(eyebrow.toUpperCase())]),
      h3([Component.text(title)]),
      if (metrics.isEmpty)
        p(classes: 'small', [Component.text('No measurements available')])
      else
        for (final metric in metrics)
          div(classes: 'sw-pd__metric-line', [
            span([Component.text(metric.label)]),
            strong([Component.text(metric.displayValue)]),
          ]),
    ]);
  }
}

class LocationEvidenceDetails extends StatelessComponent {
  final PropertyEvidence evidence;
  final CommercialProperty property;

  const LocationEvidenceDetails({
    super.key,
    required this.evidence,
    required this.property,
  });

  @override
  Component build(BuildContext context) {
    if (!evidence.available) {
      return section(classes: 'panel', [
        h2([Component.text('Location analysis unavailable')]),
        p(classes: 'body', [
          Component.text(
            evidence.reason ??
                'No verified analytical feature row is linked to this property.',
          ),
        ]),
      ]);
    }
    return div(classes: 'sw-pa__groups', [
      for (final (key, eyebrow, title) in evidenceSections)
        _section(evidence.group(key), eyebrow, title),
      section(classes: 'panel sw-pa__group', [
        span(classes: 'sw-pd__eyebrow', [
          Component.text('05 · BUSINESS PRICE POSITIONING'),
        ]),
        h2([Component.text('Rent and market-price context')]),
        div(classes: 'sw-pa__metric', [
          div([
            strong([Component.text('Asking monthly rent')]),
            p([Component.text('Listing information')]),
          ]),
          strong([Component.text(property.rentalDisplay)]),
        ]),
        if (property.sizeSqft > 0)
          div(classes: 'sw-pa__metric', [
            div([
              strong([Component.text('Rental efficiency')]),
              p([Component.text('Calculated from asking rent and floor area')]),
            ]),
            strong([
              Component.text(
                'RM ${property.rentalPerSqft.toStringAsFixed(2)} / sq ft',
              ),
            ]),
          ]),
        for (final metric
            in evidence.group('demand')?.metrics ?? const <EvidenceMetric>[])
          if (metric.key == 'district_income_median_myr') _metric(metric),
        p(classes: 'sw-pd__footnote', [
          Component.text(
            'No verified comparable F&B menu-price dataset is exposed here. Rental cost and district income do not establish consumer willingness to pay.',
          ),
        ]),
      ]),
    ]);
  }

  Component _section(EvidenceGroup? group, String eyebrow, String title) {
    return section(classes: 'panel sw-pa__group', [
      span(classes: 'sw-pd__eyebrow', [Component.text(eyebrow.toUpperCase())]),
      h2([Component.text(title)]),
      if (group == null || group.metrics.isEmpty)
        p(classes: 'small', [
          Component.text('No corresponding source metrics are available.'),
        ])
      else
        for (final metric in group.metrics) _metric(metric),
    ]);
  }

  Component _metric(EvidenceMetric metric) => div(classes: 'sw-pa__metric', [
    div([
      strong([Component.text(metric.label)]),
      if (metric.note != null && metric.note!.isNotEmpty)
        p(classes: 'sw-pa__metric-note', [Component.text(metric.note!)]),
    ]),
    div(classes: 'sw-pa__metric-value', [
      strong([Component.text(metric.displayValue)]),
      span(
        classes: metric.available ? 'sw-pa__available' : 'sw-pa__unavailable',
        [Component.text(metric.available ? 'Measured' : 'Unavailable')],
      ),
    ]),
  ]);
}
