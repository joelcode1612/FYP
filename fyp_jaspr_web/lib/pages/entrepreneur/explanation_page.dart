import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Explainable recommendation detail, laid out as the source's
/// `explanation.html`.
///
/// ```text
/// .page-head   "Explanation" · "Why this property scored X" · property line
/// .notice      what the current service does and does not return
/// .detail-grid
///   .panel                 feature contributions (explicitly unavailable)
///   .analysis              summary · strengths · trade-offs · next steps
/// ```
///
/// The shared recommendation service returns a summary, strengths and
/// considerations, but **not** per-factor contribution weights. The source's
/// contribution chart is therefore rendered as an explicit unavailable state
/// instead of inventing SHAP-style values.
class ExplanationPage extends StatefulComponent {
  /// The property id from the `?property=` query param.
  final String propertyId;

  const ExplanationPage({super.key, required this.propertyId});

  @override
  State<ExplanationPage> createState() => _ExplanationPageState();
}

class _ExplanationPageState extends State<ExplanationPage> {
  late Future<_ExplanationBundle?> _future;

  @override
  void initState() {
    super.initState();
    _future = _load(component.propertyId);
  }

  void _retry() => setState(() => _future = _load(component.propertyId));

  static Future<_ExplanationBundle?> _load(String id) async {
    final property = await AppLocator.properties.detail(id);
    if (property == null) return null;
    final explanation = await AppLocator.intelligence.explanation(id);
    return _ExplanationBundle(property, explanation);
  }

  @override
  Component build(BuildContext context) {
    if (component.propertyId.isEmpty) {
      return _page(
        title: 'Why this score',
        child: const EmptyState(
          title: 'Nothing to explain',
          body:
              'Open a recommendation and choose “Why this score” for a specific '
              'property.',
          action: ActionLink(
            'Go to recommendations',
            href: '/entrepreneur/recommendations',
            variant: 'primary',
          ),
        ),
      );
    }

    return FutureBuilder<_ExplanationBundle?>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return _page(
            title: 'Why this score',
            child: div(classes: 'loading', [
              span(classes: 'spinner', []),
              Component.text('Loading explanation…'),
            ]),
          );
        }

        if (snap.hasError) {
          return _page(
            title: 'Why this score',
            child: EmptyState(
              title: 'Could not load this explanation',
              body:
                  'The property or explanation service did not respond. The '
                  'listing itself may still be available from Explore.',
              action: ActionButton('Try again', onClick: _retry),
            ),
          );
        }

        final bundle = snap.data;
        if (bundle == null) {
          return _page(
            title: 'Why this score',
            child: EmptyState(
              title: 'Property not found',
              body:
                  'This listing is not available, so there is no explanation to '
                  'show.',
              action: const ActionLink(
                'Back to recommendations',
                href: '/entrepreneur/recommendations',
                variant: 'primary',
              ),
            ),
          );
        }

        return _page(
          title:
              'Why this property scored '
              '${bundle.explanation.suitabilityScore.toStringAsFixed(0)}/100',
          subtitle:
              '${bundle.property.title} · ${bundle.property.address}, '
              '${bundle.property.city}',
          actions: const [
            ActionLink(
              'Back to shortlist',
              href: '/entrepreneur/recommendations',
              variant: 'secondary',
            ),
          ],
          child: _ExplanationBody(bundle: bundle),
        );
      },
    );
  }

  Component _page({
    required String title,
    String? subtitle,
    List<Component> actions = const [],
    required Component child,
  }) {
    return AppLayout(
      role: AppRole.entrepreneur,
      currentRoute: '/entrepreneur/explanation',
      title: title,
      eyebrow: 'Explanation',
      subtitle: subtitle,
      actions: actions,
      child: child,
    );
  }
}

class _ExplanationBody extends StatelessComponent {
  final _ExplanationBundle bundle;

  const _ExplanationBody({required this.bundle});

  @override
  Component build(BuildContext context) {
    final e = bundle.explanation;
    final property = bundle.property;

    return div(classes: 'stack stack--sections', [
      div(classes: 'notice notice-warn', [
        Component.text(
          'The shared recommendation service returns the summary, strengths '
          'and considerations below, but not per-factor contribution weights. '
          'The contribution chart is shown as unavailable rather than '
          'estimated.',
        ),
      ]),
      div(classes: 'detail-grid', [
        section(classes: 'panel', [
          h2([Component.text('Feature contributions')]),
          p(classes: 'what', [
            Component.text(
              'Ordered by the size of each factor’s effect. A positive value '
              'pushed the score up; a negative value pulled it down.',
            ),
          ]),
          const EmptyState(
            title: 'Contribution weights not available',
            body:
                'This build does not return SHAP-style values, factor input '
                'values or the run rank. No weights are estimated here.',
          ),
        ]),
        div(classes: 'analysis', [
          section(classes: 'panel', [
            h2([Component.text('Summary')]),
            p(classes: 'body', [Component.text(e.summary)]),
          ]),
          section(classes: 'panel', [
            h2([Component.text('Working in its favour')]),
            _list(e.strengths, 'No factor had a positive effect in this run.'),
          ]),
          section(classes: 'panel', [
            h2([Component.text('Trade-offs')]),
            _list(
              e.considerations,
              'No factor had a negative effect in this run.',
            ),
          ]),
          section(classes: 'panel', [
            h2([Component.text('Not available')]),
            ul([
              li([Component.text('Per-factor contribution weights')]),
              li([Component.text('The rank this property held in the run')]),
              li([Component.text('Raw input values per factor')]),
              li([Component.text('Missing-input list')]),
            ]),
            p(classes: 'disclaimer', [
              Component.text(
                'Where an input is missing it is excluded from the score rather '
                'than estimated. Regulatory checks (licensing, extraction, '
                'venting, grease trap) are not part of this score and still '
                'need official confirmation.',
              ),
            ]),
          ]),
          section(classes: 'panel', [
            h2([Component.text('Next steps')]),
            div(classes: 'actions-row', [
              ActionLink(
                'Property details',
                href: '/entrepreneur/property-detail?id=${property.id}',
                variant: 'primary',
              ),
              ActionLink(
                'Map & surroundings',
                href: '/entrepreneur/map?id=${property.id}',
                variant: 'secondary',
              ),
              ActionLink(
                'Location report',
                href: '/entrepreneur/report?id=${property.id}',
                variant: 'secondary',
              ),
            ]),
          ]),
        ]),
      ]),
      p(classes: 'disclaimer', [
        Component.text(
          'A suitability score is a relative decision-support indicator. It is '
          'not a probability of business success, a revenue or customer-volume '
          'forecast, regulatory approval, or a guarantee of any kind.',
        ),
      ]),
    ]);
  }

  Component _list(List<String> items, String emptyMessage) {
    if (items.isEmpty) {
      return p(classes: 'what', [Component.text(emptyMessage)]);
    }
    return ul([
      for (final item in items) li([Component.text(item)]),
    ]);
  }
}

class _ExplanationBundle {
  final CommercialProperty property;
  final RecommendationExplanation explanation;

  const _ExplanationBundle(this.property, this.explanation);
}
