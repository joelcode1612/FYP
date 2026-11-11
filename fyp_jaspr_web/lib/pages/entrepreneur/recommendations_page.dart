import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Entrepreneur discovery — **Recommendations**.
///
/// This page replaced the separate Explore destination (`data/navigation.dart`;
/// `/entrepreneur/explore` redirects here in `app.dart`). It carries browsing
/// *and* ranking in one surface:
///
///  * with no criteria it is a plain catalogue browse — never an empty
///    "set your preferences first" wall;
///  * with criteria the server ranks the eligible set and returns
///    requirement-level reasons, not a fabricated score.
///
/// Everything the list shows comes from `POST /api/v1/recommendations/search`:
/// the server filters, orders and pages. This component never sorts, never
/// slices a local copy, and never loads the whole catalogue.
///
/// ```text
/// .rec2              two-column shell
///   .rec2__main      filters · result count · ranked cards · load more
///   .rec2__side      sticky intelligence panel for the selected listing
/// ```
@client
class RecommendationsPage extends StatefulComponent {
  const RecommendationsPage({super.key, this.initialPropertyId});

  /// Legacy `?id=<catalogue id>` deep link (the retired Explore page used it to
  /// open with a unit already selected). Honoured only if that property is part
  /// of the first result page, so a stale id never blanks the panel.
  final String? initialPropertyId;

  @override
  State<RecommendationsPage> createState() => _RecommendationsPageState();
}

class _RecommendationsPageState extends State<RecommendationsPage> {
  // Filter draft. Kept local until "Find properties" so typing a budget does
  // not fire a request per keystroke — the server call is the expensive part.
  String _businessType = '';
  String _state = '';
  String _propertyType = '';
  String _budget = '';
  String _minSize = '';
  String _query = '';

  /// One initial search per page instance.
  bool _seeded = false;

  EntrepreneurNotifier get _notifier =>
      context.read(entrepreneurNotifierProvider.notifier);

  @override
  void initState() {
    super.initState();
    // Deferred: the notifier publishes synchronously and initState runs while
    // the tree is building.
    Future.microtask(() async {
      if (!mounted || _seeded) return;
      _seeded = true;
      final prefs = context.read(businessPreferencesProvider);
      await _notifier.searchRecommendations(request: _initialRequest(prefs));
      final wanted = component.initialPropertyId;
      if (!mounted || wanted == null || wanted.isEmpty) return;
      final state = context.read(entrepreneurNotifierProvider);
      if (state.ranked.any((row) => row.property.id == wanted)) {
        _notifier.selectRanked(wanted);
      }
    });
  }

  /// The first search.
  ///
  /// A brand-new account has no saved requirements. Deriving a request from
  /// the placeholder defaults would attach "within RM25,000" to every card as
  /// if the user had asked for it, so an unconfigured account gets a plain
  /// browse instead.
  RecommendationSearchRequest _initialRequest(BusinessPreferences prefs) {
    final configured =
        prefs.businessType.trim().isNotEmpty ||
        prefs.preferredLocation.trim().isNotEmpty ||
        prefs.preferredAreas.isNotEmpty;
    return configured
        ? RecommendationSearchRequest.fromPreferences(prefs)
        : const RecommendationSearchRequest();
  }

  /// Applies the draft filters and re-runs from page 1.
  void _apply() {
    _notifier.applyRecommendationRequest(
      RecommendationSearchRequest(
        businessType: _businessType.trim().isEmpty
            ? null
            : _businessType.trim(),
        preferredState: _state.isEmpty ? null : _state,
        propertyType: _propertyType.isEmpty ? null : _propertyType,
        maxRentalRm: double.tryParse(_budget.trim()),
        minSizeSqft: double.tryParse(_minSize.trim()),
        query: _query.trim().isEmpty ? null : _query.trim(),
        pageSize: 20,
      ),
    );
  }

  void _reset() {
    setState(() {
      _businessType = '';
      _state = '';
      _propertyType = '';
      _budget = '';
      _minSize = '';
      _query = '';
    });
    _notifier.applyRecommendationRequest(const RecommendationSearchRequest());
  }

  /// Saves/removes a property. A signed-in account persists server-side first
  /// and the shortlist only moves once the server accepted the change.
  Future<void> _toggleSaved(String id) async {
    final notifier = context.read(appNotifierProvider.notifier);
    if (!AppLocator.isSignedIn) {
      notifier.toggleSaved(id);
      return;
    }
    final savedNow = context.read(appNotifierProvider).saved.contains(id);
    final failure = await AppLocator.persistToggleSaved(
      id,
      wantSaved: !savedNow,
    );
    if (failure != null) return;
    notifier.toggleSaved(id);
  }

  @override
  Component build(BuildContext context) {
    final state = context.watch(entrepreneurNotifierProvider);
    final saved = context.watch(appNotifierProvider.select((app) => app.saved));
    final compared = context.watch(
      appNotifierProvider.select((app) => app.compared),
    );
    final available = _notifier.hasRecommendationSearch;

    if (!available && state.ranked.isEmpty) {
      return AppLayout(
        role: AppRole.entrepreneur,
        currentRoute: '/entrepreneur/recommendations',
        title: 'Recommendations',
        eyebrow: 'Find a space that fits your vision',
        subtitle: 'Ranked commercial properties for your business.',
        child: const EmptyState(
          title: 'Recommendation search is unavailable',
          body:
              'This build has no recommendation backend configured, so no '
              'ranking can be produced. Property details, saved properties and '
              'assessments are unaffected.',
        ),
      );
    }

    final selected = _selected(state);

    return AppLayout(
      role: AppRole.entrepreneur,
      currentRoute: '/entrepreneur/recommendations',
      title: 'Recommendations',
      eyebrow: 'Find a space that fits your vision',
      subtitle: _subtitle(state),
      actions: const [
        ActionLink(
          'Edit requirements',
          href: '/entrepreneur/preferences',
          variant: 'secondary',
        ),
      ],
      child: div(classes: 'rec2', [
        div(classes: 'rec2__main', [
          _filters(state),
          if (state.recommendationError != null)
            _errorBanner(state.recommendationError!),
          _resultHead(state),
          if (state.recommendationLoading)
            const _Loading()
          else if (state.ranked.isEmpty)
            _empty(state)
          else ...[
            div(classes: 'rec2__list', [
              for (final item in state.ranked)
                _card(item, saved, compared, item.id == state.selectedRankedId),
            ]),
            if (state.recommendationHasMore)
              div(classes: 'rec2__more', [
                ActionButton(
                  state.recommendationRefreshing ? 'Loading…' : 'Load more',
                  variant: 'secondary',
                  icon: 'expand_more',
                  onClick: state.recommendationRefreshing
                      ? null
                      : () => _notifier.loadMoreRecommendations(),
                ),
              ]),
          ],
          if (state.recommendationModel != null)
            p(classes: 'rec2__provenance', [
              Component.text(_provenance(state.recommendationModel!)),
            ]),
        ]),
        div(classes: 'rec2__side', [
          if (selected == null)
            const _PanelPlaceholder()
          else
            _insightPanel(selected, saved, compared),
        ]),
      ]),
    );
  }

  RankedProperty? _selected(EntrepreneurState state) {
    final id = state.selectedRankedId;
    if (id == null) return null;
    for (final item in state.ranked) {
      if (item.id == id) return item;
    }
    return null;
  }

  String _subtitle(EntrepreneurState state) {
    final total = state.recommendationTotal;
    final model = state.recommendationModel;
    final parts = <String>[
      if (total != null) '$total properties match your requirements',
      if (model != null) model.label,
    ];
    return parts.isEmpty
        ? 'Ranked commercial properties for your business.'
        : parts.join(' · ');
  }

  String _provenance(RecommendationModelStatus model) => model.available
      ? 'Scores come from the experimental preference-matching model '
            '(${model.version ?? 'unversioned'}). They measure agreement with '
            'your stated requirements, not the probability of business '
            'success.'
      : '${model.reason} Listings are ordered by how many of your requirements '
            'they meet, then by lower rent. This is not a model score.';

  // -- filters ---------------------------------------------------------------

  Component _filters(EntrepreneurState state) {
    final facets = state.recommendationFacets;
    return div(classes: 'rec2__filters', [
      div(classes: 'rec2__filters-grid', [
        _textField(
          caption: 'Business type',
          value: _businessType,
          placeholder: 'e.g. Specialty coffee',
          onInput: (v) => setState(() => _businessType = v),
        ),
        _textField(
          caption: 'Monthly budget (RM)',
          value: _budget,
          placeholder: 'e.g. 8000',
          onInput: (v) => setState(() => _budget = v),
        ),
        _textField(
          caption: 'Minimum size (sq ft)',
          value: _minSize,
          placeholder: 'e.g. 1200',
          onInput: (v) => setState(() => _minSize = v),
        ),
        _textField(
          caption: 'Search',
          value: _query,
          placeholder: 'Area, title or property id',
          onInput: (v) => setState(() => _query = v),
        ),
      ]),
      // Chips, not <select>: the values come from the catalogue itself, so an
      // option can never match zero rows. Counts are shown because they are
      // real.
      if (facets != null && facets.states.isNotEmpty)
        _chipRow(
          caption: 'Preferred state',
          options: facets.states,
          selected: _state,
          onPick: (v) => setState(() => _state = v),
        ),
      if (facets != null && facets.propertyTypes.isNotEmpty)
        _chipRow(
          caption: 'Property type',
          options: facets.propertyTypes,
          selected: _propertyType,
          onPick: (v) => setState(() => _propertyType = v),
        ),
      div(classes: 'rec2__filters-actions', [
        ActionButton(
          state.recommendationRefreshing ? 'Searching…' : 'Find properties',
          variant: 'primary',
          icon: 'search',
          onClick: state.recommendationRefreshing ? null : _apply,
        ),
        ActionButton('Clear', variant: 'secondary', onClick: _reset),
      ]),
    ]);
  }

  Component _chipRow({
    required String caption,
    required List<FacetOption> options,
    required String selected,
    required void Function(String) onPick,
  }) => div(classes: 'field', [
    span(classes: 'field__label', [Component.text(caption)]),
    div(classes: 'chips', [
      for (final option in [const FacetOption(value: ''), ...options])
        label(
          classes: option.value == selected ? 'checkpill is-on' : 'checkpill',
          [
            input(
              attributes: {
                'type': 'radio',
                'name': caption,
                if (option.value == selected) 'checked': '',
              },
              events: events(onChange: (_) => onPick(option.value)),
            ),
            span([
              Component.text(
                option.value.isEmpty
                    ? 'Any'
                    : '${option.value} (${option.total})',
              ),
            ]),
          ],
        ),
    ]),
  ]);

  Component _textField({
    required String caption,
    required String value,
    required String placeholder,
    required void Function(String) onInput,
  }) => label(classes: 'field', [
    span(classes: 'field__label', [Component.text(caption)]),
    input(
      attributes: {
        'type': 'text',
        'value': value,
        'placeholder': placeholder,
        'aria-label': caption,
      },
      events: events<String>(onInput: onInput),
    ),
  ]);

  // -- results ---------------------------------------------------------------

  Component _resultHead(EntrepreneurState state) {
    final total = state.recommendationTotal;
    final refreshing = state.recommendationRefreshing;
    return div(classes: 'rec2__head', [
      h2(classes: 'rec2__count', [
        Component.text(
          total == null
              ? 'Ranked properties'
              : '$total ${total == 1 ? 'property' : 'properties'}',
        ),
      ]),
      if (refreshing)
        span(classes: 'rec2__refreshing', [Component.text('Updating…')]),
    ]);
  }

  Component _errorBanner(String message) => div(classes: 'rec2__error', [
    Icon('error_outline', size: 'sm'),
    div(classes: 'rec2__error-body', [
      strong([Component.text('Could not load recommendations')]),
      span([Component.text(message)]),
    ]),
    ActionButton(
      'Retry',
      variant: 'secondary',
      onClick: () => _notifier.searchRecommendations(),
    ),
  ]);

  Component _empty(EntrepreneurState state) => EmptyState(
    title: state.recommendationRequest.isBrowseOnly
        ? 'No properties available'
        : 'No property matches these requirements',
    body: state.recommendationRequest.isBrowseOnly
        ? 'The catalogue returned no listings. That is a data condition, not a '
              'filter problem.'
        : 'Nothing in the catalogue satisfies every constraint. Widen the '
              'budget or reduce the minimum floor area and search again.',
    action: ActionButton(
      'Clear filters',
      variant: 'primary',
      onClick: _reset,
    ),
  );

  Component _card(
    RankedProperty item,
    Set<String> saved,
    Set<String> compared,
    bool selected,
  ) {
    final prop = item.property;
    final match = item.match;
    final isSaved = saved.contains(prop.id);
    final isCompared = compared.contains(prop.id);
    return article(classes: selected ? 'rec2-card is-selected' : 'rec2-card', [
      div(classes: 'rec2-card__media', [
        if ((prop.imageUrl ?? '').isNotEmpty)
          img(src: prop.imageUrl ?? '', alt: 'Photograph of ${prop.title}')
        else
          div(classes: 'rec2-card__media-empty', [
            Icon('image_not_supported', size: 'sm'),
            span([Component.text('No photo')]),
          ]),
        span(classes: 'rec2-card__rank', [Component.text('#${match.rank}')]),
      ]),
      div(classes: 'rec2-card__body', [
        h3(classes: 'rec2-card__title', [
          AppLink(
            to: '/entrepreneur/property-detail?id=${Uri.encodeComponent(prop.id)}',
            children: [Component.text(prop.title)],
          ),
        ]),
        p(classes: 'rec2-card__meta', [
          Component.text(
            [
              if (prop.city.isNotEmpty) prop.city,
              if (prop.state.isNotEmpty) prop.state,
              if (prop.propertyType.isNotEmpty) prop.propertyType,
            ].join(' · '),
          ),
        ]),
        div(classes: 'rec2-card__facts', [
          _fact('Rent', 'RM ${prop.rentalRm.toStringAsFixed(0)}/mo'),
          _fact('Floor area', '${prop.sizeSqft.toStringAsFixed(0)} sq ft'),
          if (item.suitabilityAvailable)
            _fact(
              'Research index',
              item.catalogSuitabilityScore!.toStringAsFixed(0),
            ),
        ]),
        if (match.matched.isNotEmpty || match.unmatched.isNotEmpty)
          div(classes: 'rec2-card__reasons', [
            for (final reason in match.matched.take(3))
              span(classes: 'rec2-chip is-met', [
                Icon('check', size: 'sm'),
                Component.text(reason.label),
              ]),
            for (final reason in match.unmatched.take(2))
              span(classes: 'rec2-chip is-unmet', [
                Icon('close', size: 'sm'),
                Component.text(reason.label),
              ]),
          ]),
        div(classes: 'rec2-card__actions', [
          ActionButton(
            'View insight',
            variant: selected ? 'primary' : 'secondary',
            icon: 'insights',
            onClick: () => _notifier.selectRanked(prop.id),
          ),
          ActionLink(
            'Details',
            href: '/entrepreneur/property-detail?id=${Uri.encodeComponent(prop.id)}',
            variant: 'secondary',
          ),
          ActionLink(
            'Assess',
            href: '/entrepreneur/assessment?id=${Uri.encodeComponent(prop.id)}',
            variant: 'secondary',
          ),
          ActionButton(
            isSaved ? 'Saved' : 'Save',
            variant: 'secondary',
            icon: isSaved ? 'bookmark' : 'bookmark_border',
            onClick: () => _toggleSaved(prop.id),
          ),
          ActionButton(
            isCompared ? 'In compare' : 'Compare',
            variant: 'secondary',
            icon: 'compare_arrows',
            onClick: () =>
                context.read(appNotifierProvider.notifier).toggleCompared(prop.id),
          ),
        ]),
      ]),
      div(classes: 'rec2-card__score', [
        strong([
          Component.text(
            match.verifiableCount == 0
                ? '—'
                : '${match.matchedCount}/${match.verifiableCount}',
          ),
        ]),
        span([
          Component.text(
            match.verifiableCount == 0 ? 'No criteria' : 'Requirements met',
          ),
        ]),
      ]),
    ]);
  }

  Component _fact(String label, String value) => div(classes: 'rec2-fact', [
    span(classes: 'rec2-fact__label', [Component.text(label)]),
    strong([Component.text(value)]),
  ]);

  // -- intelligence panel ----------------------------------------------------

  Component _insightPanel(
    RankedProperty item,
    Set<String> saved,
    Set<String> compared,
  ) {
    final prop = item.property;
    final match = item.match;
    return div(classes: 'rec2-panel', [
      span(classes: 'overline', [Component.text('Selected property')]),
      h2(classes: 'rec2-panel__title', [Component.text(prop.title)]),
      p(classes: 'rec2-panel__meta', [
        Component.text(
          [prop.address, prop.city, prop.state]
              .where((v) => v.isNotEmpty)
              .join(', '),
        ),
      ]),
      if ((prop.imageUrl ?? '').isNotEmpty)
        div(classes: 'rec2-panel__media', [
          img(src: prop.imageUrl ?? '', alt: 'Photograph of ${prop.title}'),
        ]),

      // Recommendation verdict — requirement-level, because there is no model
      // score to quote in this build.
      div(classes: 'rec2-panel__block', [
        span(classes: 'rec2-panel__label', [
          Component.text(
            match.available ? 'Recommendation match' : 'Requirement fit',
          ),
        ]),
        if (match.fitSummary != null)
          p(classes: 'rec2-panel__fit', [Component.text(match.fitSummary!)]),
        if (match.matched.isNotEmpty)
          _requirementList('Met', match.matched, 'is-met'),
        if (match.unmatched.isNotEmpty)
          _requirementList('Not met', match.unmatched, 'is-unmet'),
        if (match.unverified.isNotEmpty)
          _requirementList(
            'Cannot be verified from the catalogue',
            match.unverified,
            'is-unverified',
          ),
        if (match.matched.isEmpty &&
            match.unmatched.isEmpty &&
            match.unverified.isEmpty)
          p(classes: 'small', [
            Component.text(
              'No requirements were applied — this is a plain catalogue '
              'browse. Set your business requirements to rank by fit.',
            ),
          ]),
      ]),

      div(classes: 'rec2-panel__block', [
        span(classes: 'rec2-panel__label', [Component.text('Listing facts')]),
        _panelRow('Monthly rental', 'RM ${prop.rentalRm.toStringAsFixed(0)}'),
        _panelRow('Floor area', '${prop.sizeSqft.toStringAsFixed(0)} sq ft'),
        _panelRow('Property type', prop.propertyType),
        _panelRow(
          'Research index',
          item.suitabilityAvailable
              ? '${item.catalogSuitabilityScore!.toStringAsFixed(1)} / 100'
              : 'Not available',
        ),
      ]),

      // PU research is a SEPARATE model. It is never merged into the match
      // figure above, and an unavailable PU score is stated, not zeroed.
      div(classes: 'rec2-panel__block', [
        span(classes: 'rec2-panel__label', [
          Component.text('PU research association'),
        ]),
        p(classes: 'small', [
          Component.text(
            item.puAvailable == true
                ? 'PU association: ${item.puScore?.toStringAsFixed(1) ?? '—'} '
                      '(research index, not a success probability).'
                : 'The PU research model returned no association score for this '
                      'property. Open the explainable analysis to request it '
                      'explicitly — it is a separate research model and is '
                      'never folded into the match figure.',
          ),
        ]),
        ActionLink(
          'Open explainable analysis',
          href:
              '/entrepreneur/explanation?property=${Uri.encodeComponent(prop.id)}',
          variant: 'secondary',
        ),
      ]),

      div(classes: 'rec2-panel__actions', [
        ActionLink(
          'View property',
          href: '/entrepreneur/property-detail?id=${Uri.encodeComponent(prop.id)}',
          variant: 'primary',
        ),
        ActionLink(
          'Assess this property',
          href: '/entrepreneur/assessment?id=${Uri.encodeComponent(prop.id)}',
          variant: 'secondary',
        ),
        ActionLink(
          'Map & nearby',
          href: '/entrepreneur/map?id=${Uri.encodeComponent(prop.id)}',
          variant: 'secondary',
        ),
        ActionButton(
          saved.contains(prop.id) ? 'Saved' : 'Save',
          variant: 'secondary',
          icon: saved.contains(prop.id) ? 'bookmark' : 'bookmark_border',
          onClick: () => _toggleSaved(prop.id),
        ),
        ActionButton(
          compared.contains(prop.id) ? 'In compare' : 'Compare',
          variant: 'secondary',
          icon: 'compare_arrows',
          onClick: () =>
              context.read(appNotifierProvider.notifier).toggleCompared(prop.id),
        ),
      ]),
    ]);
  }

  Component _requirementList(
    String title,
    List<RequirementMatch> items,
    String toneClass,
  ) => div(classes: 'rec2-reqs', [
    span(classes: 'rec2-reqs__title', [Component.text(title)]),
    for (final item in items)
      div(classes: 'rec2-reqs__item $toneClass', [
        Icon(
          item.isMet
              ? 'check'
              : item.isUnmet
              ? 'close'
              : 'help',
          size: 'sm',
        ),
        span([Component.text(item.label)]),
      ]),
  ]);

  Component _panelRow(String label, String value) =>
      div(classes: 'rec2-panel__row', [
        span([Component.text(label)]),
        strong([Component.text(value.isEmpty ? 'Not recorded' : value)]),
      ]);
}

class _PanelPlaceholder extends StatelessComponent {
  const _PanelPlaceholder();

  @override
  Component build(BuildContext context) => div(classes: 'rec2-panel', [
    span(classes: 'overline', [Component.text('Location intelligence')]),
    p(classes: 'small', [
      Component.text(
        'Select a property to see its requirement matches, listing facts and '
        'research evidence.',
      ),
    ]),
  ]);
}

class _Loading extends StatelessComponent {
  const _Loading();

  @override
  Component build(BuildContext context) => div(classes: 'loading', [
    span(classes: 'spinner', []),
    Component.text('Ranking properties…'),
  ]);
}
