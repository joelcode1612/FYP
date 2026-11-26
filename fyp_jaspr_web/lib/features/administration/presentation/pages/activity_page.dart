import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'package:sitewise_jaspr_web/features/administration/presentation/components/admin_ops_kit.dart';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:universal_web/web.dart' as web;

import 'package:sitewise_jaspr_web/shared/presentation/components/dashboard_kit.dart';
import 'package:sitewise_jaspr_web/shared/presentation/components/ui.dart';
import 'package:sitewise_jaspr_web/features/administration/data/admin_api.dart';
import 'package:sitewise_jaspr_web/core/di/app_locator.dart';
import 'package:sitewise_jaspr_web/shared/presentation/layouts/app_layout.dart';

/// Admin System Activity: responsive, read-only security and operations audit.
///
/// All rows, filters, source-availability statements and paging are returned by
/// GET /api/v1/staff/audit/security (administrator + MFA protected). This page
/// deliberately does NOT interpret an unavailable source as zero events.
/// Reuses the existing AdminApi, AppLayout and SitewiseDialog implementation.
@client
class AdminActivityPage extends StatefulComponent {
  const AdminActivityPage({super.key});

  @override
  State<AdminActivityPage> createState() => _ActivityState();
}

class _ActivityState extends State<AdminActivityPage> {
  static const _categories = <(String, String)>[
    ('all', 'All activity'),
    ('admin', 'Administrative'),
    ('auth', 'Authentication'),
    ('mfa', 'MFA'),
  ];
  static const _results = <(String, String)>[
    ('all', 'All results'),
    ('success', 'Successful'),
    ('failed', 'Failed'),
    ('info', 'Informational'),
  ];
  static const _roles = <(String, String)>[
    ('all', 'All roles'),
    ('admin', 'Administrator'),
    ('owner', 'Property Owner'),
    ('agent', 'Agent'),
    ('entrepreneur', 'Entrepreneur'),
  ];
  static const _periods = <(String, String)>[
    ('all', 'All dates'),
    ('24h', 'Last 24 hours'),
    ('7d', 'Last 7 days'),
    ('30d', 'Last 30 days'),
  ];
  static const _pageSize = 25;
  static const _exportCap = 200;

  SecurityAuditPage? _data;
  bool _loading = true;
  String? _error;
  int _loadSequence = 0;
  String _category = 'all';
  String _result = 'all';
  String _role = 'all';
  String _period = 'all';
  String _search = '';
  String _committedSearch = '';
  int _searchEpoch = 0;
  Timer? _debounce;
  int _currentPage = 1;
  SecurityAuditEvent? _selected;
  web.HTMLElement? _detailsTrigger;
  bool _exporting = false;
  String? _exportMessage;
  bool _exportFailed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _loadSequence++;
    _debounce?.cancel();
    super.dispose();
  }

  String? get _dateFrom {
    final now = DateTime.now().toUtc();
    return switch (_period) {
      '24h' => now.subtract(const Duration(hours: 24)).toIso8601String(),
      '7d' => now.subtract(const Duration(days: 7)).toIso8601String(),
      '30d' => now.subtract(const Duration(days: 30)).toIso8601String(),
      _ => null,
    };
  }

  /// Avoid out-of-order responses when administrators change filters quickly.
  /// Keep the previous server-confirmed page visible if a refresh fails.
  Future<void> _load() async {
    final sequence = ++_loadSequence;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snapshot = await AppLocator.adminApi.fetchSecurityAudit(
        page: _currentPage,
        pageSize: _pageSize,
        category: _category,
        search: _committedSearch,
        result: _result,
        role: _role,
        dateFrom: _dateFrom,
      );
      if (!mounted || sequence != _loadSequence) return;
      setState(() {
        _data = snapshot;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || sequence != _loadSequence) return;
      setState(() {
        _loading = false;
        _error = AdminApi.message(error);
      });
    }
  }

  void _restart({int page = 1}) {
    _debounce?.cancel();
    setState(() => _currentPage = page);
    unawaited(_load());
  }

  void _onSearchInput(String value) {
    _search = value;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      setState(() => _committedSearch = _search);
      _restart();
    });
  }

  void _resetFilters() {
    setState(() {
      _category = 'all';
      _result = 'all';
      _role = 'all';
      _period = 'all';
      _search = '';
      _committedSearch = '';
      _searchEpoch++;
    });
    _restart();
  }

  bool get _hasFilters =>
      _category != 'all' ||
      _result != 'all' ||
      _role != 'all' ||
      _period != 'all' ||
      _committedSearch.isNotEmpty;

  /// Bounded export: uses the same authenticated server filter and includes
  /// at most 200 rows, never claims to download the complete history.
  Future<void> _exportCsv() async {
    if (_exporting) return;
    setState(() {
      _exporting = true;
      _exportMessage = null;
      _exportFailed = false;
    });
    try {
      final snapshot = await AppLocator.adminApi.fetchSecurityAudit(
        page: 1,
        pageSize: _exportCap,
        category: _category,
        search: _committedSearch,
        result: _result,
        role: _role,
        dateFrom: _dateFrom,
      );
      if (!mounted) return;
      _saveCsv(AdminApi.securityAuditCsv(snapshot.events));
      setState(() {
        _exporting = false;
        _exportMessage =
            'Downloaded ${snapshot.events.length} matching events'
            '${snapshot.total > snapshot.events.length
                ? ' of ${snapshot.total} (export limit: $_exportCap events)'
                : ''}.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _exporting = false;
        _exportFailed = true;
        _exportMessage = 'Export failed: ${AdminApi.message(error)}';
      });
    }
  }

  void _saveCsv(String csv) {
    final blob = web.Blob(
      [utf8.encode(csv).toJS].toJS,
      web.BlobPropertyBag(type: 'text/csv;charset=utf-8'),
    );
    final url = web.URL.createObjectURL(blob);
    web.HTMLAnchorElement()
      ..href = url
      ..download = 'sitewise-system-activity.csv'
      ..click();
    web.URL.revokeObjectURL(url);
  }

  String _when(String iso) {
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return iso.isEmpty ? 'Not recorded' : iso;
    final local = parsed.toLocal();
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '${local.day} ${months[local.month - 1]} ${local.year} · $hh:$mm';
  }

  String _resultTone(String result) => switch (result) {
    'success' => 'success',
    'failed' => 'danger',
    _ => 'neutral',
  };

  String _account(SecurityAuditEvent event) {
    if (event.affectedEmail.isNotEmpty) return event.affectedEmail;
    if (event.affectedUserId.isNotEmpty) return event.affectedUserId;
    return 'Not recorded';
  }

  String _actor(SecurityAuditEvent event) {
    if (event.performedByEmail.isNotEmpty) return event.performedByEmail;
    if (event.source == 'Supabase Auth') return 'Account holder';
    return 'Not recorded';
  }

  String _eventIcon(SecurityAuditEvent event) => switch (event.category) {
    'auth' => 'login',
    'mfa' => 'verified_user',
    _ => 'admin_panel_settings',
  };

  Component _filters() => div(classes: 'sa-filter-area', [
    div(classes: 'sa-filter-grid', [
      div(classes: 'sa-search-field', [
        // Key recreates this uncontrolled input after an explicit Clear.
        SearchInput(
          key: ValueKey('sa-search-$_searchEpoch'),
          label: 'Search events',
          placeholder: 'Action, email, event ID…',
          ariaLabel: 'Search the security audit log',
          onInput: _onSearchInput,
        ),
      ]),
      _selectField('Result', _results, _result, (value) {
        setState(() => _result = value);
        _restart();
      }),
      _selectField('Account role', _roles, _role, (value) {
        setState(() => _role = value);
        _restart();
      }),
      _selectField('Date range', _periods, _period, (value) {
        setState(() => _period = value);
        _restart();
      }),
    ]),
    if (_hasFilters)
      div(classes: 'sa-filter-bottom', [
        span(classes: 'sa-filter-active', [
          const Icon('filter_alt', size: 'sm'),
          const Component.text('Filters applied'),
        ]),
        ActionButton('Clear filters', variant: 'ghost', onClick: _resetFilters),
      ]),
  ]);

  Component _selectField(
    String labelText,
    List<(String, String)> values,
    String current,
    void Function(String) onChanged,
  ) => Field(
    labelText: labelText,
    child: select(
      attributes: {'aria-label': labelText},
      events: events<List<String>>(
        onInput: (values) {
          final next = values.firstOrNull;
          if (next != null && next != current) onChanged(next);
        },
      ),
      [
        for (final (key, label) in values)
          option(
            value: key,
            attributes: key == current ? const {'selected': ''} : null,
            [Component.text(label)],
          ),
      ],
    ),
  );

  Component _categoryTabs() => div(
    classes: 'sa-tabs',
    attributes: const {'role': 'group', 'aria-label': 'Audit event category'},
    [
      for (final (key, label) in _categories)
        button(
          classes: 'sa-tab${_category == key ? ' sa-tab--selected' : ''}',
          attributes: {
            'type': 'button',
            'aria-pressed': (_category == key).toString(),
          },
          events: events(onClick: () {
            if (_category == key) return;
            setState(() => _category = key);
            _restart();
          }),
          [Component.text(label)],
        ),
    ],
  );

  Component _eventTable() {
    final data = _data;
    if (_loading && data == null) {
      return const Skeleton(variant: 'row', count: 6);
    }
    if (_error != null && data == null) {
      return div(classes: 'sa-state', [
        Callout('Security events could not be loaded: $_error', tone: 'danger', icon: 'error'),
        ActionButton('Try again', variant: 'secondary', onClick: () => unawaited(_load())),
      ]);
    }
    if (data == null || data.events.isEmpty) {
      return div(classes: 'sa-state', [
        InlineEmpty(
          _hasFilters
              ? 'No recorded events match the selected filters.'
              : 'The connected sources returned no events. This does not imply that unavailable audit sources contain no events.',
        ),
        if (_hasFilters)
          ActionButton('Clear filters', variant: 'secondary', onClick: _resetFilters),
      ]);
    }
    return div(
      classes: 'sa-table-scroll',
      attributes: const {
        'role': 'region',
        'aria-label': 'Activity history table, scroll horizontally if needed',
        'tabindex': '0',
      },
      [
      table(classes: 'sa-table', [
        thead([
          tr([
            th([const Component.text('Event')]),
            th([const Component.text('Affected account')]),
            th([const Component.text('Performed by')]),
            th([const Component.text('Date & time')]),
            th([const Component.text('Result')]),
            th([const Component.text('Action')]),
          ]),
        ]),
        tbody([
          for (final event in data.events)
            tr([
              td([
                div(classes: 'sa-event-cell', [
                  span(classes: 'sa-event-icon sa-event-icon--${event.category}', [
                    Icon(_eventIcon(event), size: 'sm'),
                  ]),
                  div(classes: 'sa-event-copy', [
                    strong(classes: 'sa-event-title', [Component.text(event.title)]),
                    span(classes: 'sa-event-meta', [
                      Component.text('${event.categoryLabel} · ${event.source}'),
                    ]),
                  ]),
                ]),
              ]),
              td([
                div(classes: 'sa-person-cell', [
                  span(classes: 'sa-person-primary', [Component.text(_account(event))]),
                  span(classes: 'sa-person-muted', [
                    Component.text(event.role ?? 'Role not recorded'),
                  ]),
                ]),
              ]),
              td([
                span(classes: 'sa-actor', [Component.text(_actor(event))]),
              ]),
              td([
                span(classes: 'sa-date', [Component.text(_when(event.createdAt))]),
              ]),
              td([
                StatusBadge(event.resultLabel, tone: _resultTone(event.result), dot: true),
              ]),
              td(classes: 'sa-table-actions', [
                ActionButton('View details', variant: 'ghost', onClick: () => _openDetails(event)),
              ]),
            ]),
        ]),
      ]),
    ]);
  }

  Component _pager() {
    final data = _data;
    if (data == null || data.total == 0) return const span([]);
    final lastPage = (data.total / data.pageSize).ceil();
    final current = data.page;
    final firstRow = (current - 1) * data.pageSize + 1;
    final lastRow = (current * data.pageSize).clamp(0, data.total);

    return div(classes: 'sa-pager', [
      span(classes: 'sa-pager-summary', [
        Component.text('Showing $firstRow–$lastRow of ${data.total} matching events'),
      ]),
      div(classes: 'sa-pager-actions', [
        ActionButton('Previous', variant: 'secondary', onClick: _loading || current <= 1
            ? null : () => _restart(page: current - 1)),
        span(classes: 'sa-page-current', [Component.text('$current / $lastPage')]),
        ActionButton('Next', variant: 'secondary', onClick: _loading || current >= lastPage
            ? null : () => _restart(page: current + 1)),
      ]),
    ]);
  }

  void _openDetails(SecurityAuditEvent event) {
    final active = web.document.activeElement;
    _detailsTrigger = active != null && active.isA<web.HTMLElement>()
        ? active as web.HTMLElement
        : null;
    setState(() => _selected = event);
    Future<void>.delayed(const Duration(milliseconds: 30), () {
      if (!mounted) return;
      final target = web.document.querySelector('.dialog--sa-event-details button');
      if (target != null && target.isA<web.HTMLElement>()) {
        (target as web.HTMLElement).focus();
      }
    });
  }

  void _closeDetails() {
    final trigger = _detailsTrigger;
    _detailsTrigger = null;
    setState(() => _selected = null);
    Future<void>.delayed(const Duration(milliseconds: 30), () {
      if (mounted && _selected == null) trigger?.focus();
    });
  }

  Component _detailsDialog(SecurityAuditEvent event) {
    // SITEWISE_ACTIVITY_DETAILS_V1 — presentation only.
    String readable(String input) => input.replaceAll('_', ' ').replaceFirstMapped(
      RegExp(r'^[a-z]'), (match) => match.group(0)!.toUpperCase(),
    );
    final details = event.details;
    final hasRole = details.containsKey('previous_role') || details.containsKey('new_role');
    final hasStatus = details.containsKey('previous_status') || details.containsKey('new_status');
    final changeKeys = {'previous_role', 'new_role', 'previous_status', 'new_status'};
    final otherDetails = details.entries.where((entry) => !changeKeys.contains(entry.key)).toList();
    Component valueTile(String label, String? value, {bool current = false}) {
      return div(classes: 'sa-dv-value${current ? ' sa-dv-value--current' : ''}', [
        span(classes: 'sa-dv-label', [Component.text(label)]),
        strong([Component.text(value == null || value.trim().isEmpty ? 'Not recorded' : value)]),
      ]);
    }
    Component changeRow(String label, String? before, String? after) {
      final unchanged = before != null && after != null && before == after;
      return div(classes: 'sa-dv-change', [
        div(classes: 'sa-dv-change-label', [
          strong([Component.text(label)]),
          if (unchanged) span(classes: 'sa-dv-unchanged', [const Component.text('Unchanged')]),
        ]),
        div(classes: 'sa-dv-change-values', [
          valueTile('Previous', before),
          valueTile('New', after, current: !unchanged && before != null && after != null),
        ]),
      ]);
    }
    return SitewiseDialog(
      title: 'Event details',
      ariaLabel: 'System activity event details',
      wide: true,
      panelClass: 'dialog--sa-event-details',
      onClose: _closeDetails,
      body: div(classes: 'sa-dialog-body sa-dv-body', [
        div(classes: 'sa-dv-summary', [
          div(classes: 'sa-dv-symbol', [const Icon('shield', size: 'lg')]),
          div(classes: 'sa-dv-summary-copy', [
            div(classes: 'sa-dv-kicker', [Component.text('${event.categoryLabel} · ${event.source}')]),
            h3([Component.text(event.title)]),
            p([Component.text(event.summary)]),
          ]),
          StatusBadge(event.resultLabel, tone: _resultTone(event.result), dot: true),
        ]),
        div(classes: 'sa-dv-columns', [
          div(classes: 'sa-dv-section', [
            h3([const Component.text('Event information')]),
            div(classes: 'sa-dv-fields', [
              valueTile('Action', readable(event.action)),
              valueTile('Recorded at', _when(event.createdAt)),
              valueTile('Affected account', _account(event)),
              valueTile('Performed by', _actor(event)),
              valueTile('Account role', event.role),
              valueTile('Result', event.resultLabel),
              valueTile('Source', event.source),
              valueTile('Event ID', event.id),
            ]),
          ]),
          if (hasRole || hasStatus) div(classes: 'sa-dv-section', [
            h3([const Component.text('Account changes')]),
            if (hasRole) changeRow('Role', details['previous_role'], details['new_role']),
            if (hasStatus) changeRow('Account status', details['previous_status'], details['new_status']),
          ]),
          if (otherDetails.isNotEmpty) div(classes: 'sa-dv-section', [
            h3([const Component.text('Additional audit information')]),
            div(classes: 'sa-dv-fields', [
              for (final entry in otherDetails)
                valueTile(readable(entry.key), entry.value),
            ]),
          ]),
          div(classes: 'sa-dv-note', [
            const Icon('shield', size: 'sm'),
            div([
              strong([const Component.text('Read-only audit record')]),
              p([const Component.text('Sensitive credentials and authentication tokens are not displayed.')]),
            ]),
          ]),
        ]),
      ]),
      actions: [
        ActionButton('Close', variant: 'secondary', onClick: _closeDetails),
      ],
    );
  }

  @override
  Component build(BuildContext context) {
    final data = _data;
    final sources = <AuditSourceStatus?>[
      data?.administrative,
      data?.authentication,
      data?.mfa,
    ];
    final unavailableSources = sources.where((entry) => entry?.available == false).length;
    return AppLayout(
      role: AppRole.admin,
      currentRoute: '/admin/activity',
      title: 'System activity',
      eyebrow: 'Security & operations',
      subtitle: 'Search and review recorded system activity.',
      actions: [
        ActionButton('Refresh', variant: 'secondary', icon: 'refresh', onClick: _loading ? null : () => unawaited(_load())),
        ActionButton(_exporting ? 'Exporting…' : 'Export CSV', variant: 'secondary', icon: 'download', onClick: _exporting ? null : () => unawaited(_exportCsv())),
      ],
      child: div(classes: 'sa-page stack stack--sections', [
        if (unavailableSources > 0)
          div(classes: 'sa-coverage-notice', [
            const Icon('info', size: 'sm'),
            div(classes: 'sa-coverage-notice-copy', [
              strong([const Component.text('Some audit sources are unavailable')]),
              p([const Component.text(
                'The table contains events from accessible sources only. '
                'Unavailable sources may still contain events.'
              )]),
            ]),
          ]),
        if (_exportMessage != null)
          Callout(_exportMessage!, tone: _exportFailed ? 'danger' : 'success', icon: _exportFailed ? 'error' : 'download_done'),
        if (_error != null && data != null)
          Callout('Refresh failed: $_error. Last loaded events remain visible.', tone: 'warning', icon: 'warning'),
        section(classes: 'sa-panel', [
          div(classes: 'sa-panel-head', [
            div(classes: 'sa-heading-copy', [
              h2([const Component.text('Activity history')]),
              p([const Component.text('Read-only, searchable events from the authorized audit feed')]),
            ]),
            span(classes: 'sa-total', [
              Component.text(data == null
                  ? (_loading ? 'Loading events…' : 'Events unavailable')
                  : '${data.total} matching ${data.total == 1 ? 'event' : 'events'}'),
            ]),
          ]),
          _categoryTabs(),
          _filters(),
          if (data?.notes.isNotEmpty == true)
            div(classes: 'sa-notes', [
              for (final note in data!.notes)
                p([const Icon('info', size: 'sm'), Component.text(note)]),
            ]),
          _eventTable(),
          _pager(),
        ]),
        p(classes: 'sa-readonly', [
          const Icon('lock', size: 'sm'),
          const Component.text('Read-only audit access · Administrator MFA required · Export limited to 200 filtered events'),
        ]),
        if (_selected != null) _detailsDialog(_selected!),
      ]),
    );
  }
}
