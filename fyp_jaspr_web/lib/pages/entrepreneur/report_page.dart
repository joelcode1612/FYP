import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web evaluation report, laid out as the source's `report.html`.
///
/// ```text
/// .page-head   "Location report" · property title · generation line + actions
/// .report-grid
///   .panel > .kv            Summary: rent / area / type / score / preferences
///   .finding.good           Supports this location
///   h2 + .finding.limit     Limitations and trade-offs
///   h2 + .finding.unknown   Unknowns — needs confirmation
/// disclaimer
/// ```
///
/// The previous version was one centred `.card` with `divider`s — a document
/// dump with no grouping, so a supporting factor and an unknown looked the same.
/// The source separates them into three graded columns of evidence.
class ReportPage extends StatelessComponent {
  /// The property id from the `?id=` query param.
  final String id;

  const ReportPage({super.key, required this.id});

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.entrepreneur,
      currentRoute: '/entrepreneur/report',
      title: 'Evaluation report',
      eyebrow: 'Location report',
      subtitle:
          'The full location evaluation for this site — footfall, competition, '
          'accessibility and demographics.',
      child: id.isEmpty
          ? const _NotFound()
          : FutureBuilder<CommercialProperty?>(
              future: AppLocator.properties.detail(id),
              builder: (ctx, propSnap) {
                if (propSnap.connectionState != ConnectionState.done) {
                  return const _Loading(message: 'Generating report…');
                }
                final p = propSnap.data;
                if (p == null) return const _NotFound();
                return FutureBuilder<LocationAnalysis>(
                  future: AppLocator.recommendations.analysis(id),
                  builder: (c2, aSnap) {
                    if (!aSnap.hasData) {
                      return const _Loading(message: 'Generating report…');
                    }
                    return _Report(property: p, analysis: aSnap.data!);
                  },
                );
              },
            ),
    );
  }
}

class _Report extends StatelessComponent {
  final CommercialProperty property;
  final LocationAnalysis analysis;

  const _Report({required this.property, required this.analysis});

  @override
  Component build(BuildContext context) {
    final a = analysis;
    final supporting = a.factors.where((f) => f.impact == 'Positive').toList();
    final limiting = a.factors.where((f) => f.impact != 'Positive').toList();

    return div(classes: 'report-grid', [
      // --- Summary ---------------------------------------------------------
      section(classes: 'panel', [
        h2([Component.text('Summary')]),
        dl(classes: 'kv', [
          _row('Monthly rent', property.rentalDisplay, 'admin'),
          _row(
            'Floor area',
            '${property.sizeSqft.toStringAsFixed(0)} sq ft',
            'admin',
          ),
          _row('Property type', property.propertyType, 'owner'),
          _row('Competitors nearby', '${a.competitorCount}', 'demo'),
          _row(
            'Suitability score',
            '${a.suitabilityScore.toStringAsFixed(0)}/100 · ${a.verdict}',
            'model',
          ),
          _row('Verification', property.verification.label, 'admin'),
        ]),
      ]),

      // --- Supports --------------------------------------------------------
      div(classes: 'report-group', [
        h2(classes: 'title', [Component.text('Supports this location')]),
        if (supporting.isEmpty)
          div(classes: 'finding', [
            p([Component.text('Nothing recorded in this category.')]),
          ])
        else
          for (final f in supporting)
            div(classes: 'finding good', [
              h4([Component.text(f.name)]),
              p([Component.text(f.evidence)]),
            ]),
      ]),

      // --- Limitations -----------------------------------------------------
      div(classes: 'report-group', [
        h2(classes: 'title', [Component.text('Limitations and trade-offs')]),
        if (limiting.isEmpty)
          div(classes: 'finding', [
            p([Component.text('Nothing recorded in this category.')]),
          ])
        else
          for (final f in limiting)
            div(classes: 'finding limit', [
              h4([Component.text('${f.name} — ${f.rating}')]),
              p([Component.text(f.evidence)]),
            ]),
      ]),

      // --- Unknowns --------------------------------------------------------
      // The source's honesty contract: what the system did not measure, stated
      // explicitly rather than left as an empty space in the report.
      div(classes: 'report-group', [
        h2(classes: 'title', [Component.text('Unknowns — needs confirmation')]),
        div(classes: 'finding unknown', [
          p([
            Component.text(
              'Unit condition is owner-declared and has not been independently '
              'verified.',
            ),
          ]),
        ]),
        div(classes: 'finding unknown', [
          p([
            Component.text(
              'Regulatory suitability (licensing, extraction/venting capacity, '
              'grease trap) is not assessed by this system.',
            ),
          ]),
        ]),
        div(classes: 'finding unknown', [
          p([
            Component.text(
              'No revenue, footfall or customer-volume forecast is produced by '
              'this system.',
            ),
          ]),
        ]),
      ]),

      p(classes: 'disclaimer', [
        Component.text(
          'This report is decision support. It is not verified fact, not '
          'regulatory advice, and not a prediction of business performance.',
        ),
      ]),

      div(classes: 'actions-row', [
        ActionLink(
          'Back to property',
          href: '/entrepreneur/property-detail?id=${property.id}',
          variant: 'secondary',
        ),
        ActionLink(
          'Open map analysis',
          href: '/entrepreneur/explore?id=map',
          variant: 'secondary',
        ),
      ]),
    ]);
  }

  /// One summary row: label, value and its provenance chip.
  ///
  /// `admin` = administrator-verified listing field, `owner` = owner-declared,
  /// `model` = produced by the scorer, `demo` = sample dataset.
  Component _row(String label, String value, String prov) => div([
    dt([Component.text(label)]),
    dd([Component.text(value)]),
    span([
      span(classes: 'prov prov-$prov', [
        Component.text(switch (prov) {
          'admin' => 'Admin verified',
          'owner' => 'Owner provided',
          'model' => 'Model output',
          _ => 'Demo value',
        }),
      ]),
    ]),
  ]);
}

class _Loading extends StatelessComponent {
  final String message;
  const _Loading({this.message = 'Loading…'});

  @override
  Component build(BuildContext context) => div(classes: 'loading', [
    span(classes: 'spinner', []),
    Component.text(message),
  ]);
}

class _NotFound extends StatelessComponent {
  const _NotFound();

  @override
  Component build(BuildContext context) => EmptyState(
    title: 'Record not found',
    body:
        'This report could not be generated — the property id is missing or the '
        'listing is unavailable.',
    action: const ActionLink(
      'Back to explore',
      href: '/entrepreneur/explore',
      variant: 'primary',
    ),
  );
}
