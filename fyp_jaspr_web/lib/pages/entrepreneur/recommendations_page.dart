import 'dart:async';
import 'dart:convert';

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

  /// The APPLIED criteria travel with every property-detail link so the
  /// comparison tab can show the filters that produced this result. Draft
  /// edits are never carried: they have not been searched yet.
  String get _filterQuery {
    final applied =
        context.read(entrepreneurNotifierProvider).recommendationRequest;
    return '&filters=${Uri.encodeQueryComponent(jsonEncode(applied.toJson()))}';
  }
  String _state = '';
  String _propertyType = '';

  /// The selected monthly-rental interval, as `"min|max"`; empty means
  /// "Any monthly rental" (both request boundaries cleared). A saved range
  /// the backend does not generate is kept under the same key until changed,
  /// so a custom preference is never silently discarded.
  String _rentKey = '';
  String _minSize = '';
  String _maxSize = '';
  String _targetMarket = '';
  String _query = '';

  /// Contextual choices for the DRAFT criteria. The applied choices remain in
  /// the session-scoped notifier state; the results list is never rebuilt
  /// from this payload.
  RecommendationFacets? _draftFacets;
  bool _facetLoading = false;
  String? _facetError;

  /// Draft facet requests are read-only and cheap relative to ranking, but a
  /// slower earlier response must never overwrite a newer selection.
  int _facetSeq = 0;
  Timer? _facetTimer;

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
          _refreshFacets();
          return;
        }
        setState(() => _syncDraft(applied));
        _refreshFacets();
        return;
      }
      final prefs = context.read(businessPreferencesProvider);
      final request = _initialRequest(prefs);
      // The form shows what the first search actually applies (saved
      // requirements, or nothing) instead of a blank panel that disagrees
      // with the results.
      setState(() => _syncDraft(request));
      await _notifier.searchRecommendations(request: request);
      if (!mounted) return;
      final wanted = component.initialPropertyId;
      if (wanted != null && wanted.isNotEmpty) {
        final state = context.read(entrepreneurNotifierProvider);
        if (state.ranked.any((row) => row.property.id == wanted)) {
          _notifier.selectRanked(wanted);
        }
      }
      _refreshFacets();
    });
  }

  @override
  void dispose() {
    _facetTimer?.cancel();
    super.dispose();
  }

  /// A stable key for a pair of rental boundaries. The option list is
  /// regenerated as filters change, but the selected budget must stay visible
  /// and comparable by value, never by a label that may be reworded.
  static String _rangeKey(double? min, double? max) =>
      '${min ?? ''}|${max ?? ''}';

  /// Draft rental boundaries, read back from the selected key. A saved range
  /// with one open side is legitimate; an inverted pair is normalised before
  /// it can ever reach FastAPI (which rejects it with 422).
  ({double? min, double? max}) get _rentBounds {
    final bounds = FacetRangeOption.boundsFromKey(_rentKey);
    final min = bounds.min;
    final max = bounds.max;
    if (min != null && max != null && min > max) {
      return (min: max, max: min);
    }
    return (min: min, max: max);
  }

  /// Draft <- applied. Called on mount and after any applied-state change
  /// that did not originate in the form (chip removal, reset).
  void _syncDraft(RecommendationSearchRequest request) {
    _businessType = request.businessType ?? '';
    _state = request.preferredState ?? '';
    _propertyType = request.propertyType ?? '';
    final rentMin = request.minRentalRm;
    final rentMax = request.maxRentalRm;
    // Preserve a saved custom range by value. It stays selected until the
    // entrepreneur picks another interval or clears it, even when the backend
    // does not generate that exact interval for the current filters.
    _rentKey = rentMin == null && rentMax == null
        ? ''
        : _rangeKey(
            rentMin != null && rentMax != null && rentMin > rentMax
                ? rentMax
                : rentMin,
            rentMin != null && rentMax != null && rentMin > rentMax
                ? rentMin
                : rentMax,
          );
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
    // Management scoping stays OFF here. The research catalogue this page
    // ranks is `verification_status='pending'`, and the manager mapping is
    // built only from approved+published operational listings, so scoping the
    // search to managers matches zero of the 290 PU-eligible properties.
    return configured
        ? RecommendationSearchRequest.fromPreferences(prefs)
        : const RecommendationSearchRequest();
  }

  /// The request the form currently describes. Used for both the facets read
  /// and "Find properties", so quoted counts and the ranked set can never be
  /// computed from different criteria.
  RecommendationSearchRequest get _draftRequest {
    final rent = _rentBounds;
    return RecommendationSearchRequest(
      businessType: _businessType.trim().isEmpty
          ? null
          : _businessType.trim(),
      preferredState: _state.isEmpty ? null : _state,
      propertyType: _propertyType.isEmpty ? null : _propertyType,
      minRentalRm: rent.min,
      maxRentalRm: rent.max,
      minSizeSqft: double.tryParse(_minSize.trim()),
      maxSizeSqft: double.tryParse(_maxSize.trim()),
      layoutPreferences: _layoutPreferences,
      query: _query.trim().isEmpty ? null : _query.trim(),
      sort: _sort,
      pageSize: 20,
    );
  }

  /// Applies the draft filters and re-runs from page 1.
  void _apply() {
    final request = _draftRequest;
    _notifier.applyRecommendationRequest(request);
    _refreshFacets();
  }

  /// A draft control changed. Facets refresh for the complete draft, while
  /// the ranked results stay as they were until "Find properties" is pressed.
  /// Text and numeric fields use a short debounce; a selection is immediate.
  void _onDraftChange({Duration debounce = Duration.zero}) =>
      _refreshFacets(debounce: debounce);

  /// Reads contextual choices for the current draft. The previous choices
  /// stay visible while loading and after a failed request; only the response
  /// for the latest request is published.
  void _refreshFacets({Duration debounce = Duration.zero}) {
    _facetTimer?.cancel();
    _facetTimer = Timer(debounce, () async {
      if (!mounted) return;
      final seq = ++_facetSeq;
      final request = _draftRequest;
      setState(() {
        _facetLoading = true;
        _facetError = null;
      });
      try {
        final facets = await _notifier.fetchRecommendationFacets(request);
        if (!mounted || seq != _facetSeq) return;
        setState(() {
          _draftFacets = facets;
          _facetLoading = false;
        });
      } on Object {
        if (!mounted || seq != _facetSeq) return;
        setState(() {
          _facetLoading = false;
          _facetError = 'Filter choices could not be updated.';
        });
      }
    });
  }

  /// The applied facets until a draft refresh completes, so a failed or slow
  /// contextual read never blanks the controls.
  RecommendationFacets? _facetsFor(EntrepreneurState state) =>
      _draftFacets ?? state.recommendationFacets;

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
    _refreshFacets();
  }

  void _reset() {
    const defaults = RecommendationSearchRequest();
    setState(() => _syncDraft(defaults));
    _notifier.applyRecommendationRequest(defaults);
    _refreshFacets();
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

  static String _rentChipLabel(RecommendationSearchRequest request) =>
      _rentText(request.minRentalRm, request.maxRentalRm);

  Component _filters(EntrepreneurState state) {
    final facets = _facetsFor(state);
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
            onChanged: (v) {
              setState(() => _businessType = v);
              _onDraftChange();
            },
          ),
          _rentalField(facets),
          _textField(
            caption: 'Minimum size (sq ft)',
            value: _minSize,
            placeholder: 'e.g. 800',
            onInput: (v) {
              setState(() => _minSize = v);
              _onDraftChange(debounce: const Duration(milliseconds: 300));
            },
          ),
          _textField(
            caption: 'Maximum size (sq ft)',
            value: _maxSize,
            placeholder: 'e.g. 1800',
            onInput: (v) {
              setState(() => _maxSize = v);
              _onDraftChange(debounce: const Duration(milliseconds: 300));
            },
          ),
          _comboField(
            caption: 'Target market',
            fieldId: 'rec2-target-market',
            value: _targetMarket,
            emptyLabel: 'Any target market',
            options: _targetMarketOptions,
            onChanged: (v) {
              setState(() => _targetMarket = v);
              _onDraftChange();
            },
          ),
          _sortField(_sortOptions(state)),
          _textField(
            caption: 'Search',
            value: _query,
            placeholder: 'Area, title or property id',
            onInput: (v) {
              setState(() => _query = v);
              _onDraftChange(debounce: const Duration(milliseconds: 300));
            },
          ),
        ]),
        _facetStatus(state),
        // Chips, not <select>: the values come from the catalogue itself, so
        // an option can never match zero rows. Counts are refreshed for the
        // DRAFT criteria and are real counts, never fabricated.
        if (facets != null && facets.states.isNotEmpty)
          _chipRow(
            caption: 'Preferred state',
            options: facets.states,
            selected: _state,
            onPick: (v) {
              setState(() => _state = v);
              _onDraftChange();
            },
          ),
        if (facets != null && facets.propertyTypes.isNotEmpty)
          _chipRow(
            caption: 'Property type',
            options: facets.propertyTypes,
            selected: _propertyType,
            onPick: (v) {
              setState(() => _propertyType = v);
              _onDraftChange();
            },
          ),
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

  /// One dropdown built from `rental_ranges.options`, never from a hand typed
  /// list. The label is the full interval and its real matching count; the
  /// value is the exact pair of boundaries sent to FastAPI.
  Component _rentalField(RecommendationFacets? facets) {
    final options = facets?.rentalRanges ?? const <FacetRangeOption>[];
    final hasSelection = _rentKey.isNotEmpty;
    final generated = hasSelection
        ? options.where((item) => item.key == _rentKey).toList()
        : const <FacetRangeOption>[];
    final custom = hasSelection && generated.isEmpty;
    final bounds = _rentBounds;
    final selectedLabel = facets?.selectedRental?.label ??
        (custom ? _rentText(bounds.min, bounds.max) : '');

    return div(classes: 'field rec2__field--wide', [
      label(classes: 'field__label', [
        Component.text('Monthly rental (RM)'),
      ]),
      select(
        id: 'rec2-monthly-rental',
        attributes: const {
          'aria-label': 'Monthly rental (RM)',
          'name': 'rec2-monthly-rental',
        },
        events: events<List<String>>(
          onInput: (values) {
            final value = values.isEmpty ? '' : values.first;
            if (value == _rentKey) return;
            setState(() => _rentKey = value);
            _onDraftChange();
          },
        ),
        [
          option(
            key: const ValueKey('rent-any'),
            value: '',
            selected: !hasSelection,
            [Component.text('Any monthly rental')],
          ),
          // A saved range (or a range that has just become unavailable) stays
          // visible and selected until it is changed or explicitly cleared.
          if (custom)
            option(
              key: ValueKey('rent-custom-$_rentKey'),
              value: _rentKey,
              selected: true,
              [
                Component.text(
                  '$selectedLabel (${_unavailableRent(facets) ? 'unavailable' : 'saved range'})',
                ),
              ],
            ),
          for (final item in options)
            option(
              key: ValueKey('rent-${item.key}'),
              value: item.key,
              selected: item.key == _rentKey,
              [
                Component.text(
                  '${item.label} (${item.total} ${item.total == 1 ? 'property' : 'properties'})',
                ),
              ],
            ),
        ],
      ),
      if (custom && _rentKey.isNotEmpty)
        div(classes: 'rec2__rent-note', [
          Component.text(
            _unavailableRent(facets)
                ? 'This rental range currently matches no eligible properties.'
                : 'Your saved rental range is not one of the current intervals. '
                    'It stays applied until you choose another.',
          ),
          if (_unavailableRent(facets))
            button(
              classes: 'rec2__link-button',
              attributes: const {
                'type': 'button',
                'aria-label': 'Clear rental filter',
              },
              events: events(onClick: _rentChangedToAny),
              [Component.text('Clear rental filter')],
            ),
        ]),
    ]);
  }

  bool _unavailableRent(RecommendationFacets? facets) =>
      _rentKey.isNotEmpty &&
      facets != null &&
      facets.rentalRanges.isNotEmpty &&
      !facets.rentalRanges.any((item) => item.key == _rentKey) &&
      facets.matchingTotal == 0;

  void _rentChangedToAny() {
    setState(() => _rentKey = '');
    _onDraftChange();
  }

  /// Small status line above the filter chips: loading, failure with retry,
  /// a real contextual count, or the empty state with recovery actions.
  Component _facetStatus(EntrepreneurState state) {
    if (_facetError != null) {
      return div(classes: 'rec2__facet-status is-error', attributes: const {
        'role': 'status',
      }, [
        Component.text('$_facetError Previous choices are still shown.'),
        button(
          classes: 'rec2__link-button',
          attributes: const {'type': 'button'},
          events: events(onClick: () => _refreshFacets()),
          [Component.text('Retry')],
        ),
      ]);
    }
    if (_facetLoading) {
      return div(classes: 'rec2__facet-status', attributes: const {
        'role': 'status',
      }, [Component.text('Updating filter choices…')]);
    }
    final facets = _draftFacets;
    if (facets == null) return Component.fragment([]);
    final total = facets.matchingTotal;
    if (total == 0) {
      final applied = state.recommendationRequest;
      return div(classes: 'rec2__facet-status is-empty', [
        strong([Component.text('No properties match all your current filters.')]),
        if (_rentKey.isNotEmpty)
          button(
            classes: 'rec2__link-button',
            attributes: const {'type': 'button'},
            events: events(onClick: _rentChangedToAny),
            [Component.text('Clear rental filter')],
          ),
        for (final relaxation in facets.relaxations.take(3))
          button(
            classes: 'rec2__link-button',
            attributes: {'type': 'button'},
            events: events(
              onClick: () => _applyRequest(
                _clearFacetField(applied, relaxation.field),
              ),
            ),
            [Component.text('Remove ${relaxation.label}')],
          ),
        button(
          classes: 'rec2__link-button',
          attributes: const {'type': 'button'},
          events: events(onClick: _reset),
          [Component.text('Clear all filters')],
        ),
      ]);
    }
    return div(classes: 'rec2__facet-status', attributes: const {
      'role': 'status',
    }, [
      Component.text(
        '$total ${total == 1 ? 'property matches' : 'properties match'} '
        'all your current filters.',
      ),
    ]);
  }

  /// Maps a backend relaxation key to the matching request clear flag. Only
  /// hard filters appear in `relaxations`; ranking-only inputs never do.
  RecommendationSearchRequest _clearFacetField(
    RecommendationSearchRequest request,
    String field,
  ) => switch (field) {
    'preferred_state' => request.copyWith(clearState: true),
    'property_type' => request.copyWith(clearPropertyType: true),
    'rental_budget' => request.copyWith(clearRentRange: true),
    'property_size' => request.copyWith(clearSizeRange: true),
    'preferred_area' => request.copyWith(clearArea: true),
    'query' => request.copyWith(clearQuery: true),
    _ => request,
  };

  /// Ringgit grouping for chip and custom-range labels.
  static String _money(double value) {
    final digits = value.toStringAsFixed(0);
    final grouped = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) grouped.write(',');
      grouped.write(digits[i]);
    }
    return 'RM $grouped';
  }

  static String _rentText(double? min, double? max) {
    if (min != null && max != null) {
      return min == max ? _money(min) : '${_money(min)} – ${_money(max)}';
    }
    if (min != null) return 'From ${_money(min)}';
    if (max != null) return 'Up to ${_money(max)}';
    return 'Any monthly rental';
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
          key: ValueKey('$caption-${option.value}'),
          classes: option.value == selected ? 'checkpill is-on' : 'checkpill',
          [
            input(
              type: InputType.radio,
              name: caption,
              // Jaspr manages `checked` as a DOM property, not a string
              // attribute: pass the boolean explicitly so assistive tech and
              // keyboard focus agree with the visible `.is-on` state.
              checked: option.value == selected,
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

  Component _empty(EntrepreneurState state) {
    final request = state.recommendationRequest;
    final browseOnly = request.isBrowseOnly;
    final facets = _facetsFor(state);
    final hasRent = request.minRentalRm != null || request.maxRentalRm != null;
    return EmptyState(
      title: browseOnly
          ? 'No PU-eligible properties'
          : 'No properties match all your current filters.',
      body: browseOnly
          ? 'No property in the catalogue has a PU research score above 50, so '
                'there is nothing eligible to recommend. That is a data '
                'condition, not a filter problem.'
          : 'Nothing in the catalogue satisfies every constraint AND has a PU '
                'score above 50. Remove a restrictive filter or clear them all '
                'and search again.',
      action: div(classes: 'rec2__empty-actions', [
        if (hasRent)
          ActionButton(
            'Clear rental filter',
            variant: 'secondary',
            onClick: () =>
                _applyRequest(request.copyWith(clearRentRange: true)),
          ),
        // The backend suggests only hard filters whose removal actually
        // recovers rows; ranking-only inputs are never offered here.
        for (final relaxation in (facets?.relaxations ?? const []).take(3))
          if (relaxation.field != 'rental_budget' || !hasRent)
            ActionButton(
              'Remove ${relaxation.label}',
              variant: 'secondary',
              onClick: () =>
                  _applyRequest(_clearFacetField(request, relaxation.field)),
            ),
        ActionButton(
          'Clear all filters',
          variant: 'primary',
          onClick: _reset,
        ),
      ]),
    );
  }

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
            to: '/entrepreneur/property-detail?id=${Uri.encodeComponent(prop.id)}$_businessTypeQuery$_filterQuery',
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
            href: '/entrepreneur/property-detail?id=${Uri.encodeComponent(prop.id)}$_businessTypeQuery$_filterQuery',
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
          href: '/entrepreneur/property-detail?id=${Uri.encodeComponent(prop.id)}$_businessTypeQuery$_filterQuery',
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
