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

  Component _coverageCard(
    String title,
    String subtitle,
    String icon,
    AuditSourceStatus? source,
  ) {
    final ready = source?.available == true;
    final known = source != null;
    return div(classes: 'sa-coverage-card', [
      div(classes: 'sa-coverage-top', [
        span(classes: 'sa-coverage-icon', [Icon(icon)]),
        span(classes: 'sa-source-status ${!known ? 'sa-source-status--loading' : ready ? 'sa-source-status--ready' : 'sa-source-status--off'}', [
          Component.text(!known ? 'Checking' : ready ? 'Available' : 'Unavailable'),
        ]),
      ]),
      strong(classes: 'sa-coverage-title', [Component.text(title)]),
      p(classes: 'sa-coverage-subtitle', [Component.text(subtitle)]),
      p(classes: 'sa-coverage-detail', [
        Component.text(source?.detail.isNotEmpty == true
            ? source!.detail
            : known ? 'No additional source details returned.' : 'Checking audit-source access…'),
      ]),
    ]);
  }

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
    return div(classes: 'sa-table-scroll', [
      table(classes: 'sa-table', [
        thead([
          tr([
            th([const Component.text('Event')]),
            th([const Component.text('Affected account')]),
            th([const Component.text('Performed by')]),
            th([const Component.text('Date & time')]),
            th([const Component.text('Result')]),
            th([const Component.text('')]),
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
    setState(() => _selected = event);
    Future<void>.delayed(const Duration(milliseconds: 30), () {
      if (!mounted) return;
      final target = web.document.querySelector('[role="dialog"] button');
      if (target is web.HTMLElement) target.focus();
    });
  }

  Component _detailsDialog(SecurityAuditEvent event) {
    String readable(String input) => input.replaceAll('_', ' ').replaceFirstMapped(
      RegExp(r'^[a-z]'), (match) => match.group(0)!.toUpperCase(),
    );
    return SitewiseDialog(
      title: 'Event details',
      ariaLabel: 'System activity event details',
      wide: true,
      onClose: () => setState(() => _selected = null),
      body: div(classes: 'sa-dialog-body', [
        div(classes: 'sa-dialog-intro', [
          div(classes: 'sa-dialog-kicker', [
            Component.text('${event.categoryLabel} · ${event.source}'),
          ]),
          strong(classes: 'sa-dialog-title', [Component.text(event.title)]),
          p(classes: 'sa-dialog-description', [Component.text(event.summary)]),
          StatusBadge(event.resultLabel, tone: _resultTone(event.result), dot: true),
        ]),
        div(classes: 'sa-dialog-grid', [
          InfoRow(icon: 'schedule', label: 'Recorded at', value: _when(event.createdAt)),
          InfoRow(icon: 'person', label: 'Affected account', value: _account(event)),
          InfoRow(icon: 'admin_panel_settings', label: 'Performed by', value: _actor(event)),
          InfoRow(icon: 'badge', label: 'Account role', value: event.role ?? 'Not recorded'),
          InfoRow(icon: 'bolt', label: 'Action', value: event.action),
          InfoRow(icon: 'tag', label: 'Event ID', value: event.id),
          for (final entry in event.details.entries)
            InfoRow(icon: 'description', label: readable(entry.key), value: entry.value),
        ]),
        p(classes: 'sa-dialog-footnote', [
          const Icon('shield', size: 'sm'),
          const Component.text(
            'Read-only audit record. Sensitive credentials and authentication tokens are not displayed.',
          ),
        ]),
      ]),
      actions: [
        ActionButton('Close', variant: 'secondary', onClick: () => setState(() => _selected = null)),
      ],
    );
  }

  @override
  Component build(BuildContext context) {
    final data = _data;
    return AppLayout(
      role: AppRole.admin,
      currentRoute: '/admin/activity',
      title: 'System activity',
      eyebrow: 'Security & operations',
      subtitle: 'Review account access, administrative actions and authentication activity from available audit sources.',
      actions: [
        ActionButton('Refresh', variant: 'secondary', icon: 'refresh', onClick: _loading ? null : () => unawaited(_load())),
        ActionButton(_exporting ? 'Exporting…' : 'Export CSV', variant: 'secondary', icon: 'download', onClick: _exporting ? null : () => unawaited(_exportCsv())),
      ],
      child: div(classes: 'sa-page stack stack--sections', [
        div(classes: 'sa-section-heading', [
          div(classes: 'sa-heading-copy', [
            span(classes: 'sa-eyebrow', [const Component.text('AUDIT COVERAGE')]),
            h2([const Component.text('Connected security sources')]),
            p([const Component.text('Source status comes from the backend. An unavailable source does not mean there were no events.')]),
          ]),
        ]),
        div(classes: 'sa-coverage-grid', [
          _coverageCard('Administrative actions', 'Staff and management changes', 'manage_accounts', data?.administrative),
          _coverageCard('Authentication', 'Account sign-in and registration', 'passkey', data?.authentication),
          _coverageCard('Multi-factor authentication', 'Authenticator and MFA records', 'shield_lock', data?.mfa),
        ]),
        if (_exportMessage != null)
          Callout(_exportMessage!, tone: _exportFailed ? 'danger' : 'success', icon: _exportFailed ? 'error' : 'download_done'),
        if (_error != null && data != null)
          Callout('Refresh failed: $_error. Last loaded events remain visible.', tone: 'warning', icon: 'warning'),
        section(classes: 'sa-panel', [
          div(classes: 'sa-panel-head', [
            div(classes: 'sa-heading-copy', [
              span(classes: 'sa-eyebrow', [const Component.text('EVENT LOG')]),
              h2([const Component.text('Security & activity history')]),
              p([const Component.text('Read-only, searchable events from the authorized audit feed')]),
            ]),
            span(classes: 'sa-total', [
              Component.text(_loading && data == null
                  ? 'Loading events…'
                  : '${data?.total ?? 0} matching ${data?.total == 1 ? 'event' : 'events'}'),
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
