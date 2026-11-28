import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:sitewise_jaspr_web/shared/presentation/components/dashboard_kit.dart';
import 'package:sitewise_jaspr_web/shared/presentation/components/ui.dart';

/// The administrative property directory.
///
/// `fyp.rental_properties` is the canonical source, so every property is
/// listed — published, unpublished, imported, owner- or agent-created, draft,
/// rejected and pending — whether or not a verification record exists.
///
/// [scope] selects the workspace the tab belongs to:
/// * `all` — the full directory (the default tab);
/// * `queue` — only the submissions that actually await a decision.
///
/// Both are applied server-side, so the counts, the rows and the pagination
/// always describe the same set.
class ReviewSplit extends StatefulComponent {
  const ReviewSplit({super.key, this.scope = 'all'});

  /// `all` or `queue`.
  final String scope;

  @override
  State<ReviewSplit> createState() => _ReviewSplitState();
}

typedef _ReviewData = ({
  VerificationQueuePage? page,
  VerificationQueueFilters filters,
  String? busy,
  String? notice,
  String? error,
  bool loading,
});

class _ReviewSplitState extends State<ReviewSplit> {
  VerificationDimension _dimension = VerificationDimension.listing;
  String _query = '';
  String _propertyType = '';

  bool get _queueScope => component.scope == 'queue';

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      unawaited(_notifier.loadReviewPage(filters: _defaultFilters()));
    });
  }

  /// The filters this tab starts from: the scope, nothing else.
  VerificationQueueFilters _defaultFilters() => VerificationQueueFilters(
    scope: _queueScope ? 'queue' : null,
    limit: _notifier.reviewFilters.limit,
  );

  AdminNotifier get _notifier => context.read(adminNotifierProvider.notifier);

  void _setStatus(PropertyVerificationStatus? status) {
    final current = _notifier.reviewFilters;
    final next = _dimension == VerificationDimension.listing
        ? current.copyWith(
            listingStatus: status,
            clearListingStatus: status == null,
            offset: 0,
          )
        : current.copyWith(
            ownershipStatus: status,
            clearOwnershipStatus: status == null,
            offset: 0,
          );
    unawaited(_notifier.setReviewFilters(next));
  }

  void _applyQuery() {
    final q = _query.trim();
    final type = _propertyType.trim();
    unawaited(
      _notifier.setReviewFilters(
        _notifier.reviewFilters.copyWith(
          q: q,
          clearQ: q.isEmpty,
          propertyType: type,
          clearPropertyType: type.isEmpty,
          offset: 0,
        ),
      ),
    );
  }

  void _setSort(String sort) {
    if (sort.isEmpty) return;
    unawaited(
      _notifier.setReviewFilters(
        _notifier.reviewFilters.copyWith(sort: sort, offset: 0),
      ),
    );
  }

  void _setLifecycle(String value) {
    unawaited(
      _notifier.setReviewFilters(
        _notifier.reviewFilters.copyWith(
          lifecycle: value,
          clearLifecycle: value.isEmpty,
          offset: 0,
        ),
      ),
    );
  }

  void _setSource(String value) {
    unawaited(
      _notifier.setReviewFilters(
        _notifier.reviewFilters.copyWith(
          source: value,
          clearSource: value.isEmpty,
          offset: 0,
        ),
      ),
    );
  }

  void _setState(String value) {
    unawaited(
      _notifier.setReviewFilters(
        _notifier.reviewFilters.copyWith(
          state: value,
          clearState: value.isEmpty,
          offset: 0,
        ),
      ),
    );
  }

  void _toggleOrder() {
    final current = _notifier.reviewFilters;
    unawaited(
      _notifier.setReviewFilters(
        current.copyWith(
          order: current.order == 'asc' ? 'desc' : 'asc',
          offset: 0,
        ),
      ),
    );
  }

  void _turnPage(int delta) {
    final current = _notifier.reviewFilters;
    final target = current.offset + delta;
    if (target < 0) return;
    unawaited(_notifier.setReviewFilters(current.copyWith(offset: target)));
  }

  /// Clears one dimension's status filter without touching the other.
  void _clearDimensionFilter(VerificationDimension dimension) {
    final current = _notifier.reviewFilters;
    unawaited(
      _notifier.setReviewFilters(
        dimension == VerificationDimension.listing
            ? current.copyWith(clearListingStatus: true, offset: 0)
            : current.copyWith(clearOwnershipStatus: true, offset: 0),
      ),
    );
  }

  void _resetFilters() {
    setState(() {
      _query = '';
      _propertyType = '';
    });
    unawaited(_notifier.setReviewFilters(_defaultFilters()));
  }

  @override
  Component build(BuildContext context) {
    final data = context.watch(
      adminNotifierProvider.select(
        (state) => (
          page: state.reviewPage,
          filters: state.reviewFilters,
          busy: state.busyAction,
          notice: state.reviewNotice,
          error: state.error,
          loading: state.loading,
        ),
      ),
    );
    final items = data.page?.items ?? const <VerificationQueueRow>[];

    return div(classes: 'al2-review', [
      if (data.notice != null)
        div(classes: 'notice notice-info row', [
          span(classes: 'grow', [Component.text(data.notice!)]),
          ActionButton(
            'Dismiss',
            variant: 'ghost',
            onClick: () => _notifier.clearReviewNotice(),
          ),
        ]),
      if (data.error != null)
        div(classes: 'notice notice-danger row', [
          span(classes: 'grow', [Component.text(data.error!)]),
        ]),
      _summary(data),
      div(classes: 'al2-workspace', [
        _toolbar(data),
        _tabs(data),
        div(classes: 'al2-directory', [
          div(classes: 'al2-directory-header', [
            div(classes: 'al2-directory-heading', [
              span(classes: 'al2-overline', [
                Component.text(
                  _queueScope ? 'VERIFICATION QUEUE' : 'PROPERTY DIRECTORY',
                ),
              ]),
              h2([Component.text(_countLine(data))]),
              p(classes: 'al2-muted', [
                Component.text(
                  _queueScope
                      ? 'Submissions with a dimension awaiting a decision. '
                            'Properties without a submission are listed under '
                            'All properties.'
                      : 'Every property in the catalogue, whatever its '
                            'lifecycle. Open one to review its documents, '
                            'ownership and location details.',
                ),
              ]),
            ]),
            ActionButton(
              data.loading ? 'Refreshing…' : 'Refresh',
              variant: 'secondary',
              icon: 'refresh',
              onClick: data.loading
                  ? null
                  : () => unawaited(
                      _notifier.loadReviewPage(
                        filters: _notifier.reviewFilters,
                      ),
                    ),
            ),
          ]),
          if (items.isEmpty)
            EmptyState(
              title: data.loading
                  ? 'Loading property listings…'
                  : data.error != null && data.page == null
                  ? 'Could not load the directory'
                  : _queueScope
                  ? 'Nothing awaiting a decision'
                  : 'No properties match',
              body: data.loading
                  ? 'Reading the latest property records.'
                  : data.error != null && data.page == null
                  ? 'The server has not returned the list. Try refreshing.'
                  : _queueScope
                  ? 'Every submission has been decided. Properties that were '
                        'never submitted are listed under All properties.'
                  : 'Try a different search, lifecycle, source or status.',
              action: data.error != null && data.page == null && !data.loading
                  ? ActionButton(
                      'Try again',
                      variant: 'primary',
                      onClick: () => unawaited(
                        _notifier.loadReviewPage(
                          filters: _notifier.reviewFilters,
                        ),
                      ),
                    )
                  : null,
            )
          else
            TableScroll(
              classes: 'al2-table-scroll',
              label: _queueScope ? 'Verification queue' : 'Property directory',
              children: [
                table(classes: 'al2-table', [
                  thead([
                    tr([
                      _column('Property'),
                      _column('Rent and area', classes: 'al2-number'),
                      _column('Verification'),
                      _column('Publication'),
                      _column('Action', classes: 'al2-action'),
                    ]),
                  ]),
                  tbody([for (final item in items) _queueRow(item)]),
                ]),
              ],
            ),
          _pager(data),
        ]),
      ]),
    ]);
  }

  Component _stat(String label, String value, String iconName) =>
      div(classes: 'al2-stat', [
        span(classes: 'al2-stat__top', [
          Icon(iconName, size: 'sm'),
          Component.text(label),
        ]),
        span(classes: 'al2-stat__value', [Component.text(value)]),
      ]);

  /// Directory overview. The numbers come from the server and deliberately
  /// ignore the status tab, so they do not collapse when one status is
  /// selected.
  Component _summary(_ReviewData data) {
    final summary = data.page?.summary ?? VerificationQueueSummary.empty;
    final loaded = data.page != null;
    String value(int count) => loaded ? '$count' : '—';

    return div(classes: 'al2-summary', [
      div(classes: 'al2-summary__intro', [
        span(classes: 'al2-overline', [
          const Component.text('STAFF WORKSPACE'),
        ]),
        h2([const Component.text('Property overview')]),
        p(classes: 'al2-muted', [
          const Component.text(
            'Counts describe the directory under the current search and '
            'location filters. They are not narrowed by the status tab.',
          ),
        ]),
      ]),
      div(classes: 'al2-stats', [
        _stat('Total properties', value(summary.total), 'inventory_2'),
        _stat('Published', value(summary.published), 'public'),
        _stat('Drafts', value(summary.drafts), 'edit_note'),
        _stat(
          'Awaiting review',
          value(summary.awaitingReview),
          'pending_actions',
        ),
      ]),
    ]);
  }

  Component _toolbar(_ReviewData data) {
    final filters = data.filters;
    // Only states that actually occur in scope are offered, so a filter can
    // never be selected for a value no property has.
    final states =
        (data.page?.stateCounts ?? const <String, int>{}).keys.toList()..sort();
    return div(classes: 'al2-toolbar', [
      div(classes: 'al2-search-field', [
        label(classes: 'al2-field-label', [
          const Component.text('Search properties'),
        ]),
        div(classes: 'al2-search-control', [
          const Icon('search', size: 'sm'),
          input(
            type: InputType.search,
            attributes: {
              'value': _query,
              'placeholder':
                  'Property ID, title, address, city, state or submitter',
              'aria-label': 'Search property listings',
            },
            events: events<String>(
              onInput: (value) => setState(() => _query = value),
            ),
          ),
          button(
            classes: 'btn btn--primary',
            events: events(onClick: _applyQuery),
            attributes: {'type': 'button', 'aria-label': 'Apply search and property type'},
            [const Component.text('Search')],
          ),
        ]),
      ]),
      div(classes: 'al2-sort-field', [
        label(htmlFor: 'al2-property-type', classes: 'al2-field-label', [
          const Component.text('Property type'),
        ]),
        div(classes: 'al2-sort-control', [
          select(
            id: 'al2-property-type',
            attributes: {'aria-label': 'Filter by property type'},
            events: events<String>(onChange: (value) {
              setState(() => _propertyType = value);
              _applyQuery();
            }),
            [
              option(value: '', [const Component.text('All property types')]),
              option(value: 'Shop lot', [const Component.text('Shop lot')]),
              option(value: 'Retail space', [const Component.text('Retail space')]),
            ],
          ),
        ]),
      ]),
      div(classes: 'al2-sort-field', [
        label(classes: 'al2-field-label', [const Component.text('Listing status')]),
        div(classes: 'al2-sort-control', [
          _dropdown(
            'Filter by property lifecycle',
            filters.lifecycle ?? '',
            const {
              '': 'All statuses',
              'published': 'Published',
              'approved': 'Approved, not published',
              'draft': 'Draft',
              'pending': 'Pending',
              'rejected': 'Rejected',
            },
            _setLifecycle,
          ),
        ]),
      ]),
      div(classes: 'al2-sort-field', [
        label(classes: 'al2-field-label', [const Component.text('Source')]),
        div(classes: 'al2-sort-control', [
          _dropdown('Filter by property source', filters.source ?? '', const {
            '': 'All sources',
            'imported': 'Imported catalogue',
            'owner': 'Owner created',
            'agent': 'Agent created',
            'platform': 'Unattributed',
          }, _setSource),
        ]),
      ]),
      div(classes: 'al2-sort-field', [
        label(classes: 'al2-field-label', [const Component.text('State')]),
        div(classes: 'al2-sort-control', [
          _dropdown('Filter by state', filters.state ?? '', {
            '': 'All states',
            for (final state in states)
              state: '${data.page!.stateCounts[state]} · $state',
          }, _setState),
        ]),
      ]),
      div(classes: 'al2-sort-field', [
        label(classes: 'al2-field-label', [const Component.text('Sort by')]),
        div(classes: 'al2-sort-control', [
          _dropdown('Sort listings by', filters.sort, const {
            'submitted_at': 'Submission date',
            'updated_at': 'Last updated',
            'created_at': 'Date added',
            'title': 'Property title',
            'monthly_rent': 'Monthly rent',
          }, _setSort),
          ActionButton(
            filters.order == 'asc' ? 'Ascending' : 'Descending',
            variant: 'secondary',
            icon: filters.order == 'asc' ? 'arrow_upward' : 'arrow_downward',
            onClick: data.busy == null ? _toggleOrder : null,
          ),
        ]),
      ]),
      if (!_isPristine(data.filters) ||
          _query.isNotEmpty ||
          _propertyType.isNotEmpty)
        div(classes: 'al2-clear', [
          ActionButton(
            'Clear filters',
            variant: 'ghost',
            icon: 'filter_alt_off',
            onClick: _resetFilters,
          ),
        ]),
    ]);
  }

  /// Pristine means "no filter beyond this tab's own scope".
  bool _isPristine(VerificationQueueFilters filters) =>
      filters.q == null &&
      filters.listingStatus == null &&
      filters.ownershipStatus == null &&
      filters.lifecycle == null &&
      filters.source == null &&
      filters.propertyType == null &&
      filters.state == null &&
      filters.city == null &&
      filters.submittedFrom == null &&
      filters.submittedTo == null &&
      filters.offset == 0 &&
      filters.sort == _defaultFilters().sort &&
      filters.order == _defaultFilters().order;

  Component _dropdown(
    String labelText,
    String value,
    Map<String, String> options,
    void Function(String) onChanged,
  ) {
    return select(
      attributes: {'aria-label': labelText},
      events: events<List<String>>(
        onInput: (values) => onChanged(values.isEmpty ? '' : values.first),
      ),
      [
        for (final entry in options.entries)
          option(
            value: entry.key,
            attributes: value == entry.key ? const {'selected': ''} : null,
            [Component.text(entry.value)],
          ),
      ],
    );
  }

  Component _tabs(_ReviewData data) {
    final page = data.page;
    final active = _dimension == VerificationDimension.listing
        ? data.filters.listingStatus
        : data.filters.ownershipStatus;

    // "All statuses" is the count for this dimension's scope with its own
    // filter removed — never the already-filtered page total.
    final defs = <(PropertyVerificationStatus?, String, int?)>[
      (null, 'All statuses', page?.countAll(_dimension)),
      (
        PropertyVerificationStatus.notSubmitted,
        'Not submitted',
        page?.countOf(_dimension, PropertyVerificationStatus.notSubmitted),
      ),
      (
        PropertyVerificationStatus.pending,
        'Awaiting review',
        page?.countOf(_dimension, PropertyVerificationStatus.pending),
      ),
      (
        PropertyVerificationStatus.underReview,
        'Under review',
        page?.countOf(_dimension, PropertyVerificationStatus.underReview),
      ),
      (
        PropertyVerificationStatus.verified,
        'Verified',
        page?.countOf(_dimension, PropertyVerificationStatus.verified),
      ),
      (
        PropertyVerificationStatus.rejected,
        'Rejected',
        page?.countOf(_dimension, PropertyVerificationStatus.rejected),
      ),
      (
        PropertyVerificationStatus.informationRequested,
        'Info requested',
        page?.countOf(
          _dimension,
          PropertyVerificationStatus.informationRequested,
        ),
      ),
    ];

    // The OTHER dimension's filter is still applied server-side. Showing it
    // makes sure a reviewer can never be puzzled by records that a filter they
    // cannot see has removed.
    final hiddenDimension = _dimension == VerificationDimension.listing
        ? VerificationDimension.ownership
        : VerificationDimension.listing;
    final hiddenStatus = hiddenDimension == VerificationDimension.ownership
        ? data.filters.ownershipStatus
        : data.filters.listingStatus;

    return div(classes: 'al2-filter-shell', [
      div(classes: 'al2-filter-line', [
        span(classes: 'al2-filter-name', [
          const Component.text('Verification type'),
        ]),
        div(classes: 'al2-segments', [
          for (final dimension in VerificationDimension.values)
            button(
              classes:
                  'al2-segment${_dimension == dimension ? ' is-active' : ''}',
              attributes: {
                'type': 'button',
                'aria-pressed': (_dimension == dimension).toString(),
              },
              events: events(
                onClick: () => setState(() => _dimension = dimension),
              ),
              [Component.text(dimension.label)],
            ),
        ]),
      ]),
      div(classes: 'al2-filter-line al2-status-line', [
        span(classes: 'al2-filter-name', [
          const Component.text('Review status'),
        ]),
        div(classes: 'al2-statuses', [
          for (final (status, text, count) in defs)
            button(
              classes: 'al2-status${status == active ? ' is-active' : ''}',
              attributes: {
                'type': 'button',
                'aria-pressed': (status == active).toString(),
              },
              events: events(onClick: () => _setStatus(status)),
              [
                Component.text(text),
                if (count != null)
                  span(classes: 'al2-status__count', [
                    Component.text('$count'),
                  ]),
              ],
            ),
        ]),
      ]),
      if (hiddenStatus != null)
        div(classes: 'al2-filter-line al2-status-line', [
          span(classes: 'al2-filter-name', [
            const Component.text('Also filtered by'),
          ]),
          div(classes: 'al2-statuses', [
            button(
              classes: 'al2-status is-active',
              attributes: {'type': 'button'},
              events: events(
                onClick: () => _clearDimensionFilter(hiddenDimension),
              ),
              [
                Component.text(
                  '${hiddenDimension.label} · ${hiddenStatus.label}',
                ),
                span(classes: 'al2-status__count', [const Component.text('×')]),
              ],
            ),
          ]),
        ]),
    ]);
  }

  String _countLine(_ReviewData data) {
    final total = data.page?.total;
    if (total == null) return 'Property directory';
    return '$total ${total == 1 ? 'property' : 'properties'} found';
  }

  Component _column(String label, {String? classes}) => th(
    classes: classes,
    attributes: {'scope': 'col'},
    [Component.text(label)],
  );

  Component _queueRow(VerificationQueueRow item) {
    final href =
        '/admin/listing-detail?id=${Uri.encodeComponent('${item.propertyId}')}';
    final canReview = _queueScope && item.isActionable;
    final location = [item.city, item.state]
        .whereType<String>()
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toSet()
        .join(', ');
    final submitter = switch (item.source) {
      'owner' => 'Owner',
      'agent' => 'Agent',
      'imported' => 'Imported catalogue',
      _ => null,
    };
    // The API's submitter name is joined from the Owner account.
    final ownerName = item.source == 'owner'
        ? item.submitterName?.trim()
        : null;
    final photo = item.primaryPhotoUrl;
    return tr(key: ValueKey(item.propertyId), [
      td([
        div(classes: 'al2-property', [
          span(classes: 'al2-property__icon', [
            const Icon('storefront', size: 'sm'),
            if (photo != null && photo.isNotEmpty)
              img(src: photo, alt: '', attributes: {'loading': 'lazy'}),
          ]),
          div(classes: 'al2-property__copy', [
            AppLink(
              to: href,
              classes: 'al2-property__name',
              children: [
                span(
                  attributes: {'title': item.displayName},
                  [Component.text(item.displayName)],
                ),
              ],
            ),
            span(classes: 'al2-property__id', [
              Component.text('ID ${item.propertyId}'),
            ]),
            span(classes: 'al2-property__meta', [
              Component.text('${_displayPropertyType(item.propertyType)} · $location'),
            ]),
            span(classes: 'al2-property__submitter', [
              Component.text(ownerName != null && ownerName.isNotEmpty ? 'Owner · $ownerName' : (submitter ?? 'Not provided')),
            ]),
          ]),
        ]),
      ]),
      td(classes: 'al2-rent-area', [
        strong([Component.text(item.monthlyRent == null ? 'Rent not provided' : 'RM ${_quantity(item.monthlyRent!)}')]),
        span([Component.text(item.builtUpAreaSqft == null ? 'Area not provided' : '${_quantity(item.builtUpAreaSqft!)} sq ft')]),
      ]),
      td([_verificationPill(item)]),
      td([
        Pill(
          item.isPublished ? 'Published' : 'Not published',
          tone: item.isPublished ? 'success' : 'neutral',
        ),
      ]),
      td(classes: 'al2-action', [
        ActionLink(
          canReview ? 'Review' : 'View details',
          href: href,
          variant: canReview ? 'secondary' : 'ghost',
        ),
      ]),
    ]);
  }

  String _quantity(double value) =>
      value.toStringAsFixed(value == value.roundToDouble() ? 0 : 2);

  Component _verificationPill(VerificationQueueRow item) {
    final (label, tone) = switch (item.listingStatus) {
      PropertyVerificationStatus.verified => ('Approved', 'success'),
      PropertyVerificationStatus.pending => ('Awaiting review', 'warning'),
      PropertyVerificationStatus.underReview => ('Under review', 'action'),
      PropertyVerificationStatus.rejected => ('Rejected', 'danger'),
      PropertyVerificationStatus.informationRequested => (
        'Information requested',
        'warning',
      ),
      PropertyVerificationStatus.notSubmitted => switch (item.agentStage) {
        'requested' || 'accepted' => ('Awaiting inspection', 'warning'),
        _ when item.lifecycle == 'draft' => ('Draft', 'neutral'),
        _ => ('Not submitted', 'neutral'),
      },
    };
    return Pill(label, tone: tone);
  }

  Component _pager(_ReviewData data) {
    final page = data.page;
    if (page == null) return Component.fragment([]);
    final from = page.total == 0 ? 0 : page.offset + 1;
    final to = (page.offset + page.limit).clamp(0, page.total);
    final current = page.limit == 0 ? 1 : page.offset ~/ page.limit + 1;
    final pages = page.limit == 0
        ? 1
        : (page.total + page.limit - 1) ~/ page.limit;
    final hasPrev = data.filters.offset > 0;
    final hasNext = data.filters.offset + page.limit < page.total;

    return div(classes: 'al2-pager', [
      span(classes: 'al2-pager__caption', [
        Component.text(
          'Showing $from–$to of ${page.total} · Page $current of $pages',
        ),
      ]),
      if (page.total > page.limit)
        div(classes: 'al2-pager__actions', [
          ActionButton(
            'Previous',
            onClick: hasPrev ? () => _turnPage(-page.limit) : null,
            variant: 'secondary',
            icon: 'chevron_left',
          ),
          ActionButton(
            'Next',
            onClick: hasNext ? () => _turnPage(page.limit) : null,
            variant: 'secondary',
            icon: 'chevron_right',
          ),
        ]),
    ]);
  }
}

String _displayPropertyType(String? value) {
  final normalized = value?.replaceAll(RegExp(r'\s+'), '').toLowerCase();
  if (normalized == 'shoplot') return 'Shop lot';
  if (normalized == 'retailspace') return 'Retail space';
  return value?.trim().isNotEmpty == true ? value!.trim() : 'Type not provided';
}
