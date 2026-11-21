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

/// One sentence describing the entrepreneur's OWN category match.
///
/// The model's highest class is reported only as a comparison. Leading with it
/// would silently replace the entrepreneur's selection — a Café search must
/// read as a Café result even where Restaurant scores higher.
String _categorySentence(CategoryEvidence category) {
  final selected = category.selectedCategory;
  final top = category.topCategory ?? '—';
  final topScore = category.topScore?.toStringAsFixed(2) ?? '—';
  if (selected == null) {
    return 'Closest observed F&B pattern: $top ($topScore on a 0–1 resemblance '
        'index). Choose your business type to see your own match.';
  }
  final own = '${selected.businessType} scores '
      '${selected.score.toStringAsFixed(2)} on a 0–1 resemblance index'
      '${selected.rank > 0 ? ' and ranks #${selected.rank} of 4' : ''}';
  final comparison = selected.businessType == top
      ? " — also the model's closest observed pattern here"
      : "; the model's closest observed pattern here is $top ($topScore)";
  return 'Your selected type $own$comparison. This is exploratory resemblance, '
      'not a success probability.';
}

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

  /// `&businessType=<selection>` for links that must keep the entrepreneur's
  /// chosen business type. Empty when nothing is selected, so the destination
  /// never receives a blank parameter.
  String get _businessTypeQuery {
    final selected = _businessType.trim();
    return selected.isEmpty
        ? ''
        : '&businessType=${Uri.encodeQueryComponent(selected)}';
  }
  String _state = '';
  String _propertyType = '';
  String _area = '';

  /// The chosen budget and floor-area intervals, held as BOUNDS rather than as
  /// a position in the option list. A re-count re-prices the dropdown but can
  /// never move the selection, and an interval a saved preference supplied —
  /// which the generated buckets may never offer — stays selectable with its
  /// own count. A range with no bounds at all is "Any".
  FacetRange _budget = const FacetRange();
  FacetRange _size = const FacetRange();
  String _targetMarket = '';
  String _query = '';

  /// The active ordering. Held as the accepted server key, never a label, so a
  /// rename of the wording cannot silently change the request.
  String _sort = _sortBestMatch;

  static const _sortBestMatch = 'best_match';

  // -- contextual filter options ---------------------------------------------
  //
  // Draft-level view data, deliberately not in the session state: these counts
  // answer "what would my OTHER selections still leave if I chose this?", which
  // only makes sense for what is being selected right now, before any search
  // has run. The applied results and the vocabulary the session fetched stay in
  // `state.recommendationFacets`.

  /// Options priced for the current draft.
  RecommendationFacets? _options;

  /// A re-count is scheduled or in flight, so the numbers on screen are about
  /// to move.
  bool _optionsBusy = false;

  /// The last re-count failed. The counts then describe the PREVIOUS
  /// selections, and the form says so instead of presenting them as the
  /// availability of what is currently chosen.
  bool _optionsStale = false;

  /// Each re-count takes a number and a response that no longer matches is
  /// dropped: a slow answer about filters the entrepreneur has already changed
  /// must never overwrite the newer choices.
  int _optionsSeq = 0;

  /// Coalesces keystrokes — otherwise every character typed asks the database
  /// to re-price the whole eligible set.
  static const _optionsDelay = Duration(milliseconds: 400);

  Timer? _optionsTimer;

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

  // Reuse the business-category and target-customer vocabulary used by
  // existing SiteWise preferences and the assessment questionnaire.
  static const _businessTypeOptions = <String>[
    'Cafe / Coffee Shop',
    'Restaurant',
    'Bakery / Dessert Shop',
    'Fast Food / Quick Service',
    'Beverage Shop / Kiosk',
    'Other F&B',
  ];

  static const _targetMarketOptions = <String>[
    'Nearby Residents',
    'Office Workers',
    'Students',
    'Commuters',
    'General Public',
  ];

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
        final applied = current.recommendationRequest;
        // A session may still carry results from the build that scoped this
        // page to managed listings. That filter no longer exists in the UI, so
        // leaving it set would strand the page on "0 properties" with no way
        // to clear it. Re-run once, unscoped.
        if (applied.managedOnly) {
          final restored = applied.copyWith(managedOnly: false);
          setState(() => _syncDraft(restored));
          _notifier.applyRecommendationRequest(restored);
          _priceDraft();
          return;
        }
        setState(() => _syncDraft(applied));
        _priceDraft();
        return;
      }
      final prefs = context.read(businessPreferencesProvider);
      final request = _initialRequest(prefs);
      // The form shows what the first search actually applies (saved
      // requirements, or nothing) instead of a blank panel that disagrees
      // with the results.
      setState(() => _syncDraft(request));
      await _notifier.searchRecommendations(request: request);
      _priceDraft();
      if (!mounted) return;
      final wanted = component.initialPropertyId;
      if (wanted == null || wanted.isEmpty) return;
      final state = context.read(entrepreneurNotifierProvider);
      if (state.ranked.any((row) => row.property.id == wanted)) {
        _notifier.selectRanked(wanted);
      }
    });
  }

  @override
  void dispose() {
    _optionsTimer?.cancel();
    super.dispose();
  }

  /// Draft <- applied. Called on mount and after any applied-state change
  /// that did not originate in the form (chip removal, reset).
  void _syncDraft(RecommendationSearchRequest request) {
    _businessType = request.businessType ?? '';
    _state = request.preferredState ?? '';
    _propertyType = request.propertyType ?? '';
    _area = request.preferredArea ?? '';
    _budget = FacetRange(low: request.minRentalRm, high: request.maxRentalRm);
    _size = FacetRange(low: request.minSizeSqft, high: request.maxSizeSqft);
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
    // Management scoping stays OFF here. The research catalogue this page
    // ranks is `verification_status='pending'`, and the manager mapping is
    // built only from approved+published operational listings, so scoping the
    // search to managers matches zero of the 290 PU-eligible properties.
    return configured
        ? RecommendationSearchRequest.fromPreferences(prefs)
        : const RecommendationSearchRequest();
  }

  /// The draft as a request: what a re-count prices and what "Find properties"
  /// sends. One builder for both, so the options on screen can never describe
  /// a different combination from the one the button would search.
  RecommendationSearchRequest _draftRequest() => RecommendationSearchRequest(
    businessType: _businessType.trim().isEmpty
        ? null
        : _businessType.trim(),
    preferredState: _state.isEmpty ? null : _state,
    preferredArea: _area.trim().isEmpty ? null : _area.trim(),
    minRentalRm: _budget.low,
    maxRentalRm: _budget.high,
    minSizeSqft: _size.low,
    maxSizeSqft: _size.high,
    propertyType: _propertyType.isEmpty ? null : _propertyType,
    layoutPreferences: _layoutPreferences,
    query: _query.trim().isEmpty ? null : _query.trim(),
    sort: _sort,
    pageSize: 20,
  );

  /// Applies the draft filters and re-runs from page 1.
  void _apply() {
    _notifier.applyRecommendationRequest(_draftRequest());
  }

  // -- contextual re-counting ------------------------------------------------
  //
  // Every input change re-prices every OTHER input, which is what makes the
  // form interconnected instead of a set of independent dropdowns. The counts
  // come from the same PU-gated population the search ranks — never from the
  // cards currently on screen — and the ranking itself still only runs when
  // the entrepreneur presses "Find properties".

  /// The options the form shows: the ones priced for this draft, or before the
  /// first re-count lands the vocabulary the session already holds.
  RecommendationFacets? _effectiveOptions(EntrepreneurState state) =>
      _options ?? state.recommendationFacets;

  /// Prices the dropdowns for the draft as it stands, when the draft actually
  /// constrains something.
  ///
  /// With nothing selected the session's catalogue-wide facets already ARE the
  /// contextual answer, so a filtered page costs one query and an unfiltered
  /// one costs none.
  void _priceDraft() {
    if (_draftRequest().facetsQuery.isEmpty) return;
    _refreshOptions(immediate: true);
  }

  /// Called after any draft edit. [key] is the field the entrepreneur touched:
  /// the server says which fields narrow the eligible set, and only those are
  /// worth re-counting. Selecting a discrete option re-prices immediately;
  /// typing is coalesced.
  void _onDraftChanged({String key = '', bool immediate = false}) {
    if (key.isNotEmpty &&
        _options != null &&
        _options!.roleOf(key) != FilterRole.hardFilter) {
      return;
    }
    _refreshOptions(immediate: immediate);
  }

  void _refreshOptions({bool immediate = false}) {
    if (!mounted || !_notifier.hasRecommendationSearch) return;
    _optionsTimer?.cancel();
    final seq = ++_optionsSeq;
    final request = _draftRequest();
    setState(() => _optionsBusy = true);
    if (immediate) {
      unawaited(_loadOptions(request, seq));
      return;
    }
    _optionsTimer = Timer(_optionsDelay, () => _loadOptions(request, seq));
  }

  Future<void> _loadOptions(
    RecommendationSearchRequest request,
    int seq,
  ) async {
    RecommendationFacets? priced;
    var failed = false;
    try {
      priced = await AppLocator.recommendationSearchRepo.facets(request);
    } on Object {
      // The previous counts stay on screen with a note; a dropdown that
      // empties itself on a network hiccup reads as "nothing is available".
      failed = true;
    }
    if (seq != _optionsSeq || !mounted) return;
    setState(() {
      _optionsBusy = false;
      _optionsStale = failed;
      if (priced != null) _options = priced;
    });
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
    _priceDraft();
    _notifier.applyRecommendationRequest(request);
  }

  void _reset() {
    const defaults = RecommendationSearchRequest();
    setState(() => _syncDraft(defaults));
    _refreshOptions(immediate: true);
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
          _appliedFilters(state),
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
    if (model.isLivePuAssociation) {
      // The expanded 64-feature variant: eligibility and tie-breaks come from
      // LIVE PU inference, not from the stored research index.
      return '${model.reason} The PU input is a research association index — '
          'not a probability of business success — and a property whose '
          'measured features are unavailable is excluded rather than guessed. '
          'Business-type resemblance is shown separately on each card.';
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
  Component _appliedFilters(EntrepreneurState state) {
    final request = state.recommendationRequest;
    final facets = _effectiveOptions(state);
    // A preference that cannot remove a property is never shown as though it
    // had: the server says which inputs filter, and the chip carries that.
    String qualifier(String key, String whenUnverified) =>
        facets == null || facets.roleOf(key) == FilterRole.hardFilter
        ? ''
        : (facets.roleOf(key) == FilterRole.rankingOnly
              ? ' · ordering only'
              : whenUnverified);
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
      if (request.preferredArea != null)
        (
          label: request.preferredArea!,
          next: request.copyWith(clearArea: true),
        ),
      if (request.businessType != null)
        (
          label: '${request.businessType}${qualifier('business_type', '')}',
          next: request.copyWith(clearBusinessType: true),
        ),
      if (request.query != null)
        (
          label: '“${request.query}”',
          next: request.copyWith(clearQuery: true),
        ),
      if (request.layoutPreferences.isNotEmpty)
        (
          label:
              '${request.layoutPreferences.length == 1 ? request.layoutPreferences.first : '${request.layoutPreferences.length} layout preferences'}'
              '${qualifier('target_market', ' · cannot be verified')}',
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
    final facets = _effectiveOptions(state);
    return div(
      classes: 'rec2__filters',
      attributes: const {'id': 'rec2-filters'},
      [
        div(classes: 'rec2__filters-grid', [
          _comboField(
            caption: 'Business type',
            fieldId: 'rec2-business-type',
            value: _businessType,
            emptyLabel: 'Any business type',
            options: _businessTypeOptions,
            hint: _roleHint(facets, 'business_type'),
            onChanged: (v) {
              setState(() => _businessType = v);
              _onDraftChanged(key: 'business_type');
            },
          ),
          // One dropdown replaces the old min/max text boxes. Its intervals
          // are generated from the listings the OTHER selections leave, so the
          // catalogue never offers a band with nothing in it, and nothing is
          // hardcoded: choosing a band sends exactly the `min_rental_rm` /
          // `max_rental_rm` pair it was counted from.
          _rangeField(
            caption: 'Monthly rental budget',
            fieldId: 'rec2-rental-budget',
            anyLabel: 'Any available budget',
            money: true,
            ranges: facets?.rentalRanges ?? const [],
            unboundedTotal: facets?.rentalUnboundedTotal ?? -1,
            selected: facets?.selectedRentalRange,
            draft: _budget,
            priced: facets != null,
            onPick: (range) {
              setState(() => _budget = range);
              _onDraftChanged(key: 'rental_budget', immediate: true);
            },
          ),
          _rangeField(
            caption: 'Preferred property size',
            fieldId: 'rec2-property-size',
            anyLabel: 'Any property size',
            money: false,
            ranges: facets?.sizeRanges ?? const [],
            unboundedTotal: facets?.sizeUnboundedTotal ?? -1,
            selected: facets?.selectedSizeRange,
            draft: _size,
            priced: facets != null,
            onPick: (range) {
              setState(() => _size = range);
              _onDraftChanged(key: 'property_size', immediate: true);
            },
          ),
          _textField(
            caption: 'Preferred area',
            value: _area,
            placeholder: 'e.g. Petaling Jaya',
            onInput: (v) {
              setState(() => _area = v);
              _onDraftChanged(key: 'preferred_area');
            },
          ),
          _comboField(
            caption: 'Target market',
            fieldId: 'rec2-target-market',
            value: _targetMarket,
            emptyLabel: 'Any target market',
            options: _targetMarketOptions,
            hint: _roleHint(facets, 'target_market'),
            onChanged: (v) {
              setState(() => _targetMarket = v);
              _onDraftChanged(key: 'target_market');
            },
          ),
          _sortField(_sortOptions(state)),
          _textField(
            caption: 'Search',
            value: _query,
            placeholder: 'Area, title or property id',
            onInput: (v) {
              setState(() => _query = v);
              _onDraftChanged(key: 'query');
            },
          ),
        ]),
        // Chips, not <select>: the values come from the catalogue itself, so
        // an option can never match zero rows. Counts are shown because they
        // are real, and they are the counts the OTHER selections leave.
        if (facets != null && facets.states.isNotEmpty)
          _chipRow(
            caption: 'Preferred state',
            options: facets.states,
            selected: _state,
            onPick: (v) {
              setState(() => _state = v);
              _onDraftChanged(key: 'preferred_state', immediate: true);
            },
          ),
        if (facets != null && facets.propertyTypes.isNotEmpty)
          _chipRow(
            caption: 'Property type',
            options: facets.propertyTypes,
            selected: _propertyType,
            onPick: (v) {
              setState(() => _propertyType = v);
              _onDraftChanged(key: 'property_type', immediate: true);
            },
          ),
        if (facets?.matchingTotal != null) _optionsSummary(facets!),
        // No management-scoping toggle: see `_initialRequest` for why the
        // catalogue search must not be restricted to assigned listings.
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

  /// The server's own words for an input that does NOT narrow the eligible
  /// set, so a ranking preference can never read as an eligibility filter.
  /// A hard filter needs no note, and nothing is claimed before the
  /// vocabulary has arrived.
  String _roleHint(RecommendationFacets? facets, String key) {
    if (facets == null) return '';
    if (facets.roleOf(key) == FilterRole.hardFilter) return '';
    final effect = facets.effectOf(key);
    return effect.isEmpty ? 'Does not remove properties.' : effect;
  }

  /// The live availability of the DRAFT, and when it is thin or empty the
  /// single filter that would restore the most listings.
  ///
  /// Nothing relaxes itself: the alternatives carry real counts and releasing
  /// one is a button the entrepreneur presses. Every other selection stays.
  Component _optionsSummary(RecommendationFacets facets) {
    final matching = facets.matchingTotal ?? 0;
    final alternatives = facets.relaxations;
    return div(classes: 'rec2__available-wrap', [
      div(classes: 'rec2__available', [
        Icon(matching == 0 ? 'filter_alt_off' : 'filter_alt', size: 'sm'),
        span(classes: 'grow', [
          Component.text(
            '$matching of ${facets.universeTotal} eligible '
            '${facets.universeTotal == 1 ? 'property' : 'properties'} '
            'match these filters',
          ),
        ]),
        if (_optionsBusy)
          span(classes: 'rec2__refreshing', [
            Component.text('Updating options…'),
          ])
        else if (_optionsStale)
          span(classes: 'rec2__refreshing', [
            Component.text('Could not re-count — numbers are from your '
                'previous selection.'),
          ]),
      ]),
      if (matching > 0 && matching < 3 && alternatives.isNotEmpty)
        _alternatives(
          'Only $matching ${matching == 1 ? 'property' : 'properties'} '
              'survive every filter you have set. Releasing one of these '
              'brings more back:',
          alternatives,
        ),
      if (matching == 0)
        _alternatives(
          alternatives.isEmpty
              ? 'No property in the catalogue is PU-eligible, so there is '
                    'nothing for these filters to narrow. That is a data '
                    'condition, not a filter problem.'
              : 'Nothing satisfies every filter together — each one on its own '
                    'still leaves properties. Releasing one of these is what '
                    'matches again:',
          alternatives,
        ),
    ]);
  }

  Component _alternatives(
    String message,
    List<FilterRelaxation> alternatives,
  ) => div(classes: 'rec2__conflicts', [
    p(classes: 'rec2__conflicts-head', [Component.text(message)]),
    if (alternatives.isNotEmpty)
      div(classes: 'rec2__conflicts-list', [
        for (final option in alternatives)
          ActionButton(
            option.total == 0
                ? '${option.label} — still nothing'
                : '${option.label} → ${option.total} '
                      '${option.total == 1 ? 'property' : 'properties'}',
            variant: 'secondary',
            icon: 'filter_alt_off',
            onClick: () => _release(option.field),
          ),
      ]),
  ]);

  /// Releases ONE filter, explicitly. The rest of what the entrepreneur chose
  /// is kept, and the form re-prices itself around the change.
  void _release(String fieldKey) {
    setState(() {
      switch (fieldKey) {
        case 'preferred_state':
          _state = '';
        case 'property_type':
          _propertyType = '';
        case 'rental_budget':
          _budget = const FacetRange();
        case 'property_size':
          _size = const FacetRange();
        case 'preferred_area':
          _area = '';
        case 'query':
          _query = '';
      }
    });
    _refreshOptions(immediate: true);
  }

  /// One dropdown of server-generated intervals.
  ///
  /// Bounds are observed listing values, so consecutive options neither
  /// overlap nor leave a priced listing outside every band, and the count is
  /// exactly what sending that pair to the search returns. The draft's own
  /// interval is always on the list — including when no generated band
  /// offers it (a saved preference) or when its re-count has not landed yet,
  /// which reads as "counting…" rather than a number that might be wrong.
  Component _rangeField({
    required String caption,
    required String fieldId,
    required String anyLabel,
    required bool money,
    required List<FacetRange> ranges,
    required int unboundedTotal,
    required FacetRange? selected,
    required FacetRange draft,
    required bool priced,
    required void Function(FacetRange) onPick,
  }) {
    final held = ranges.any((r) => r.matches(draft.low, draft.high));
    final choices = <FacetRange>[
      FacetRange(label: anyLabel, total: unboundedTotal),
      if (!draft.matches(null, null) && !held)
        selected != null && selected.matches(draft.low, draft.high)
            ? selected
            : FacetRange(
                low: draft.low,
                high: draft.high,
                total: -1,
                label: _pendingRangeLabel(money, draft.low, draft.high),
              ),
      ...ranges,
    ];
    final current = _rangeKey(draft);
    return label(classes: 'field', [
      span(classes: 'field__label', [Component.text(caption)]),
      select(
        attributes: {'aria-label': caption, 'id': fieldId, 'name': fieldId},
        events: events<List<String>>(
          onInput: (values) {
            final key = values.isEmpty ? _rangeKey(const FacetRange()) : values.first;
            if (key == current) return;
            onPick(
              choices.firstWhere(
                (c) => _rangeKey(c) == key,
                orElse: () => const FacetRange(),
              ),
            );
          },
        ),
        [
          for (final choice in choices)
            option(
              value: _rangeKey(choice),
              attributes: _rangeKey(choice) == current
                  ? const {'selected': ''}
                  : null,
              [Component.text(_rangeText(choice, money, priced: priced))],
            ),
        ],
      ),
    ]);
  }

  /// The interval's identity: its two bounds, never its position in a list
  /// that a re-count is free to reorder.
  static String _rangeKey(FacetRange range) =>
      '${range.low?.toStringAsFixed(2) ?? ''}|'
      '${range.high?.toStringAsFixed(2) ?? ''}';

  static String _rangeText(
    FacetRange range,
    bool money, {
    required bool priced,
  }) {
    final label = range.label.isEmpty
        ? (money ? 'Any available budget' : 'Any property size')
        : range.label;
    if (range.total < 0) return '$label (counting…)';
    if (!priced) return label;
    return '$label (${range.total})';
  }

  /// Wording for an interval whose re-count has not arrived. The server
  /// supplies every label it has priced; this only covers the window between a
  /// click and its response.
  static String _pendingRangeLabel(
    bool money,
    double? low,
    double? high,
  ) {
    String amount(double value) => money
        ? 'RM ${value.toStringAsFixed(0)}'
        : '${value.toStringAsFixed(0)} sq ft';
    if (low != null && high != null) return '${amount(low)} – ${amount(high)}';
    if (low != null) return 'From ${amount(low)}';
    if (high != null) return 'Up to ${amount(high)}';
    return 'Selected range';
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

  /// Editable combobox: a text input backed by a `<datalist>` of suggestions.
  ///
  /// A strict `<select>` cannot express a value outside its option list, but
  /// both of these fields legitimately can: target market is a comma-separated
  /// list of requirements, and older saved searches may hold custom business
  /// types. Choosing a suggestion or typing a custom value both fire `input`,
  /// so one handler covers both paths.
  Component _comboField({
    required String caption,
    required String fieldId,
    required String value,
    required String emptyLabel,
    required List<String> options,
    required void Function(String) onChanged,
    String hint = '',
  }) {
    final listId = '$fieldId-options';
    return label(classes: 'field', [
      span(classes: 'field__label', [Component.text(caption)]),
      input(
        id: fieldId,
        key: ValueKey(fieldId),
        attributes: {
          'type': 'text',
          'value': value,
          'placeholder': emptyLabel,
          'list': listId,
          'autocomplete': 'off',
          'name': fieldId,
          'aria-label': caption,
        },
        events: events<String>(onInput: onChanged),
      ),
      if (hint.isNotEmpty) span(classes: 'hint', [Component.text(hint)]),
      datalist(
        [
          // Keep an older custom value selectable until the field is changed,
          // so rehydrating an applied search cannot silently narrow it.
          if (value.isNotEmpty && !options.contains(value))
            option([Component.text(value)], value: value),
          for (final item in options)
            option([Component.text(item)], value: item),
        ],
        id: listId,
      ),
    ]);
  }

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
              'Only $total ${total == 1 ? 'property matches' : 'properties match'}'
              ' your current criteria and '
              '${total == 1 ? 'has' : 'have'} PU scores ${_puGate(state)}.',
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

  /// The eligibility gate every count on this page already respects, quoted
  /// from the server instead of repeated as a page constant. The original
  /// wording stands until the facets have arrived.
  String _puGate(EntrepreneurState state) {
    final threshold =
        _options?.puThreshold ?? state.recommendationFacets?.puThreshold;
    return threshold == null
        ? 'above 50'
        : 'above ${threshold.toStringAsFixed(0)}';
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
        ? 'No property in the catalogue has a PU research score '
              '${_puGate(state)}, so there is nothing eligible to recommend. '
              'That is a data condition, not a filter problem.'
        : 'Nothing in the catalogue satisfies every constraint AND has a PU '
              'score ${_puGate(state)}. No property was dropped to make this '
              'list shorter and no constraint was relaxed to make it longer. '
              'The filter options above show what each selection leaves, and '
              'releasing one filter at a time is yours to choose.',
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
            to: '/entrepreneur/property-detail?id=${Uri.encodeComponent(prop.id)}$_businessTypeQuery',
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
        p(classes: 'rec2-card__meta', [
          Component.text('Management: ${item.management.display}'),
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
            href: '/entrepreneur/property-detail?id=${Uri.encodeComponent(prop.id)}$_businessTypeQuery',
            variant: 'secondary',
          ),
          ActionLink(
            'Assess',
            href: '/entrepreneur/assessment?id=${Uri.encodeComponent(prop.id)}$_businessTypeQuery',
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
        _panelRow('Management', item.management.display),
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
                      '${item.puScoreSource == 'expanded64_live_inference' ? ' '
                          'This score was computed live by the expanded '
                          '64-feature research model '
                          '(${item.puModelVersion ?? 'unversioned'}); the '
                          'stored research index is a different model and is '
                          'not shown here.' : ''}'
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

      div(classes: 'rec2-panel__block', [
        span(classes: 'rec2-panel__label', [
          Component.text('How well this location matches your business type'),
        ]),
        if (item.category?.available == true) ...[
          p(classes: 'small', [
            Component.text(_categorySentence(item.category!)),
          ]),
        ] else
          p(classes: 'small', [
            Component.text(
              item.category?.reason ??
                  'Business-type resemblance is not available for this property.',
            ),
          ]),
      ]),

      div(classes: 'rec2-panel__actions', [
        ActionLink(
          'View property',
          href: '/entrepreneur/property-detail?id=${Uri.encodeComponent(prop.id)}$_businessTypeQuery',
          variant: 'primary',
        ),
        ActionLink(
          'Assess this property',
          href: '/entrepreneur/assessment?id=${Uri.encodeComponent(prop.id)}$_businessTypeQuery',
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
