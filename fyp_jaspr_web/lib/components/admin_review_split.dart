import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import 'ui.dart';
import 'verification_detail_view.dart';

/// Master-detail review surface, ported from the source `admin/review.html`.
///
/// The queue is the backend's SQL projection (`GET /api/v1/staff/properties/`):
/// every tab, search term, sort and page turn composes into
/// [VerificationQueueFilters] and the server answers with one page plus
/// faceted per-dimension counts. Nothing is filtered client-side — what the
/// table shows is exactly what the database matched.
///
/// The left panel renders the queue; the right panel embeds the shared
/// [VerificationDetailView] for the selected property. Decisions, busy flags
/// and success notices all live in the shared admin controller.
class ReviewSplit extends StatefulComponent {
  const ReviewSplit({super.key});

  @override
  State<ReviewSplit> createState() => _ReviewSplitState();
}

/// The slice of [AdminState] the split renders, selected as one value so the
/// rebuild trigger mirrors the old Selector scope.
typedef _ReviewData = ({
  VerificationQueuePage? page,
  VerificationQueueFilters filters,
  VerificationDetail? detail,
  String? busy,
  String? notice,
  String? error,
  bool loading,
});

class _ReviewSplitState extends State<ReviewSplit> {
  /// Which dimension's status tabs the queue is faceted by.
  VerificationDimension _dimension = VerificationDimension.listing;
  String? _selectedId;
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

  // --- Filter actions -------------------------------------------------------

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
    final next = _notifier.reviewFilters.copyWith(
      q: q,
      clearQ: q.isEmpty,
      offset: 0,
    );
    unawaited(_notifier.setReviewFilters(next));
  }

  void _setSort(String sort) {
    final next = _notifier.reviewFilters.copyWith(sort: sort, offset: 0);
    unawaited(_notifier.setReviewFilters(next));
  }

  void _toggleOrder() {
    final current = _notifier.reviewFilters;
    final next = current.copyWith(
      order: current.order == 'asc' ? 'desc' : 'asc',
      offset: 0,
    );
    unawaited(_notifier.setReviewFilters(next));
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

  void _select(String propertyId) {
    setState(() => _selectedId = propertyId);
    unawaited(_notifier.loadReviewDetail(propertyId));
  }

  // --- Build ----------------------------------------------------------------

  @override
  Component build(BuildContext context) {
    final data = context.watch(
      adminNotifierProvider.select(
        (state) => (
          page: state.reviewPage,
          filters: state.reviewFilters,
          detail: state.reviewDetail,
          busy: state.busyAction,
          notice: state.reviewNotice,
          error: state.error,
          loading: state.loading,
        ),
      ),
    );

    final items = data.page?.items ?? const <VerificationQueueRow>[];
    // Default the selection to the first row once a page arrives; the detail
    // load happens in a microtask so build stays side-effect free.
    if (_selectedId == null && items.isNotEmpty) {
      final first = '${items.first.propertyId}';
      Future.microtask(() {
        if (!mounted || _selectedId != null) return;
        _select(first);
      });
    }

    final detailMatches = data.detail != null &&
        '${data.detail!.property.propertyId}' == _selectedId;

    return div(classes: 'stack', [
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
      _toolbar(data),
      _tabs(data),
      div(classes: 'split', [
        div(classes: 'panel', [
          h2([Component.text(_countLine(data))]),
          if (items.isEmpty)
            EmptyState(
              title: data.loading
                  ? 'Loading…'
                  : data.error != null && data.page == null
                  ? 'Could not load the review queue'
                  : 'Queue is empty',
              body: data.loading
                  ? 'Fetching the review queue from the server.'
                  : data.error != null && data.page == null
                  ? 'The server did not return the queue, so its contents are '
                        'unknown. This is not an empty result.'
                  : 'No listing matches the current filters.',
              action: data.error != null && data.page == null && !data.loading
                  ? ActionButton(
                      'Try again',
                      variant: 'primary',
                      onClick: () => unawaited(_notifier.loadReviewPage()),
                    )
                  : null,
            )
          else
            div(classes: 'queue', [
              for (final item in items) _queueItem(item, data),
            ]),
          _pager(data),
        ]),
        div([
          if (_selectedId == null)
            const EmptyState(
              title: 'Select a listing',
              body: 'Choose a listing on the left to review its evidence.',
            )
          else if (detailMatches)
            div(classes: 'stack', [
              // Agent assignment lives on the standalone listing page. This is
              // the queue's path to it — a second assignment form here would
              // be a duplicate write surface for the same foreign key.
              div(classes: 'row row--md', [
                span(classes: 'grow small muted', [
                  const Component.text(
                    'Agent assignment is managed on the full listing record.',
                  ),
                ]),
                ActionLink(
                  'Open full listing record',
                  href:
                      '/admin/listing-detail?id=${Uri.encodeComponent(_selectedId!)}',
                  variant: 'secondary',
                  icon: 'open_in_new',
                ),
              ]),
              const VerificationDetailView(),
            ])
          else
            div(classes: 'card', [
              p(classes: 'body muted', [const Component.text('Loading…')]),
            ]),
        ]),
      ]),
    ]);
  }

  Component _toolbar(_ReviewData data) {
    final filters = data.filters;
    return div(classes: 'toolbar row', [
      div(classes: 'grow', [
        input(
          type: InputType.search,
          attributes: {
            'value': _query,
            'placeholder': 'Search title, address or company…',
            'aria-label': 'Search the review queue',
          },
          events: events<String>(
            onInput: (value) => setState(() => _query = value),
          ),
        ),
      ]),
      _dropdown(
        'Sort by',
        filters.sort,
        const {
          'submitted_at': 'Submission date',
          'updated_at': 'Last update',
          'title': 'Title',
          'price': 'Rent',
        },
        _setSort,
      ),
      ActionButton(
        filters.order == 'asc' ? 'Ascending' : 'Descending',
        onClick: data.busy == null ? _toggleOrder : null,
        variant: 'secondary',
        icon: filters.order == 'asc' ? 'arrow_upward' : 'arrow_downward',
      ),
      ActionButton('Search', onClick: _applyQuery, icon: 'search'),
      if (!filters.isPristine)
        ActionButton('Clear filters', onClick: _resetFilters, variant: 'ghost'),
    ]);
  }

  Component _dropdown(
    String label,
    String value,
    Map<String, String> options,
    void Function(String) onChanged,
  ) {
    return select(
      attributes: {'aria-label': label},
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

  /// Status tabs for the active dimension, with the backend's faceted counts
  /// (each dimension counted without its own status filter applied).
  Component _tabs(_ReviewData data) {
    final page = data.page;
    final active = _dimension == VerificationDimension.listing
        ? data.filters.listingStatus
        : data.filters.ownershipStatus;

    final defs = <(PropertyVerificationStatus?, String, int?)>[
      (null, 'All', page?.total),
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
        'Information requested',
        page?.countOf(
          _dimension,
          PropertyVerificationStatus.informationRequested,
        ),
      ),
    ];

    return div(
      classes: 'tabs row',
      attributes: {'role': 'tablist'},
      [
        for (final dimension in VerificationDimension.values)
          button(
            classes: 'tab${_dimension == dimension ? ' is-active' : ''}',
            attributes: {
              'type': 'button',
              'role': 'tab',
              'aria-selected': (_dimension == dimension).toString(),
            },
            events: events(
              onClick: () => setState(() => _dimension = dimension),
            ),
            [Component.text(dimension.label)],
          ),
        span(classes: 'grow', []),
        for (final (status, label, count) in defs)
          button(
            classes: 'tab${active == status ? ' is-active' : ''}',
            attributes: {
              'type': 'button',
              'role': 'tab',
              'aria-selected': (active == status).toString(),
            },
            events: events(onClick: () => _setStatus(status)),
            [Component.text(count == null ? label : '$label ($count)')],
          ),
      ],
    );
  }

  String _countLine(_ReviewData data) {
    final page = data.page;
    if (page == null) return 'Loading the queue…';
    final total = page.total;
    final from = total == 0 ? 0 : page.offset + 1;
    final to = (page.offset + page.limit).clamp(0, total);
    return '$total ${total == 1 ? 'listing' : 'listings'}'
        '${total > page.limit ? ' · showing $from–$to' : ''}';
  }

  Component _queueItem(VerificationQueueRow item, _ReviewData data) {
    final active = _selectedId == '${item.propertyId}';
    return button(
      classes: 'queue-item${active ? ' is-active' : ''}',
      attributes: {'type': 'button'},
      events: events(onClick: () => _select('${item.propertyId}')),
      [
        div(classes: 'shot', [const Icon('apartment', size: 'sm')]),
        div([
          h4([Component.text(item.displayName)]),
          _queueMetaLine(item),
        ]),
        div(classes: 'queue-item__meta stack', [
          for (final dimension in VerificationDimension.values)
            _rowPill(
              dimension == VerificationDimension.listing
                  ? item.listingStatus
                  : item.ownershipStatus,
            ),
          if (item.publicationEligible) const Pill('Live', tone: 'success'),
          // Management responsibility as the backend derived it. An unresolved
          // property is surfaced here so an administrator can act on it rather
          // than the queue implying someone is already responsible.
          if (item.management != null)
            Pill(
              item.management!.display,
              tone: switch (item.management!.type) {
                'agent' => 'action',
                'owner' => 'neutral',
                'platform' => 'neutral',
                _ => 'warning',
              },
            ),
        ]),
      ],
    );
  }

  /// Meta line under the queue title. Company and city stay muted text; the
  /// monthly rent is its own `.queue-item__rent` span so the Admin stylesheet
  /// can give the scannable datum ink weight instead of burying it in the
  /// muted line (the classes render as plain inline text without that CSS).
  Component _queueMetaLine(VerificationQueueRow item) {
    final prefix = [
      if (item.companyName != null) item.companyName!,
      if (item.city != null) item.city!,
    ].join(' · ');
    return p([
      if (prefix.isNotEmpty) Component.text(prefix),
      if (item.monthlyRent != null) ...[
        if (prefix.isNotEmpty)
          span(classes: 'queue-item__sep', [const Component.text(' · ')]),
        span(
          classes: 'queue-item__rent',
          [Component.text('RM${item.monthlyRent!.toStringAsFixed(0)}')],
        ),
      ],
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
    if (page == null || page.total <= page.limit) {
      return Component.fragment([]);
    }
    final filters = data.filters;
    final hasPrev = filters.offset > 0;
    final hasNext = filters.offset + page.limit < page.total;
    return div(classes: 'row', [
      ActionButton(
        'Previous',
        onClick: hasPrev ? () => _turnPage(-page.limit) : null,
        variant: 'secondary',
      ),
      ActionButton(
        'Next',
        onClick: hasNext ? () => _turnPage(page.limit) : null,
        variant: 'secondary',
      ),
    ]);
  }
}
