import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:universal_web/web.dart' as web;

import '../../components/admin_ops_kit.dart';
import '../../components/dashboard_kit.dart';
import '../../components/ui.dart';
import '../../data/admin_api.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// System activity — administrative actions AND security events in one
/// server-filtered timeline (`/admin/activity`).
///
/// ## Data sources (reported honestly, never faked)
///
/// * **Administrative** — the existing `GET /api/v1/staff/audit` feed
///   (`public.role_change_audit`): agent invitations, activations,
///   suspensions, role changes, administrator MFA factor resets, listing
///   assignments, company registrations. Every line carries the performing
///   administrator.
/// * **Authentication / MFA** — `auth.audit_log_entries`, read only when the
///   backend can actually reach it. The backend probes that capability and
///   the source strip below renders the probe's real answer: on deployments
///   where Supabase does not expose the `auth` schema (the default), the
///   chips say "Not available" with the reason instead of pretending.
///   GoTrue also records successes only — failed sign-ins and failed MFA
///   verifications do not exist in that source, and the page says so.
///
/// Every filter (category, search, result, role, date window) and the
/// pagination are applied SERVER-SIDE via `GET /api/v1/staff/audit/security`,
/// so a search never downloads the whole audit history. The endpoint is
/// admin+MFA-gated; the browser never touches Supabase credentials.
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

  /// The roles the identity backend actually has (`rbac.ALL_ROLES`):
  /// administrator, property owner, agent, entrepreneur. Owner is its own role,
  /// not an entrepreneur who happens to hold property — filtering by it is how
  /// an administrator reviews owner-role changes.
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

  String _category = 'all';
  String _result = 'all';
  String _role = 'all';
  String _period = 'all';
  String _queryInput = '';
  String _committedQuery = '';
  Timer? _debounce;
  int _currentPage = 1;

  SecurityAuditEvent? _selected;
  bool _exporting = false;
  String? _exportMessage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  /// `24h`/`7d`/`30d` → an ISO UTC lower bound the backend applies
  /// server-side. UTC windows avoid pretending a timezone the browser never
  /// declared; the table itself formats to the browser's local time.
  String? get _dateFrom {
    final now = DateTime.now().toUtc();
    return switch (_period) {
      '24h' => now.subtract(const Duration(hours: 24)).toIso8601String(),
      '7d' => now.subtract(const Duration(days: 7)).toIso8601String(),
      '30d' => now.subtract(const Duration(days: 30)).toIso8601String(),
      _ => null,
    };
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await AppLocator.adminApi.fetchSecurityAudit(
        page: _currentPage,
        pageSize: _pageSize,
        category: _category,
        search: _committedQuery,
        result: _result,
        role: _role,
        dateFrom: _dateFrom,
      );
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = AdminApi.message(error);
      });
    }
  }

  void _restart({int page = 1}) {
    _debounce?.cancel();
    setState(() => _currentPage = page);
    _load();
  }

  void _onSearchInput(String value) {
    _queryInput = value;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      setState(() => _committedQuery = _queryInput);
      _restart();
    });
  }

  /// CSV export of AUTHORIZED records only: the backend returns the same
  /// filtered view with a bounded window (200 rows, the endpoint cap), and
  /// the page says exactly how many rows were included — never "everything".
  Future<void> _exportCsv() async {
    setState(() {
      _exporting = true;
      _exportMessage = null;
    });
    try {
      final data = await AppLocator.adminApi.fetchSecurityAudit(
        page: 1,
        pageSize: _exportCap,
        category: _category,
        search: _committedQuery,
        result: _result,
        role: _role,
        dateFrom: _dateFrom,
      );
      if (!mounted) return;
      final csv = AdminApi.securityAuditCsv(data.events);
      _saveCsv(csv);
      setState(() {
        _exporting = false;
        _exportMessage =
            'Exported ${data.events.length} authorized events matching the '
            'current filters${data.total > data.events.length
                ? ' (of ${data.total} total — export is capped at the most '
                      'recent $_exportCap)'
                : ''}.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _exporting = false;
        _exportMessage = 'Export failed: ${AdminApi.message(error)}';
      });
    }
  }

  /// Client-only download flow, same mechanism as verification documents.
  void _saveCsv(String csv) {
    final bytes = utf8.encode(csv);
    final blob = web.Blob(
      [bytes.toJS].toJS,
      web.BlobPropertyBag(type: 'text/csv;charset=utf-8'),
    );
    final url = web.URL.createObjectURL(blob);
    web.HTMLAnchorElement()
      ..href = url
      ..download = 'sitewise-system-activity.csv'
      ..click();
    web.URL.revokeObjectURL(url);
  }

  // --- Formatting helpers ---------------------------------------------------

  /// ISO → `15 Nov 2026 · 18:42`. Unparseable stamps pass through verbatim
  /// rather than masquerading as the epoch.
  String _when(String iso) {
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return iso.isEmpty ? 'Time not recorded' : iso;
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
    'info' => 'neutral',
    _ => 'neutral',
  };

  String _accountLabel(SecurityAuditEvent event) =>
      event.affectedEmail.isNotEmpty ? event.affectedEmail : event.affectedUserId;

  // --- Fragments ------------------------------------------------------------

  Component _sourceCard(String name, String icon, AuditSourceStatus status) {
    return div(classes: 'act-source', [
      div(classes: 'act-source__main', [
        span(classes: 'act-source__name', [Component.text(name)]),
        span(classes: 'act-source__detail', [Component.text(status.detail)]),
        span(
          classes:
              'act-chip ${status.available ? 'act-chip--ok' : 'act-chip--off'}',
          [Component.text(status.available ? 'Available' : 'Not available')],
        ),
      ]),
      span(classes: 'ops-tile', [Icon(icon)]),
    ]);
  }

  Component _tableBody() {
    final data = _data;
    if (_loading) return const Skeleton(variant: 'row', count: 6);
    if (_error != null) {
      return div(classes: 'stack', [
        Callout(
          'The audit feed could not be read: $_error',
          tone: 'danger',
          icon: 'error',
        ),
        p(classes: 'ops-qrow__meta', [
          Component.text(
            'This is usually the identity backend being unreachable from this '
            'environment — not an empty log. Retrying is safe; a read never '
            'writes anything.',
          ),
        ]),
        ActionButton('Try again', variant: 'secondary', onClick: _load),
      ]);
    }
    if (data == null || data.events.isEmpty) {
      final filtered = _committedQuery.isNotEmpty ||
          _category != 'all' ||
          _result != 'all' ||
          _role != 'all' ||
          _period != 'all';
      return InlineEmpty(
        filtered
            ? 'No audit events match these filters. Try a different search or '
                  'reset the filters.'
            : 'The audit sources returned no events yet. Nothing is invented '
                  'here: this deployment simply has no recorded activity.',
      );
    }
    return DataTable(
      columns: const [
        DataColumn('Activity'),
        DataColumn('Account'),
        DataColumn('Source'),
        DataColumn('Date & time'),
        DataColumn('Result'),
        DataColumn('Details', actions: true),
      ],
      rows: [
        for (final event in data.events)
          [
            CellIdentity(
              title: event.title,
              caption: '${event.action} · ${event.id}',
            ),
            CellIdentity(
              title: _accountLabel(event),
              caption: event.role ?? 'Role not recorded',
            ),
            Component.text(event.source),
            Component.text(_when(event.createdAt)),
            StatusBadge(
              event.resultLabel,
              tone: _resultTone(event.result),
              dot: true,
            ),
            ActionButton(
              'View',
              variant: 'ghost',
              onClick: () => _openDetails(event),
            ),
          ],
      ],
    );
  }

  Component _paginationFooter() {
    final data = _data;
    if (data == null || data.total == 0) return const span([]);
    final maxPage = (data.total / data.pageSize).ceil();
    final page = data.page;
    final first = (page - 1) * data.pageSize + 1;
    final last = (page * data.pageSize).clamp(0, data.total);

    Component pageBtn(int target, String label, {bool current = false}) {
      return button(
        classes: current ? 'act-pagebtn act-pagebtn--on' : 'act-pagebtn',
        attributes: {
          'type': 'button',
          'aria-label': label,
          if (current) 'aria-current': 'page',
        },
        events: current || target < 1 || target > maxPage
            ? null
            : events(onClick: () => _restart(page: target)),
        [Component.text(label)],
      );
    }

    // A small sliding window keeps long histories usable: at most seven
    // numbered buttons, anchored so the current page is always visible.
    final windowStart = (page - 3).clamp(1, (maxPage - 6).clamp(1, maxPage));
    final windowEnd = (windowStart + 6).clamp(1, maxPage);

    return div(classes: 'act-footer', [
      span(classes: 'act-pageinfo', [
        Component.text(
          maxPage <= 1
              ? '${data.total} event${data.total == 1 ? '' : 's'}'
              : 'Showing $first–$last of ${data.total} events · page $page of $maxPage',
        ),
      ]),
      div(classes: 'act-paging', [
        pageBtn(page - 1, 'Previous page', current: false),
        for (var n = windowStart; n <= windowEnd; n++)
          pageBtn(n, 'Page $n', current: n == page),
        pageBtn(page + 1, 'Next page'),
      ]),
    ]);
  }

  /// Opens the details dialog and moves focus into it. The shared
  /// [SitewiseDialog] handles Escape only for key events that originate
  /// INSIDE the dialog element, so focus must land there — the same pattern
  /// the reference HTML's drawer applies to its close button.
  void _openDetails(SecurityAuditEvent event) {
    setState(() => _selected = event);
    Future.delayed(const Duration(milliseconds: 30), () {
      final button = web.document.querySelector('[role="dialog"] button');
      if (button != null) (button as web.HTMLElement).focus();
    });
  }

  Component _detailDialog(SecurityAuditEvent event) {
    String fieldTitle(String raw) => raw
        .replaceAll('_', ' ')
        .replaceAllMapped(RegExp(r'^[a-z]'), (m) => m.group(0)!.toUpperCase());
    final rows = <InfoRow>[
      InfoRow(icon: 'tag', label: 'Event ID', value: event.id),
      InfoRow(icon: 'category', label: 'Category', value: event.categoryLabel),
      InfoRow(icon: 'bolt', label: 'Action', value: event.action),
      InfoRow(icon: 'schedule', label: 'Date & time', value: _when(event.createdAt)),
      InfoRow(
        icon: 'person',
        label: 'Affected account',
        value: _accountLabel(event).isEmpty
            ? 'Not recorded'
            : _accountLabel(event),
      ),
      InfoRow(icon: 'badge', label: 'Account role', value: event.role ?? 'Not available'),
      InfoRow(
        icon: 'admin_panel_settings',
        label: 'Performed by',
        value: event.performedByEmail.isNotEmpty
            ? event.performedByEmail
            : (event.source == 'Supabase Auth'
                  ? 'Self-service (the account holder)'
                  : 'Not recorded'),
      ),
      InfoRow(icon: 'check_circle', label: 'Result', value: event.resultLabel),
      InfoRow(icon: 'database', label: 'Source', value: event.source),
      for (final entry in event.details.entries)
        InfoRow(
          icon: 'description',
          label: fieldTitle(entry.key),
          value: entry.value,
        ),
    ];
    return SitewiseDialog(
      title: 'Audit event details',
      ariaLabel: 'Audit event details',
      wide: true,
      onClose: () => setState(() => _selected = null),
      body: div(classes: 'stack', [
        div(classes: 'act-detail-intro', [
          span(classes: 'act-detail-intro__title', [Component.text(event.title)]),
          span(classes: 'act-detail-intro__body', [Component.text(event.summary)]),
        ]),
        div(classes: 'stack', [for (final row in rows) row]),
        p(classes: 'act-detail-note', [
          Component.text(
            'Read-only record. Authentication events are recorded by Supabase '
            'Auth on success only; no credentials, codes or tokens are ever '
            'shown or stored here.',
          ),
        ]),
      ]),
      actions: [
        ActionButton(
          'Close',
          variant: 'secondary',
          onClick: () => setState(() => _selected = null),
        ),
      ],
    );
  }

  @override
  Component build(BuildContext context) {
    final data = _data;
    final notes = data?.notes ?? const <String>[];
    return AppLayout(
      role: AppRole.admin,
      currentRoute: '/admin/activity',
      title: 'System activity',
      eyebrow: 'Operations',
      subtitle:
          'Review administrative actions and security events from one place. '
          'Every filter and page is resolved by the backend; nothing is '
          'fabricated when a source is unavailable.',
      actions: [
        ActionButton(
          'Refresh',
          variant: 'secondary',
          icon: 'refresh',
          onClick: _load,
        ),
        ActionButton(
          'Export CSV',
          variant: 'secondary',
          icon: 'download',
          onClick: _exporting ? null : () => unawaited(_exportCsv()),
        ),
      ],
      child: div(classes: 'stack act-fade', [
        if (_exportMessage != null)
          Callout(_exportMessage!, tone: 'info', icon: 'info'),
        // Source coverage — the backend probe's real answer, not a static label.
        div(classes: 'act-sources', [
          _sourceCard(
            'Administrative actions',
            'history',
            data?.administrative ??
                const AuditSourceStatus(available: true, detail: 'Loading…'),
          ),
          _sourceCard(
            'Sign-in & registration',
            'group',
            data?.authentication ??
                const AuditSourceStatus(available: false, detail: 'Loading…'),
          ),
          _sourceCard(
            'MFA events',
            'lock',
            data?.mfa ?? const AuditSourceStatus(available: false, detail: 'Loading…'),
          ),
        ]),
        SectionCard(
          title: 'Activity timeline',
          flush: true,
          action: [
            span(classes: 'act-count', [
              Component.text(
                _loading
                    ? '…'
                    : '${data?.total ?? 0} event${(data?.total ?? 0) == 1 ? '' : 's'}',
              ),
            ]),
          ],
          child: div(classes: 'stack', [
            div(classes: 'act-tabs', [
              ChipRow(
                options: [
                  for (final (_, label) in _categories) label,
                ],
                selected: _categories
                    .firstWhere((c) => c.$1 == _category)
                    .$2,
                ariaLabel: 'Activity category',
                onSelect: (chosen) {
                  final next = _categories
                      .firstWhere(
                        (c) => c.$2 == chosen,
                        orElse: () => _categories.first,
                      )
                      .$1;
                  if (next == _category) return;
                  setState(() {
                    _category = next;
                    _queryInput = '';
                    _committedQuery = '';
                  });
                  _restart();
                },
              ),
            ]),
            div(classes: 'act-filters', [
              SearchInput(
                label: 'Search',
                placeholder: 'Search action, account or event ID',
                ariaLabel: 'Search audit events',
                onInput: _onSearchInput,
              ),
              _selectField(
                'Result',
                _results,
                _result,
                (value) {
                  setState(() => _result = value);
                  _restart();
                },
              ),
              _selectField(
                'Account role',
                _roles,
                _role,
                (value) {
                  setState(() => _role = value);
                  _restart();
                },
              ),
              _selectField(
                'Date range',
                _periods,
                _period,
                (value) {
                  setState(() => _period = value);
                  _restart();
                },
              ),
            ]),
            for (final note in notes)
              p(classes: 'ops-qrow__meta', [Component.text(note)]),
            _tableBody(),
            _paginationFooter(),
          ]),
        ),
        p(classes: 'act-bottom-note', [
          Icon('shield', size: 'sm'),
          Component.text(
            'This page is read-only. Audit data is exposed only through the '
            'admin + MFA-protected backend; no passwords, tokens or one-time '
            'codes are ever stored or displayed.',
          ),
        ]),
        if (_selected != null) _detailDialog(_selected!),
      ]),
    );
  }

  Component _selectField(
    String fieldLabel,
    List<(String, String)> options,
    String value,
    void Function(String) onChanged,
  ) {
    return Field(
      labelText: fieldLabel,
      // Jaspr's typed events deliver List<String> for <select> targets (the
      // selected options). events<String> here throws a runtime cast error in
      // the release bundle — a footgun the users page filters also carry.
      child: select(
        events: events<List<String>>(
          onInput: (values) {
            final next = values.firstOrNull;
            if (next != null && next != value) onChanged(next);
          },
        ),
        [
          for (final (optionValue, optionLabel) in options)
            option(
              value: optionValue,
              attributes: {if (optionValue == value) 'selected': ''},
              [Component.text(optionLabel)],
            ),
        ],
      ),
    );
  }
}
