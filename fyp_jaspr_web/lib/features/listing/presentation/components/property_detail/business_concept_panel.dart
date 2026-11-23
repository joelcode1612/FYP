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
      for (final item in concepts) div(classes: 'sw-pd__detail-row', [
        h3([Component.text('${item['rank'] == null ? '' : '${item['rank']}. '}${item['name'] ?? ''} — ${_score(item['score'])}')]),
        if (item['component_scores'] is Map) p([Component.text(
          'Demand ${_score((item['component_scores'] as Map)['demand'])} · '
          'Access ${_score((item['component_scores'] as Map)['accessibility'])} · '
          'Competition ${_score((item['component_scores'] as Map)['competition'])}',
        )]),
        for (final reason in (item['strengths'] as List? ?? const []).take(1))
          p([Component.text('Strength: $reason')]),
        for (final reason in (item['limitations'] as List? ?? const []).take(1))
          p([Component.text('Consider: $reason')]),
        if (!available) p([Component.text('Missing: ${(item['missing_features'] as List? ?? const []).join(', ')}')]),
        p([Component.text('Premises requirements and F&B approval must be verified before a final decision.')]),
      ]),
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
}
