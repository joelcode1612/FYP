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
  // Filter DRAFT. Kept local until "Find properties" so typing a budget does
  // not fire a request per keystroke — the server call is the expensive part.
  // The APPLIED criteria live in the session-scoped entrepreneur state
  // (`state.recommendationRequest`); this draft is rehydrated from it on
  // every mount, so returning from a property detail restores the form.
  String _businessType = '';
  String _state = '';
  String _propertyType = '';
  String _minBudget = '';
  String _budget = '';
  String _minSize = '';
  String _maxSize = '';
  String _targetMarket = '';
  String _query = '';

  /// The active ordering. Held as the accepted server key, never a label, so a
  /// rename of the wording cannot silently change the request.
  String _sort = _sortBestMatch;

  static const _sortBestMatch = 'best_match';

  /// Used only when the facets call has not returned (or failed). The server
  /// sends the authoritative list with the facets; this keeps the control
  /// usable — and identical — before that arrives.
  static const _sortFallback = <String, String>{
    _sortBestMatch: 'Best requirement match',
    'rent_asc': 'Lowest monthly rent',
    'rent_desc': 'Highest monthly rent',
    'size_desc': 'Largest floor area',
    'size_asc': 'Smallest floor area',
    'pu_desc': 'Highest PU research index',
  };

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
      final current = context.read(entrepreneurNotifierProvider);
      // Returning within the same session: the session-scoped state still
      // holds the applied filters AND their results. Restore the draft from
      // the applied request — never re-seed from saved preferences, which
      // would silently overwrite what the entrepreneur applied.
      if (current.recommendationTotal != null) {
        setState(() => _syncDraft(current.recommendationRequest));
        return;
      }
      final prefs = context.read(businessPreferencesProvider);
      final request = _initialRequest(prefs);
      // The form shows what the first search actually applies (saved
      // requirements, or nothing) instead of a blank panel that disagrees
      // with the results.
      setState(() => _syncDraft(request));
      await _notifier.searchRecommendations(request: request);
      final wanted = component.initialPropertyId;
      if (!mounted || wanted == null || wanted.isEmpty) return;
      final state = context.read(entrepreneurNotifierProvider);
      if (state.ranked.any((row) => row.property.id == wanted)) {
        _notifier.selectRanked(wanted);
      }
    });
  }

  /// Draft <- applied. Called on mount and after any applied-state change
  /// that did not originate in the form (chip removal, reset).
  void _syncDraft(RecommendationSearchRequest request) {
    _businessType = request.businessType ?? '';
    _state = request.preferredState ?? '';
    _propertyType = request.propertyType ?? '';
    _minBudget = request.minRentalRm == null
        ? ''
        : request.minRentalRm!.toStringAsFixed(0);
    _budget = request.maxRentalRm == null
        ? ''
        : request.maxRentalRm!.toStringAsFixed(0);
    _minSize = request.minSizeSqft == null
        ? ''
        : request.minSizeSqft!.toStringAsFixed(0);
    _maxSize = request.maxSizeSqft == null
        ? ''
        : request.maxSizeSqft!.toStringAsFixed(0);
    _targetMarket = request.layoutPreferences.join(', ');
    _query = request.query ?? '';
    _sort = request.sort ?? _sortBestMatch;
  }

  /// Target market is the one requirement with no dedicated catalogue column,
  /// so it travels as the request's layout preferences — the same convention
  /// the preferences page uses. Commas separate several requirements.
  List<String> get _layoutPreferences => [
    for (final part in _targetMarket.split(','))
      if (part.trim().isNotEmpty) part.trim(),
  ];

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
        minRentalRm: double.tryParse(_minBudget.trim()),
        maxRentalRm: double.tryParse(_budget.trim()),
        minSizeSqft: double.tryParse(_minSize.trim()),
        maxSizeSqft: double.tryParse(_maxSize.trim()),
        layoutPreferences: _layoutPreferences,
        query: _query.trim().isEmpty ? null : _query.trim(),
        sort: _sort,
        pageSize: 20,
      ),
    );
  }

  /// Ordering is a view of the SAME result set, so it is committed the moment
  /// it changes instead of waiting for "Find properties". It is built from the
  /// APPLIED request, never the draft: changing the sort must not silently
  /// apply a budget the entrepreneur has typed but not submitted.
  void _applySort(String value) {
    final applied = context.read(entrepreneurNotifierProvider).recommendationRequest;
    if ((applied.sort ?? _sortBestMatch) == value) return;
    _notifier.applyRecommendationRequest(applied.copyWith(sort: value));
  }

  /// Commits a new APPLIED request originating outside the form (chip
  /// removal) and mirrors it into the draft so the form cannot disagree.
  void _applyRequest(RecommendationSearchRequest request) {
    setState(() => _syncDraft(request));
    _notifier.applyRecommendationRequest(request);
  }

  void _reset() {
    const defaults = RecommendationSearchRequest();
    setState(() => _syncDraft(defaults));
    _notifier.applyRecommendationRequest(defaults);
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
      child: div(classes: 'rec2', [
        div(classes: 'rec2__main', [
          _filters(state),
          _appliedFilters(state.recommendationRequest),
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
              Component.text(_provenance(state)),
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
    final parts = <String>[
      if (total != null) '$total properties match your requirements',
      _orderingSummary(state),
    ];
    return parts.join(' · ');
  }

  /// What the list is currently ordered by. The header must agree with the
  /// list: quoting "requirement-fit ordering" while the list is sorted by rent
  /// would be a false statement about the data.
  String _orderingSummary(EntrepreneurState state) {
    final sort = state.recommendationRequest.sort;
    final model = state.recommendationModel;
    if (sort == null || sort == _sortBestMatch) {
      return model?.label ?? 'Ranked commercial properties for your business.';
    }
    return 'Ordered by ${_sortLabel(state, sort).toLowerCase()}';
  }

  /// Label for an ordering key, preferring the server's own vocabulary.
  String _sortLabel(EntrepreneurState state, String key) {
    final fromServer = state.recommendationFacets?.sortOptions;
    if (fromServer != null && fromServer.containsKey(key)) {
      return fromServer[key]!;
    }
    return _sortFallback[key] ?? key;
  }

  Map<String, String> _sortOptions(EntrepreneurState state) {
    final fromServer = state.recommendationFacets?.sortOptions;
    return fromServer == null || fromServer.isEmpty
        ? _sortFallback
        : fromServer;
  }

  String _provenance(EntrepreneurState state) {
    final model = state.recommendationModel!;
    final sort = state.recommendationRequest.sort;
    if (sort != null && sort != _sortBestMatch) {
      return 'Ordered by ${_sortLabel(state, sort).toLowerCase()}. This only '
          're-sequences the same eligible properties — it does not change '
          'which properties qualify, and it is not a model score.';
    }
    return model.available
        ? 'Scores come from the experimental preference-matching model '
              '(${model.version ?? 'unversioned'}). They measure agreement with '
              'your stated requirements, not the probability of business '
              'success.'
        : '${model.reason} Listings are ordered by how many of your requirements '
              'they meet, then by lower rent. This is not a model score.';
  }

  // -- filters ---------------------------------------------------------------

  /// The APPLIED criteria as readable, individually removable chips.
  ///
  /// Built from `state.recommendationRequest` — the same request the server
  /// ranked — so the summary can never disagree with the results. Removing a
  /// chip commits a new applied request immediately (it is not a draft edit).
  Component _appliedFilters(RecommendationSearchRequest request) {
    final chips = <({String label, RecommendationSearchRequest next})>[
      if (request.preferredState != null)
        (
          label: request.preferredState!,
          next: request.copyWith(clearState: true),
        ),
      if (request.propertyType != null)
        (
          label: request.propertyType!,
          next: request.copyWith(clearPropertyType: true),
        ),
      if (request.minRentalRm != null || request.maxRentalRm != null)
        (
          label: _rentChipLabel(request),
          next: request.copyWith(clearRentRange: true),
        ),
      if (request.minSizeSqft != null || request.maxSizeSqft != null)
        (
          label: _sizeChipLabel(request),
          next: request.copyWith(clearSizeRange: true),
        ),
      if (request.businessType != null)
        (
          label: request.businessType!,
          next: request.copyWith(clearBusinessType: true),
        ),
      if (request.query != null)
        (
          label: '“${request.query}”',
          next: request.copyWith(clearQuery: true),
        ),
      if (request.layoutPreferences.isNotEmpty)
        (
          label: request.layoutPreferences.length == 1
              ? request.layoutPreferences.first
              : '${request.layoutPreferences.length} layout preferences',
          next: request.copyWith(layoutPreferences: const []),
        ),
    ];
    if (chips.isEmpty) return Component.fragment([]);
    return div(classes: 'rec2__applied', [
      span(classes: 'rec2__applied-label', [
        Component.text('Applied filters:'),
      ]),
      for (final chip in chips)
        span(classes: 'chip rec2__chip', [
          Component.text(chip.label),
          button(
            classes: 'rec2__chip-remove',
            attributes: {
              'type': 'button',
              'aria-label': 'Remove filter ${chip.label}',
            },
            events: events(onClick: () => _applyRequest(chip.next)),
            [Component.text('×')],
          ),
        ]),
      AppLink(
        to: '#rec2-filters',
        classes: 'rec2__edit-filters',
        children: [Component.text('Edit filters')],
      ),
    ]);
  }

  static String _sizeChipLabel(RecommendationSearchRequest request) {
    final min = request.minSizeSqft;
    final max = request.maxSizeSqft;
    String n(double value) => value.toStringAsFixed(0);
    if (min != null && max != null) return '${n(min)}–${n(max)} sq ft';
    if (min != null) return '${n(min)}+ sq ft';
    return 'Up to ${n(max!)} sq ft';
  }

  static String _rentChipLabel(RecommendationSearchRequest request) {
    final min = request.minRentalRm;
    final max = request.maxRentalRm;
    String n(double value) => value.toStringAsFixed(0);
    if (min != null && max != null) return 'RM ${n(min)}–${n(max)}';
    if (min != null) return 'RM ${n(min)}+';
    return 'RM ${n(max!)} max';
  }

  Component _filters(EntrepreneurState state) {
    final facets = state.recommendationFacets;
    return div(
      classes: 'rec2__filters',
      attributes: const {'id': 'rec2-filters'},
      [
        div(classes: 'rec2__filters-grid', [
          _textField(
            caption: 'Business type',
            value: _businessType,
            placeholder: 'e.g. Specialty coffee',
            onInput: (v) => setState(() => _businessType = v),
          ),
          _textField(
            caption: 'Min monthly rent (RM)',
            value: _minBudget,
            placeholder: 'e.g. 3000',
            onInput: (v) => setState(() => _minBudget = v),
          ),
          _textField(
            caption: 'Max monthly rent (RM)',
            value: _budget,
            placeholder: 'e.g. 8000',
            onInput: (v) => setState(() => _budget = v),
          ),
          _textField(
            caption: 'Minimum size (sq ft)',
            value: _minSize,
            placeholder: 'e.g. 800',
            onInput: (v) => setState(() => _minSize = v),
          ),
          _textField(
            caption: 'Maximum size (sq ft)',
            value: _maxSize,
            placeholder: 'e.g. 1800',
            onInput: (v) => setState(() => _maxSize = v),
          ),
          _textField(
            caption: 'Target market',
            value: _targetMarket,
            placeholder: 'e.g. Office workers, students',
            onInput: (v) => setState(() => _targetMarket = v),
          ),
          _sortField(_sortOptions(state)),
          _textField(
            caption: 'Search',
            value: _query,
            placeholder: 'Area, title or property id',
            onInput: (v) => setState(() => _query = v),
          ),
        ]),
        // Chips, not <select>: the values come from the catalogue itself, so
        // an option can never match zero rows. Counts are shown because they
        // are real.
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
      ],
    );
  }

  /// Ordering control. Applied on change rather than on "Find properties":
  /// re-sequencing the same eligible set is not a filter change, and a sort
  /// that appears to do nothing until another button is pressed reads as
  /// broken.
  ///
  /// The labels are sentences ("Best requirement match"), so the control is
  /// given two grid tracks — one 160px track truncates every option.
  Component _sortField(Map<String, String> options) =>
      label(classes: 'field rec2__field--wide', [
        span(classes: 'field__label', [Component.text('Sort by')]),
        select(
          attributes: {'aria-label': 'Sort by', 'id': 'rec2-sort'},
          events: events<List<String>>(
            onInput: (values) {
              final value = values.isEmpty ? '' : values.first;
              if (value.isEmpty || value == _sort) return;
              setState(() => _sort = value);
              _applySort(value);
            },
          ),
          [
            for (final entry in options.entries)
              option(
                value: entry.key,
                attributes: _sort == entry.key ? {'selected': ''} : null,
                [Component.text(entry.value)],
              ),
          ],
        ),
      ]);

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
    return div(classes: 'stack', [
      div(classes: 'rec2__head', [
        h2(classes: 'rec2__count', [
          Component.text(
            total == null
                ? 'Ranked properties'
                : '$total ${total == 1 ? 'property' : 'properties'}',
          ),
        ]),
        if (refreshing)
          span(classes: 'rec2__refreshing', [Component.text('Updating…')]),
      ]),
      // The target is at least three, but the minimum is never manufactured:
      // when fewer properties qualify, say so and offer the filter editor.
      if (total != null && total > 0 && total < 3)
        div(classes: 'rec2__insufficient', [
          Icon('info_outline', size: 'sm'),
          span(classes: 'grow', [
            Component.text(
              'Only $total ${total == 1 ? 'property matches' : 'properties match'} '
              'your current criteria and '
              '${total == 1 ? 'has a PU score' : 'have PU scores'} above 50.',
            ),
          ]),
          AppLink(
            to: '#rec2-filters',
            classes: 'rec2__edit-filters',
            children: [Component.text('Edit filters')],
          ),
        ]),
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
        ? 'No PU-eligible properties'
        : 'No property matches these requirements',
    body: state.recommendationRequest.isBrowseOnly
        ? 'No property in the catalogue has a PU research score above 50, so '
              'there is nothing eligible to recommend. That is a data '
              'condition, not a filter problem.'
        : 'Nothing in the catalogue satisfies every constraint AND has a PU '
              'score above 50. Widen the budget or reduce the minimum floor '
              'area and search again.',
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
          if (item.puAvailable == true && item.puScore != null)
            _fact('PU score', item.puScore!.toStringAsFixed(0))
          else if (item.suitabilityAvailable)
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

      div(classes: 'rec2-panel__block', [
        span(classes: 'rec2-panel__label', [
          Component.text('PU research association'),
        ]),
        p(classes: 'small', [
          Component.text(
            item.puAvailable == true
                ? 'PU score: ${item.puScore?.toStringAsFixed(1) ?? '—'} / 100 '
                      '— the research association index (not a success '
                      'probability). Every listed recommendation exceeds 50.'
                : 'No PU score is stored for this property, so it cannot pass '
                      'the eligibility threshold and is not recommended. The '
                      'PU model is a separate research model and is never '
                      'folded into the match figure.',
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
