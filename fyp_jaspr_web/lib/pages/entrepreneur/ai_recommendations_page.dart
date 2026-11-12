import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../data/preference_labels.dart';
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

  // Each saved batch contains at most 20 ranked results. Pagination changes
  // presentation only: it never re-ranks, truncates, or regenerates a batch.
  static const int _pageSize = 5;
  int _pageIndex = 0; // Zero-based; the URL uses one-based ?page=N.

  void _goToPage(int pageIndex) {
    if (pageIndex == _pageIndex) return;
    setState(() => _pageIndex = pageIndex);
  }

  /// Dev-only: metadata of the PU model variant that produced the batch
  /// (legacy default vs experimental47). Never rendered for normal users.
  Map<String, dynamic> _modelInfo = const {};

  /// Development-only gate: debug builds, or `?debug=1` in the URL query.
  static bool get _devModelView {
    if (kDebugMode) return true;
    return Uri.base.queryParameters.containsKey('debug');
  }

  @override
  void initState() {
    super.initState();
    // Keep the result page when returning from an explanation, including
    // when the router remounts this component.
    final requestedPage = int.tryParse(Uri.base.queryParameters['page'] ?? '1');
    _pageIndex = requestedPage != null && requestedPage > 0
        ? requestedPage - 1
        : 0;
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
        _pageIndex = 0; // A new/reused generated batch opens at rank 1.
        _reused = response['reused_existing_batch'] == true;
        _modelInfo = Map<String, dynamic>.from(
          (response['model'] as Map?) ?? const {},
        );
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
      child: div(classes: 'stack', styles: Styles(raw: {'gap': '20px'}), [
          if (_devModelView && _modelInfo.isNotEmpty)
            div(classes: 'notice notice-info', styles: Styles(raw: {'margin-bottom': '0'}), [
              Component.text(
                '[DEV] Active PU model: ${_modelInfo['name'] ?? '?'} '
                '(variant=${_modelInfo['key'] ?? '?'}, version='
                '${_modelInfo['version'] ?? '?'}, features='
                '${_modelInfo['feature_count'] ?? '?'}). '
                'Legacy vs experimental47 comparison: switch '
                'SITEWISE_PU_MODEL_VARIANT on the backend and regenerate.',
              ),
            ]),
          div(classes: 'notice', styles: Styles(raw: {'margin-bottom': '0'}), [
            Component.text(
              'Ranked from your saved requirements. Preference fit and the PU '
              'research association index are reported separately and are '
              'never merged into a success probability.',
            ),
          ]),
          _toolbar(),
          if (_error != null)
            div(classes: 'notice notice-warn', styles: Styles(raw: {'margin-bottom': '0'}), [
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
              final total = batch.results.length;
              final pageCount = (total + _pageSize - 1) ~/ _pageSize;
              // A saved batch can contain fewer items than the page in a
              // bookmarked URL. Clamp the rendered page without mutating data.
              final pageIndex = _pageIndex < pageCount
                  ? _pageIndex
                  : pageCount - 1;
              final start = pageIndex * _pageSize;
              final end = start + _pageSize < total
                  ? start + _pageSize
                  : total;
              final visibleResults = batch.results.sublist(start, end);

              return div(classes: 'stack', styles: Styles(raw: {'gap': '16px'}), [
                div(
                  classes: 'row',
                  styles: Styles(raw: {
                    'justify-content': 'space-between',
                    'gap': '8px',
                    'flex-wrap': 'wrap',
                    'color': '#475569',
                    'font-size': '13px',
                    'font-weight': '600',
                  }),
                  [
                    span([Component.text(
                      'Showing ${start + 1}–$end of $total recommendations',
                    )]),
                    span([Component.text('Page ${pageIndex + 1} of $pageCount')]),
                  ],
                ),
                for (final item in visibleResults)
                  _AiRecommendationCard(
                    item: item,
                    returnPage: pageIndex + 1,
                  ),
                if (pageCount > 1) _pagination(pageIndex, pageCount),
              ]);
            },
          ),
        ]),
    );
  }

  /// Accessible numbered pagination for the saved batch already in memory.
  /// No API call or recomputation occurs when changing pages.
  Component _pagination(int current, int pageCount) {
    final first = pageCount <= 5
        ? 0
        : current <= 2
            ? 0
            : current >= pageCount - 3
                ? pageCount - 5
                : current - 2;
    final last = first + 5 < pageCount ? first + 5 : pageCount;
    return nav(
      classes: 'actions-row',
      attributes: const {'aria-label': 'AI recommendation pages'},
      styles: Styles(raw: {
        'justify-content': 'center',
        'gap': '8px',
        'flex-wrap': 'wrap',
        'margin-top': '4px',
      }),
      [
        ActionButton(
          'Previous',
          variant: 'secondary',
          onClick: current == 0 ? null : () => _goToPage(current - 1),
        ),
        for (var page = first; page < last; page++)
          button(
            attributes: {
              'type': 'button',
              'aria-label': 'Page ${page + 1}',
              if (page == current) 'aria-current': 'page',
            },
            styles: Styles(raw: {
              'min-width': '40px',
              'min-height': '40px',
              'padding': '8px 12px',
              'border-radius': '10px',
              'border': page == current
                  ? '1px solid #1D4ED8'
                  : '1px solid #CBD5E1',
              'background': page == current ? '#1D4ED8' : '#FFFFFF',
              'color': page == current ? '#FFFFFF' : '#1E293B',
              'font-weight': '700',
              'cursor': 'pointer',
            }),
            events: events(onClick: () => _goToPage(page)),
            [Component.text('${page + 1}')],
          ),
        ActionButton(
          'Next',
          variant: 'secondary',
          onClick: current == pageCount - 1
              ? null
              : () => _goToPage(current + 1),
        ),
      ],
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
  final int returnPage;

  const _AiRecommendationCard({required this.item, required this.returnPage});

  @override
  Component build(BuildContext context) {
    final prop = item.property;
    final ref = item.listingRef;
    final prefPct = item.preferenceMatchScore == null
        ? null
        : item.preferenceMatchScore! * 100;
    final image = (prop.imageUrl ?? '').trim();
    final addressLine = [
      if (prop.address.isNotEmpty) prop.address,
      if (prop.city.isNotEmpty) prop.city,
      if (prop.state.isNotEmpty) prop.state,
    ].join(', ');
    // `confirmed_available` is the backend's own verdict. Anything else is
    // reported as unverified rather than dressed up as available.
    final confirmed = prop.verification['confirmed_available'] == true;
    final availabilityStatus =
        '${prop.verification['availability_status'] ?? 'UNKNOWN_NOT_VERIFIED'}';
    return section(classes: 'panel sw-rec', [
      // A real photo when the catalogue row has one. Rendered as a background
      // so a dead URL shows the placeholder colour instead of a broken-image
      // icon, and no client-side state is needed for the error case.
      div(
        classes: 'sw-rec__media${image.isEmpty ? ' is-empty' : ''}',
        styles: image.isEmpty ? null : Styles(raw: {'background-image': 'url("$image")'}),
        [
          if (image.isEmpty)
            span(classes: 'sw-rec__media-empty', [Component.text('No photo recorded')]),
        ],
      ),
      div(classes: 'sw-rec__body', [
        div(classes: 'panel-head panel-head--split', [
          h2([
            Component.text(prop.title.isEmpty ? prop.propertyId : prop.title),
          ]),
          span(classes: 'pill', [
            Component.text(item.rank == null ? '' : '#${item.rank}'),
          ]),
        ]),
        if (addressLine.isNotEmpty)
          p(classes: 'what', [Component.text(addressLine)]),
        div(classes: 'metrics-row', [
          _metric(
            'Monthly rental',
            prop.monthlyRentalMyr == null
                ? 'not recorded'
                : 'RM ${prop.monthlyRentalMyr!.toStringAsFixed(0)}',
          ),
          _metric(
            'Floor area',
            prop.builtUpSqft == null
                ? 'not recorded'
                : '${prop.builtUpSqft!.toStringAsFixed(0)} sq ft',
          ),
          _metric(
            'Property type',
            prop.propertyType.isEmpty ? 'not recorded' : prop.propertyType,
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
        p(classes: 'sw-rec__verify${confirmed ? ' is-verified' : ''}', [
          Component.text(
            confirmed
                ? 'Verified available'
                : 'Availability not verified ($availabilityStatus)',
          ),
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
          'View property insights',
          // The canonical RESEARCH id (EP-/MD-). Never the numeric listing id:
          // the insights and catalogue endpoints are keyed by the text id, so
          // passing the bigint here produced a 404 record-not-found page.
          href:
              '/entrepreneur/property-detail?id=${Uri.encodeQueryComponent(item.propertyId)}'
              '&result=${Uri.encodeQueryComponent(item.resultId)}',
          variant: 'primary',
        ),
        ActionLink(
          'Why recommended',
          href:
              '/entrepreneur/ai-recommendations?result=${item.resultId}&page=$returnPage',
          variant: 'secondary',
        ),
        ActionLink(
          'Assess this property',
          // The workspace reads `?id=`, not `?property=`. The previous query
          // key was silently ignored, so the page opened with no property.
          href:
              '/entrepreneur/assessment?id=${Uri.encodeQueryComponent(item.propertyId)}',
          variant: 'secondary',
        ),
        if (ref != null && ref.detailAvailable)
          ActionLink(
            'View commercial listing',
            // The verified NUMERIC listing id (fyp.rental_properties.id), read
            // by the approved+published-only explore detail endpoint. Only
            // rendered when the backend reports the listing is accessible.
            href: '/entrepreneur/listing?id=${ref.listingId}',
            variant: 'secondary',
          ),
      ]),
        if (ref != null && !ref.detailAvailable)
          p(classes: 'disclaimer', [
            Component.text(ref.detailNote ?? ''),
          ]),
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

  static String get _returnToResults {
    final page = int.tryParse(Uri.base.queryParameters['page'] ?? '1') ?? 1;
    return page <= 1
        ? '/entrepreneur/ai-recommendations'
        : '/entrepreneur/ai-recommendations?page=$page';
  }

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
            action: ActionLink(
              'Back to AI recommendations',
              href: _returnToResults,
              variant: 'primary',
            ),
          );
        }
        final e = snap.data!;
        return div(classes: 'stack', styles: Styles(raw: {'gap': '20px'}), [
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
                      componentLabel(entry.key),
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
                        '+ ${e.labelFor(f.feature)} '
                        '(${f.contribution.toStringAsFixed(4)})',
                      ),
                    ]),
                  for (final f in e.shap!.topNegative.take(4))
                    li([
                      Component.text(
                        '- ${e.labelFor(f.feature)} '
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
              ActionLink(
                'Open property insights',
                href:
                    '/entrepreneur/property-detail?id=${Uri.encodeQueryComponent(e.propertyId)}'
                    '&result=${Uri.encodeQueryComponent(e.resultId)}',
                variant: 'primary',
              ),
              ActionLink(
                'Back to AI recommendations',
                href: _returnToResults,
                variant: 'secondary',
              ),
            ]),
        ]);
      },
    );
  }
}
