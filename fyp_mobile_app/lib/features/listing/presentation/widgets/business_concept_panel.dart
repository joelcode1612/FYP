import 'package:flutter/material.dart';
import 'package:fyp/core/di/service_locator.dart';
import 'package:fyp/core/theme/sitewise_theme.dart';

/// On-demand property -> F&B concept comparison. All numbers are backend data.
/// General PU and category research scores never become ranking weights.
class BusinessConceptPanel extends StatefulWidget {
  final String propertyId;
  const BusinessConceptPanel({super.key, required this.propertyId});

  @override
  State<BusinessConceptPanel> createState() => _BusinessConceptPanelState();
}

class _BusinessConceptPanelState extends State<BusinessConceptPanel> {
  Future<Map<String, dynamic>>? _assessment;

  Future<Map<String, dynamic>> _load() async {
    final result = await ServiceLocator.apiClient.get(
      '/api/v1/catalog/properties/${Uri.encodeComponent(widget.propertyId)}/business-concepts',
    );
    return result['data'] is Map
        ? Map<String, dynamic>.from(result['data'] as Map)
        : result;
  }

  String _formatScore(Object? score) =>
      score is num ? '${score.toStringAsFixed(1)}/100' : 'Not measured';

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: SitewiseColors.surface,
      border: Border.all(color: SitewiseColors.border),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Which F&B business could fit here?', style: TextStyle(
        color: SitewiseColors.ink, fontWeight: FontWeight.w800, fontSize: 17)),
      const SizedBox(height: 8),
      const Text('Compare five business concepts using measured location evidence. '
          'Results are exploratory, not predictions of sales, approval or success.',
          style: TextStyle(color: SitewiseColors.muted, fontSize: 13, height: 1.4)),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: () => setState(() => _assessment = _load()),
        icon: const Icon(Icons.insights_outlined),
        label: Text(_assessment == null ? 'Assess business concepts' : 'Refresh assessment'),
      ),
      if (_assessment != null) ...[
        const SizedBox(height: 14),
        FutureBuilder<Map<String, dynamic>>(
          future: _assessment,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(padding: EdgeInsets.all(12),
                  child: Center(child: CircularProgressIndicator()));
            }
            if (snapshot.hasError || snapshot.data == null) {
              return const Text('Business concept assessment could not be loaded. '
                  'Check your connection and try again.',
                  style: TextStyle(color: SitewiseColors.muted, fontSize: 13));
            }
            return _assessmentView(snapshot.data!);
          },
        ),
      ],
    ]),
  );

  Widget _assessmentView(Map<String, dynamic> payload) {
    final decision = payload['concept_assessment'] as Map? ?? {};
    final general = payload['general_pu'] as Map? ?? {};
    final research = payload['category_research'] as Map? ?? {};
    final rankings = (decision['rankings'] as List? ?? const []).whereType<Map>().toList();
    final available = decision['available'] == true;
    final flags = (payload['evidence_flags'] as List? ?? const []).take(4);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('General 64-feature PU association: ${_formatScore(general['association_index_0_100'])}',
          style: const TextStyle(fontWeight: FontWeight.w700, color: SitewiseColors.ink)),
      const SizedBox(height: 5),
      const Text('The PU index is shared location evidence, not a success probability. '
          'It is excluded from the concept ranking.',
          style: TextStyle(color: SitewiseColors.muted, fontSize: 12, height: 1.45)),
      const SizedBox(height: 12),
      Text(available ? 'Provisional concept ranking' : 'Comparison not yet possible',
          style: const TextStyle(color: SitewiseColors.ink,
              fontWeight: FontWeight.w800, fontSize: 15)),
      const SizedBox(height: 5),
      Text('${decision['note'] ?? ''}', style: const TextStyle(
          color: SitewiseColors.muted, fontSize: 12, height: 1.4)),
      for (final raw in rankings) ...[
        const Divider(color: SitewiseColors.border, height: 22),
        Text('${raw['rank'] != null ? '${raw['rank']}. ' : ''}${raw['name'] ?? ''} — ${_formatScore(raw['score'])}',
            style: const TextStyle(color: SitewiseColors.ink,
                fontWeight: FontWeight.w700, fontSize: 14)),
        if (raw['component_scores'] is Map)
          Padding(padding: const EdgeInsets.only(top: 4), child: Text(
            'Demand ${_formatScore((raw['component_scores'] as Map)['demand'])} · '
            'Access ${_formatScore((raw['component_scores'] as Map)['accessibility'])} · '
            'Competition ${_formatScore((raw['component_scores'] as Map)['competition'])}',
            style: const TextStyle(color: SitewiseColors.muted, fontSize: 12))),
        for (final reason in (raw['strengths'] as List? ?? const []).take(1))
          Padding(padding: const EdgeInsets.only(top: 5), child: Text('Strength: $reason',
              style: const TextStyle(color: SitewiseColors.text, fontSize: 12))),
        for (final reason in (raw['limitations'] as List? ?? const []).take(1))
          Padding(padding: const EdgeInsets.only(top: 4), child: Text('Consider: $reason',
              style: const TextStyle(color: SitewiseColors.text, fontSize: 12))),
        if (!available)
          Text('Missing: ${(raw['missing_features'] as List? ?? const []).join(', ')}',
              style: const TextStyle(color: SitewiseColors.muted, fontSize: 12)),
        const Text('Premises approval and operational facilities: verify before deciding.',
            style: TextStyle(color: SitewiseColors.muted, fontSize: 12)),
      ],
      const SizedBox(height: 12),
      Text('Four-class research model: ${research['available'] == true ? 'available (not used in ranking)' : 'unavailable'}',
          style: const TextStyle(color: SitewiseColors.ink, fontWeight: FontWeight.w700, fontSize: 12)),
      for (final raw in (research['rankings'] as List? ?? const []).whereType<Map>())
        Text('${raw['business_type'] ?? ''}: research association ${raw['score'] ?? 'unknown'}',
            style: const TextStyle(color: SitewiseColors.muted, fontSize: 12)),
      const SizedBox(height: 4),
      const Text('Bakery/dessert and beverage are combined in the research model. '
          'Research outputs are not five-business success probabilities.',
          style: TextStyle(color: SitewiseColors.muted, fontSize: 12, height: 1.4)),
      for (final flag in flags)
        Padding(padding: const EdgeInsets.only(top: 6), child: Text('• $flag',
            style: const TextStyle(color: SitewiseColors.muted, fontSize: 12))),
    ]);
  }
}
