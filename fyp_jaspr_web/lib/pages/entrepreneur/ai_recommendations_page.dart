import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Entrepreneur **AI recommendations** — the personalised Layer 2/3 pipeline.
///
/// Distinct from the requirement-fit Recommendations page: this view ranks
/// the research catalogue against the entrepreneur's SAVED preferences via
/// `POST /api/v1/recommendations/generate`, retrieves the durable latest
/// batch via `GET .../me/generated`, and keeps the two explanation layers
/// strictly separated:
///
/// * the rule engine's preference reasons, cautions and component breakdown;
/// * the PU research model's Permutation SHAP payload when the exact
///   47-feature vector resolved — with an explicit unavailable panel when it
///   did not (absence is stated, never estimated away).
///
/// Navigation honours the verified `listing_ref`: assessment and research
/// surfaces open by canonical id; the commercial-listing detail link is only
/// rendered when the backend reports `detail_available` (approved +
/// published), so no recommendation ever links into a 404.
@client
class AiRecommendationsPage extends StatefulComponent {
  /// Optional `?result=` id: shows the two-layer explanation for one owned
  /// result instead of the batch list.
  final String resultId;

  const AiRecommendationsPage({super.key, this.resultId = ''});

  @override
  State<AiRecommendationsPage> createState() => _AiRecommendationsPageState();
}

class _AiRecommendationsPageState extends State<AiRecommendationsPage> {
  late Future<GeneratedBatch?> _latest;
  bool _generating = false;
  String? _error;
  bool _reused = false;

  @override
  void initState() {
    super.initState();
    _latest = _loadLatest();
  }

  Future<GeneratedBatch?> _loadLatest() async {
    setState(() => _error = null);
    return AppLocator.personalisedRecommendations.latest();
  }

  Future<void> _generate() async {
    setState(() {
      _generating = true;
      _error = null;
    });
    try {
      final response =
          await AppLocator.personalisedRecommendations.generate(limit: 20);
      final results = (response['results'] as List?) ?? const [];
      final batch = GeneratedBatch.fromJson({
        'batch_id': response['batch_id'] ?? '',
        'generated_at': response['generated_at'],
        'result_count': results.length,
        'results': results,
      });
      setState(() {
        _generating = false;
        _reused = response['reused_existing_batch'] == true;
        _latest = Future.value(batch);
      });
    } catch (err) {
      setState(() {
        _generating = false;
        _error = err.toString();
      });
    }
  }

  @override
  Component build(BuildContext context) {
    if (component.resultId.isNotEmpty) {
      return _page(
        title: 'Why this match was recommended',
        child: _ExplanationView(resultId: component.resultId),
      );
    }
    return _page(
      title: 'AI recommendations',
      child: div(classes: 'stack stack--sections', [
          div(classes: 'notice', [
            Component.text(
              'Ranked from your saved requirements. Preference fit and the PU '
              'research association index are reported separately and are '
              'never merged into a success probability.',
            ),
          ]),
          _toolbar(),
          if (_error != null)
            div(classes: 'notice notice-warn', [
              Component.text('Could not load AI recommendations: $_error'),
              ActionButton('Try again', onClick: () => setState(() {
                _latest = _loadLatest();
              })),
            ]),
          FutureBuilder<GeneratedBatch?>(
            future: _latest,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return div(classes: 'loading', [
                  span(classes: 'spinner', []),
                  Component.text('Loading personalised matches…'),
                ]);
              }
              if (snap.hasError) {
                return EmptyState(
                  title: 'Could not load AI recommendations',
                  body:
                      'The recommendation service did not respond. Nothing was '
                      'substituted for the missing data.',
                  action: ActionButton(
                    'Try again',
                    onClick: () => setState(() => _latest = _loadLatest()),
                  ),
                );
              }
              final batch = snap.data;
              if (batch == null || batch.results.isEmpty) {
                return EmptyState(
                  title: 'No personalised matches yet',
                  body:
                      'Generate a ranked batch from your saved requirements. '
                      'Results are stored for your account and remain '
                      'available after a restart.',
                  action: ActionButton(
                    'Generate recommendations',
                    onClick: _generate,
                    variant: 'primary',
                  ),
                );
              }
              return div(classes: 'stack', [
                for (final item in batch.results)
                  _AiRecommendationCard(item: item),
              ]);
            },
          ),
        ]),
    );
  }

  Component _toolbar() {
    return div(classes: 'actions-row', [
      ActionButton(
        _generating ? 'Generating…' : 'Regenerate from saved requirements',
        onClick: _generating ? null : _generate,
        variant: 'primary',
      ),
    ]);
  }

  Component _page({required String title, required Component child}) {
    return AppLayout(
      role: AppRole.entrepreneur,
      currentRoute: '/entrepreneur/ai-recommendations',
      title: title,
      eyebrow: 'AI recommendations',
      subtitle: _reused
          ? 'Your latest saved matches — inputs unchanged, nothing recomputed.'
          : 'Personalised matches from your saved requirements.',
      actions: const [
        ActionLink(
          'Requirement search',
          href: '/entrepreneur/recommendations',
          variant: 'secondary',
        ),
      ],
      child: child,
    );
  }
}

class _AiRecommendationCard extends StatelessComponent {
  final GeneratedRecommendation item;

  const _AiRecommendationCard({required this.item});

  @override
  Component build(BuildContext context) {
    final prop = item.property;
    final ref = item.listingRef;
    final prefPct = item.preferenceMatchScore == null
        ? null
        : item.preferenceMatchScore! * 100;
    return section(classes: 'panel', [
      div(classes: 'panel-head', [
        h2([
          Component.text(
            prop.title.isEmpty ? prop.propertyId : prop.title,
          ),
        ]),
        span(classes: 'pill', [
          Component.text(item.rank == null ? '' : '#${item.rank}'),
        ]),
      ]),
      p(classes: 'what', [
        Component.text(
          [
            if (prop.city.isNotEmpty) prop.city,
            if (prop.state.isNotEmpty) prop.state,
            if (prop.propertyType.isNotEmpty) prop.propertyType,
          ].join(' · '),
        ),
      ]),
      div(classes: 'metrics-row', [
        _metric(
          'Preference fit',
          prefPct == null ? 'unknown' : '${prefPct.toStringAsFixed(0)}%',
        ),
        _metric(
          'PU research index',
          (item.puAssociationScore * 100).toStringAsFixed(1),
        ),
        _metric('Final score', item.finalScore.toStringAsFixed(3)),
      ]),
      if (item.preferenceReasons.isNotEmpty) ...[
        h3([Component.text('Why it matches')]),
        ul([
          for (final reason in item.preferenceReasons.take(3))
            li([Component.text(reason)]),
        ]),
      ],
      if (item.cautions.isNotEmpty) ...[
        h3([Component.text('Cautions')]),
        ul(classes: 'cautions', [
          for (final caution in item.cautions.take(3))
            li([Component.text(caution)]),
        ]),
      ],
      div(classes: 'actions-row', [
        ActionLink(
          'Why recommended (explanation)',
          href:
              '/entrepreneur/ai-recommendations?result=${item.resultId}',
          variant: 'primary',
        ),
        ActionLink(
          'Assess this property',
          href:
              '/entrepreneur/assessment?property=${Uri.encodeQueryComponent(item.propertyId)}',
          variant: 'secondary',
        ),
        if (ref != null && ref.detailAvailable)
          ActionLink(
            'Property details',
            href: '/entrepreneur/property-detail?id=${ref.listingId}',
            variant: 'secondary',
          ),
      ]),
      if (ref != null && !ref.detailAvailable)
        p(classes: 'disclaimer', [
          Component.text(ref.detailNote ?? ''),
        ]),
    ]);
  }

  Component _metric(String label, String value) {
    return div(classes: 'metric', [
      span(classes: 'metric-label', [Component.text(label)]),
      span(classes: 'metric-value', [Component.text(value)]),
    ]);
  }
}


/// One owned result's two separated explanations:
/// * the rule engine's reasons, cautions and component breakdown;
/// * the PU model's SHAP payload when the exact 47-feature vector resolved,
///   otherwise the explicit unavailability note from the backend.
class _ExplanationView extends StatefulComponent {
  final String resultId;

  const _ExplanationView({required this.resultId});

  @override
  State<_ExplanationView> createState() => _ExplanationViewState();
}

class _ExplanationViewState extends State<_ExplanationView> {
  late Future<PersonalisedExplanation?> _future;

  @override
  void initState() {
    super.initState();
    _future = _load(component.resultId);
  }

  static Future<PersonalisedExplanation?> _load(String resultId) async {
    return AppLocator.personalisedRecommendations.explanation(resultId);
  }

  @override
  Component build(BuildContext context) {
    return FutureBuilder<PersonalisedExplanation?>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return div(classes: 'loading', [
            span(classes: 'spinner', []),
            Component.text('Loading explanation…'),
          ]);
        }
        if (snap.hasError || snap.data == null) {
          return EmptyState(
            title: 'Could not load this explanation',
            body:
                'The result may have been generated in another session or the '
                'service did not respond. Regenerate the batch and try again.',
            action: const ActionLink(
              'Back to AI recommendations',
              href: '/entrepreneur/ai-recommendations',
              variant: 'primary',
            ),
          );
        }
        final e = snap.data!;
        return div(classes: 'stack stack--sections', [
            section(classes: 'panel', [
              h2([Component.text('Preference match (rule engine)')]),
              p(classes: 'what', [
                Component.text(
                  'These reasons come from the versioned rule engine\'s own '
                  'component calculations. SHAP is never used to explain a '
                  'rule, preference or filter.',
                ),
              ]),
              if (e.preferenceReasons.isEmpty)
                p(classes: 'what', [
                  Component.text(
                    'No preference components were scorable — unknown inputs '
                    'are excluded, never treated as zero.',
                  ),
                ])
              else
                ul([
                  for (final reason in e.preferenceReasons)
                    li([Component.text(reason)]),
                ]),
              if (e.cautions.isNotEmpty) ...[
                h3([Component.text('Cautions')]),
                ul([
                  for (final caution in e.cautions.take(5))
                    li([Component.text(caution)]),
                ]),
              ],
              h3([Component.text('Component breakdown')]),
              ul([
                for (final entry in e.components.entries)
                  li([
                    Component.text(
                      entry.key.replaceAll('_', ' '),
                    ),
                    Component.text(
                      entry.value.value == null
                          ? ' — unknown (excluded, not zero)'
                          : ' — ${entry.value.value!.toStringAsFixed(2)}',
                    ),
                  ]),
              ]),
            ]),
            section(classes: 'panel', [
              h2([Component.text('PU research model (SHAP)')]),
              if (e.shap != null && e.shapStatus.available) ...[
                p(classes: 'what', [
                  Component.text(
                    'Permutation SHAP over the research PU association score. '
                    'Baseline + contributions reconstruct the score '
                    '(verified server-side, error < 1e-6). Research index '
                    'only — not a success probability.',
                  ),
                ]),
                ul([
                  for (final f in e.shap!.topPositive.take(4))
                    li([
                      Component.text(
                        '+ ${f.feature.replaceAll('_', ' ')} '
                        '(${f.contribution.toStringAsFixed(4)})',
                      ),
                    ]),
                  for (final f in e.shap!.topNegative.take(4))
                    li([
                      Component.text(
                        '- ${f.feature.replaceAll('_', ' ')} '
                        '(${f.contribution.toStringAsFixed(4)})',
                      ),
                    ]),
                ]),
              ] else ...[
                p(classes: 'what', [
                  Component.text(
                    'SHAP is unavailable for this property: '
                    '${e.shapStatus.reason ?? 'the exact 47-feature research '
                        'vector could not be resolved.'} '
                    'Nothing is invented to fill the gap; the rule-based '
                    'explanation above remains fully available.',
                  ),
                ]),
              ],
            ]),
            div(classes: 'actions-row', [
              const ActionLink(
                'Back to AI recommendations',
                href: '/entrepreneur/ai-recommendations',
                variant: 'primary',
              ),
            ]),
        ]);
      },
    );
  }
}
