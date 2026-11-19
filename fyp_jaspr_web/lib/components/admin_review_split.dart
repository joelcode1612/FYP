import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import 'ui.dart';

/// Full-width admin listing directory.
///
/// Search, status filters, facets, sorting and pagination use the original
/// backend `GET /api/v1/staff/properties/` projection. A property opens the
/// existing `/admin/listing-detail?id=...` route, which already provides the
/// full VerificationDetailView and authenticated review actions. Keeping the
/// detailed evidence and decision sidebar out of a nested split view gives
/// administrators room to work without changing backend behavior.
class ReviewSplit extends StatefulComponent {
  const ReviewSplit({super.key});

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

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      unawaited(
        context.read(adminNotifierProvider.notifier).loadReviewPage(),
      );
    });
  }

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
    unawaited(_notifier.setReviewFilters(_notifier.reviewFilters.copyWith(
      q: q,
      clearQ: q.isEmpty,
      offset: 0,
    )));
  }

  void _setSort(String sort) {
    unawaited(_notifier.setReviewFilters(
      _notifier.reviewFilters.copyWith(sort: sort, offset: 0),
    ));
  }

  void _toggleOrder() {
    final current = _notifier.reviewFilters;
    unawaited(_notifier.setReviewFilters(current.copyWith(
      order: current.order == 'asc' ? 'desc' : 'asc',
      offset: 0,
    )));
  }

  void _turnPage(int delta) {
    final current = _notifier.reviewFilters;
    final target = current.offset + delta;
    if (target < 0) return;
    unawaited(_notifier.setReviewFilters(current.copyWith(offset: target)));
  }

  void _resetFilters() {
    setState(() => _query = '');
    unawaited(_notifier.setReviewFilters(const VerificationQueueFilters()));
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
                const Component.text('PROPERTY DIRECTORY'),
              ]),
              h2([Component.text(_countLine(data))]),
              p(classes: 'al2-muted', [
                const Component.text(
                  'Open a property to review its documents, ownership and location details.',
                ),
              ]),
            ]),
            ActionButton(
              data.loading ? 'Refreshing…' : 'Refresh',
              variant: 'secondary',
              icon: 'refresh',
              onClick: data.loading
                  ? null
                  : () => unawaited(_notifier.loadReviewPage()),
            ),
          ]),
          if (items.isEmpty)
            EmptyState(
              title: data.loading
                  ? 'Loading property listings…'
                  : data.error != null && data.page == null
                      ? 'Could not load the directory'
                      : 'No listings match',
              body: data.loading
                  ? 'Reading the latest property records.'
                  : data.error != null && data.page == null
                      ? 'The server has not returned the list. Try refreshing.'
                      : 'Try a different search or verification status.',
              action: data.error != null && data.page == null && !data.loading
                  ? ActionButton(
                      'Try again',
                      variant: 'primary',
                      onClick: () => unawaited(_notifier.loadReviewPage()),
                    )
                  : null,
            )
          else
            div(classes: 'al2-table-scroll', [
              table(classes: 'al2-table', [
                thead([
                  tr([
                    th([const Component.text('Property')]),
                    th([const Component.text('Location / submitter')]),
                    th([const Component.text('Monthly rent')]),
                    th([const Component.text('Listing')]),
                    th([const Component.text('Ownership')]),
                    th([const Component.text('Managed by')]),
                    th([const Component.text('')]),
                  ]),
                ]),
                tbody([
                  for (final item in items) _queueRow(item),
                ]),
              ]),
            ]),
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

  Component _summary(_ReviewData data) {
    final page = data.page;
    String count(VerificationDimension dimension, PropertyVerificationStatus status) =>
        page == null ? '—' : '${page.countOf(dimension, status) ?? 0}';

    return div(classes: 'al2-summary', [
      div(classes: 'al2-summary__intro', [
        span(classes: 'al2-overline', [
          const Component.text('STAFF WORKSPACE'),
        ]),
        h2([const Component.text('Listing overview')]),
        p(classes: 'al2-muted', [
          const Component.text(
            'Review listing details and ownership independently. All counts '
            'are supplied by the verification service.',
          ),
        ]),
      ]),
      div(classes: 'al2-stats', [
        _stat('Matching listings', page == null ? '—' : '${page.total}', 'inventory_2'),
        _stat('Listing pending',
            count(VerificationDimension.listing, PropertyVerificationStatus.pending),
            'pending_actions'),
        _stat('Ownership pending',
            count(VerificationDimension.ownership, PropertyVerificationStatus.pending),
            'verified_user'),
        _stat('Listings verified',
            count(VerificationDimension.listing, PropertyVerificationStatus.verified),
            'task_alt'),
      ]),
    ]);
  }

  Component _toolbar(_ReviewData data) {
    final filters = data.filters;
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
              'placeholder': 'Title, address, city or company',
              'aria-label': 'Search property listings',
            },
            events: events<String>(
              onInput: (value) => setState(() => _query = value),
            ),
          ),
          ActionButton('Search', onClick: _applyQuery, variant: 'primary'),
        ]),
      ]),
      div(classes: 'al2-sort-field', [
        label(classes: 'al2-field-label', [
          const Component.text('Sort by'),
        ]),
        div(classes: 'al2-sort-control', [
          _dropdown(
            'Sort listings by',
            filters.sort,
            const {
              'submitted_at': 'Submission date',
              'updated_at': 'Last updated',
              'title': 'Property title',
              'price': 'Monthly rent',
            },
            _setSort,
          ),
          ActionButton(
            filters.order == 'asc' ? 'Ascending' : 'Descending',
            variant: 'secondary',
            icon: filters.order == 'asc' ? 'arrow_upward' : 'arrow_downward',
            onClick: data.busy == null ? _toggleOrder : null,
          ),
        ]),
      ]),
      if (!filters.isPristine)
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
    final defs = <(PropertyVerificationStatus?, String, int?)>[
      (null, 'All statuses', page?.total),
      (PropertyVerificationStatus.pending, 'Awaiting review',
          page?.countOf(_dimension, PropertyVerificationStatus.pending)),
      (PropertyVerificationStatus.underReview, 'Under review',
          page?.countOf(_dimension, PropertyVerificationStatus.underReview)),
      (PropertyVerificationStatus.verified, 'Verified',
          page?.countOf(_dimension, PropertyVerificationStatus.verified)),
      (PropertyVerificationStatus.rejected, 'Rejected',
          page?.countOf(_dimension, PropertyVerificationStatus.rejected)),
      (PropertyVerificationStatus.informationRequested, 'Info requested',
          page?.countOf(_dimension, PropertyVerificationStatus.informationRequested)),
    ];

    return div(classes: 'al2-filter-shell', [
      div(classes: 'al2-filter-line', [
        span(classes: 'al2-filter-name', [
          const Component.text('Verification type'),
        ]),
        div(classes: 'al2-segments', [
          for (final dimension in VerificationDimension.values)
            button(
              classes: 'al2-segment${_dimension == dimension ? ' is-active' : ''}',
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
                  span(classes: 'al2-status__count', [Component.text('$count')]),
              ],
            ),
        ]),
      ]),
    ]);
  }

  String _countLine(_ReviewData data) {
    final total = data.page?.total;
    if (total == null) return 'Property directory';
    return '$total ${total == 1 ? 'listing' : 'listings'} found';
  }

  Component _queueRow(VerificationQueueRow item) {
    final href =
        '/admin/listing-detail?id=${Uri.encodeComponent('${item.propertyId}')}';
    return tr([
      td([
        div(classes: 'al2-property', [
          span(classes: 'al2-property__icon', [
            const Icon('storefront', size: 'sm'),
          ]),
          div(classes: 'al2-property__copy', [
            AppLink(
              to: href,
              classes: 'al2-property__name',
              children: [Component.text(item.displayName)],
            ),
            span(classes: 'al2-property__id', [
              Component.text('ID ${item.propertyId}'),
              if (item.publicationEligible)
                span(classes: 'al2-live', [const Component.text('Live')]),
            ]),
          ]),
        ]),
      ]),
      td([
        span(classes: 'al2-cell-main', [
          Component.text(item.city ?? 'Location not supplied'),
        ]),
        if (item.companyName != null)
          span(classes: 'al2-cell-sub', [Component.text(item.companyName!)]),
      ]),
      td([
        span(classes: 'al2-rent', [
          Component.text(item.monthlyRent == null
              ? '—'
              : 'RM ${item.monthlyRent!.toStringAsFixed(0)}'),
        ]),
        if (item.monthlyRent != null)
          span(classes: 'al2-cell-sub', [const Component.text('per month')]),
      ]),
      td([_rowPill(item.listingStatus)]),
      td([_rowPill(item.ownershipStatus)]),
      td([
        span(classes: 'al2-cell-main', [
          Component.text(item.management?.display ?? 'Not available'),
        ]),
      ]),
      td([
        ActionLink(
          'Review',
          href: href,
          variant: 'secondary',
          icon: 'arrow_forward',
        ),
      ]),
    ]);
  }

  Component _rowPill(PropertyVerificationStatus status) => Pill(
    status.label,
    tone: switch (status) {
      PropertyVerificationStatus.verified => 'success',
      PropertyVerificationStatus.pending => 'warning',
      PropertyVerificationStatus.underReview => 'action',
      PropertyVerificationStatus.rejected => 'danger',
      PropertyVerificationStatus.informationRequested => 'warning',
      PropertyVerificationStatus.notSubmitted => 'neutral',
    },
  );

  Component _pager(_ReviewData data) {
    final page = data.page;
    if (page == null) return Component.fragment([]);
    final from = page.total == 0 ? 0 : page.offset + 1;
    final to = (page.offset + page.limit).clamp(0, page.total);
    final current = page.limit == 0 ? 1 : page.offset ~/ page.limit + 1;
    final pages = page.limit == 0 ? 1 : (page.total + page.limit - 1) ~/ page.limit;
    final hasPrev = data.filters.offset > 0;
    final hasNext = data.filters.offset + page.limit < page.total;

    return div(classes: 'al2-pager', [
      span(classes: 'al2-pager__caption', [
        Component.text('Showing $from–$to of ${page.total} · Page $current of $pages'),
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
