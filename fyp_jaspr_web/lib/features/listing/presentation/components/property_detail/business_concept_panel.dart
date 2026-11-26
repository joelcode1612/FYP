import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:sitewise_jaspr_web/features/authentication/data/auth_browser.dart';

/// Read-only on-demand five-concept comparison. The backend owns all scores.
@client
class BusinessConceptPanel extends StatefulComponent {
  final String propertyId;
  const BusinessConceptPanel({super.key, required this.propertyId});

  @override
  State<BusinessConceptPanel> createState() => _BusinessConceptPanelState();
}

class _BusinessConceptPanelState extends State<BusinessConceptPanel> {
  Future<Map<String, dynamic>>? _future;

  Future<Map<String, dynamic>> _load() => WebAuth.request(
    '/api/v1/catalog/properties/${Uri.encodeComponent(component.propertyId)}/business-concepts',
  );

  String _score(Object? v) => v is num ? '${v.toStringAsFixed(1)}/100' : 'Not available';

  @override
  Component build(BuildContext context) => section(classes: 'sw-info sw-fnb-v2', [
    div(classes: 'sw-info__head', [
      h2(classes: 'sw-info__title', [Component.text('Which F&B business could fit here?')]),
      p(classes: 'sw-info__lede', [Component.text(
        'Compare five concepts using measured demand, transport and competitor signals. '
        'Exploratory guidance only — not a business success or premises approval forecast.',
      )]),
    ]),
    button(
      classes: 'sw-pd__details-toggle',
      attributes: const {'type': 'button'},
      events: events(onClick: () => setState(() => _future = _load())),
      [Component.text(_future == null ? 'Assess business concepts' : 'Refresh assessment')],
    ),
    if (_future != null) FutureBuilder<Map<String, dynamic>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return p([Component.text('Analyzing recorded location evidence…')]);
        }
        if (snapshot.hasError || snapshot.data == null) {
          return p([Component.text('Business assessment is unavailable. Check your connection and retry.')]);
        }
        return _result(snapshot.data!);
      },
    ),
  ]);

  Component _result(Map<String, dynamic> payload) {
    final data = payload['concept_assessment'] as Map? ?? {};
    final pu = payload['general_pu'] as Map? ?? {};
    final research = payload['category_research'] as Map? ?? {};
    final available = data['available'] == true;
    final concepts = (data['rankings'] as List? ?? const []).whereType<Map>();
    return div(classes: 'sw-info__panel', [
      h3([Component.text('General F&B PU association: ${_score(pu['association_index_0_100'])}')]),
      p([Component.text('The established 64-feature PU index is context only, not a business success probability or a ranking input.')]),
      h3([Component.text(available ? 'Provisional business-concept comparison' : 'Insufficient comparable evidence')]),
      p([Component.text('${data['note'] ?? ''}')]),
      for (final item in concepts) _conceptCard(item, available: available),
      h3([Component.text('Four-class category research (not used to calculate ranks)')]),
      if (research['available'] == true)
        for (final item in (research['rankings'] as List? ?? const []).whereType<Map>())
          p([Component.text('${item['business_type'] ?? ''}: research association ${item['score'] ?? 'unknown'}')])
      else p([Component.text('Category research model unavailable for this property.')]),
      p([Component.text('The research model combines bakery, dessert and beverage. Neither ML output measures profitability or licensing.')]),
      for (final flag in (payload['evidence_flags'] as List? ?? const []).take(4))
        p([Component.text('• $flag')]),
    ]);
  }

  /// One concept rendered as its own card.
  ///
  /// These five pieces used to be siblings inside a `.sw-pd__detail-row`,
  /// which is a two-column label/value rule (flex + space-between). Five
  /// blocks were therefore squeezed into one unlabelled strip, and the long
  /// "Consider" sentence ran into the premises note. Every value keeps its own
  /// label and line here, so nothing can overlap at any viewport width.
  Component _conceptCard(Map item, {required bool available}) {
    final scores = item['component_scores'];
    final strengths =
        (item['strengths'] as List? ?? const []).whereType<Object>().take(1).toList();
    final limitations =
        (item['limitations'] as List? ?? const []).whereType<Object>().take(1).toList();
    final missing = (item['missing_features'] as List? ?? const []).join(', ');
    final rank = item['rank'];
    return div(classes: 'sw-fnb-card', [
      div(classes: 'sw-fnb-card__head', [
        h3(classes: 'sw-fnb-card__name', [
          Component.text('${rank == null ? '' : '$rank. '}${item['name'] ?? ''}'),
        ]),
        span(classes: 'sw-fnb-card__score', [
          Component.text(_score(item['score'])),
        ]),
      ]),
      if (scores is Map) div(classes: 'sw-fnb-card__metrics', [
        _metric('Demand', scores['demand']),
        _metric('Access', scores['accessibility']),
        _metric('Competition', scores['competition']),
      ]),
      if (strengths.isNotEmpty || limitations.isNotEmpty)
        div(classes: 'sw-fnb-card__notes', [
          for (final reason in strengths) _note('Strength', reason),
          for (final reason in limitations) _note('Consider', reason),
        ]),
      if (!available)
        p(classes: 'sw-fnb-card__foot', [Component.text('Missing: $missing')]),
      p(classes: 'sw-fnb-card__foot', [
        Component.text(
          'Premises requirements and F&B approval must be verified before a final decision.',
        ),
      ]),
    ]);
  }

  Component _metric(String label, Object? value) => div(classes: 'sw-fnb-metric', [
    span(classes: 'sw-fnb-metric__label', [Component.text(label)]),
    span(classes: 'sw-fnb-metric__value', [Component.text(_score(value))]),
  ]);

  Component _note(String label, Object body) => div(classes: 'sw-fnb-note', [
    span(classes: 'sw-fnb-note__label', [Component.text(label)]),
    p(classes: 'sw-fnb-note__body', [Component.text('$body')]),
  ]);
}
