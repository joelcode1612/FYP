import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:sitewise_jaspr_web/core/di/app_locator.dart';
import 'package:sitewise_jaspr_web/features/administration/presentation/components/admin_ops_kit.dart';
import 'package:sitewise_jaspr_web/features/administration/data/admin_api.dart';
import 'package:sitewise_jaspr_web/shared/presentation/components/dashboard_kit.dart';
import 'package:sitewise_jaspr_web/shared/presentation/components/ui.dart';
import 'package:sitewise_jaspr_web/shared/presentation/layouts/app_layout.dart';

@client
class DashboardPage extends StatefulComponent {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  late Future<Map<String, dynamic>> _statistics = AppLocator.adminApi
      .dashboard();
  late Future<List<AuditEvent>> _activity = AppLocator.adminApi.listAudit();

  @override
  Component build(BuildContext context) => AppLayout(
    role: AppRole.admin,
    currentRoute: '/admin',
    title: 'Dashboard',
    subtitle: 'Property, account and inspection activity.',
    actions: const [
      ActionLink('Review queue', href: '/admin/listings'),
      ActionLink('Manage agents', href: '/admin/agents', variant: 'secondary'),
      ActionLink('Manage users', href: '/admin/users', variant: 'secondary'),
    ],
    child: div(classes: 'admin-dashboard stack stack--sections', [
      FutureBuilder<Map<String, dynamic>>(
        future: _statistics,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return SectionCard(
              title: 'Dashboard statistics',
              child: div(classes: 'stack', [
                const InlineEmpty('Statistics are unavailable.'),
                ActionButton(
                  'Try again',
                  variant: 'secondary',
                  onClick: () {
                    setState(() {
                      _statistics = AppLocator.adminApi.dashboard();
                    });
                  },
                ),
              ]),
            );
          }
          final data = snapshot.data;
          return data == null
              ? const Skeleton(variant: 'row', count: 4)
              : _analytics(data);
        },
      ),
      SectionCard(
        title: 'Recent activity',
        child: div(classes: 'stack', [
          FutureBuilder<List<AuditEvent>>(
            future: _activity,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return div(classes: 'stack', [
                  const InlineEmpty('Recent activity is unavailable.'),
                  ActionButton(
                    'Try again',
                    variant: 'secondary',
                    onClick: () {
                      setState(() {
                        _activity = AppLocator.adminApi.listAudit();
                      });
                    },
                  ),
                ]);
              }
              final events = snapshot.data;
              if (events == null) {
                return const Skeleton(variant: 'row', count: 3);
              }
              return events.isEmpty
                  ? const InlineEmpty('No activity recorded yet.')
                  : ol(classes: 'ad-viz-timeline', [
                      for (final event in events.take(6))
                        li([
                          strong([
                            Component.text(
                              _label(event.action.split('.').last),
                            ),
                          ]),
                          span(classes: 'muted', [
                            Component.text(
                              '${event.performedByEmail.isEmpty ? 'User not recorded' : event.performedByEmail} · ${_when(event.createdAt)}',
                            ),
                          ]),
                        ]),
                    ]);
            },
          ),
          const ActionLink(
            'View all activity',
            href: '/admin/activity',
            variant: 'secondary',
          ),
        ]),
      ),
    ]),
  );

  Component _analytics(Map<String, dynamic> data) {
    final total = data['total_properties'] as int;
    final published = data['published'] as int;
    final verification = _counts(data['verification']);
    final known = [
      'not_submitted',
      'pending',
      'under_review',
      'verified',
      'information_requested',
      'rejected',
    ];
    final other = verification.entries
        .where((entry) => !known.contains(entry.key))
        .fold(0, (sum, entry) => sum + entry.value);
    final states = _counts(data['states']).entries.toList()
      ..sort((first, second) => second.value.compareTo(first.value));
    final types = _counts(data['types']).entries.toList()
      ..sort((first, second) => second.value.compareTo(first.value));
    return div(classes: 'stack stack--sections', [
      div(classes: 'bento-kpis', [
        _kpi('Total properties', total, '/admin/listings'),
        _kpi('Published listings', published, '/admin/listings'),
        _kpi(
          'Pending property reviews',
          data['pending_reviews'] as int,
          '/admin/listings',
        ),
        _kpi(
          'Registered users',
          data['registered_users'] as int,
          '/admin/users',
        ),
      ]),
      div(classes: 'ad-viz-grid', [
        SectionCard(
          title: 'Publication status',
          child: _donut([
            ('Published', published),
            ('Unpublished', total - published),
          ]),
        ),
        SectionCard(
          title: 'Verification status',
          child: _bars([
            ('Not submitted', verification['not_submitted'] ?? 0),
            (
              'Awaiting review',
              (verification['pending'] ?? 0) +
                  (verification['under_review'] ?? 0),
            ),
            ('Approved', verification['verified'] ?? 0),
            ('Needs correction', verification['information_requested'] ?? 0),
            ('Rejected', verification['rejected'] ?? 0),
            if (other > 0) ('Other status', other),
          ]),
        ),
        SectionCard(
          title: 'Properties by state',
          child: div(classes: 'stack', [
            _bars(
              states.take(6).map((entry) => (entry.key, entry.value)).toList(),
            ),
            if (states.length > 6)
              details([
                summary([const Component.text('View remaining states')]),
                _bars(
                  states
                      .skip(6)
                      .map((entry) => (entry.key, entry.value))
                      .toList(),
                  maximum: states.first.value,
                ),
              ]),
          ]),
        ),
        SectionCard(
          title: 'Property type',
          child: _donut([for (final entry in types) (entry.key, entry.value)]),
        ),
        SectionCard(
          title: 'Registered accounts',
          child: _bars([
            for (final entry in _counts(data['roles']).entries)
              (
                switch (entry.key) {
                  'admin' => 'Administrator',
                  'owner' => 'Property owner',
                  'unknown' => 'Role not recorded',
                  _ => _label(entry.key),
                },
                entry.value,
              ),
          ]),
        ),
        SectionCard(
          title: 'Agent inspection workload',
          child: _workload(
            _rows(data['workload']),
            data['workload_available'] == true,
          ),
        ),
      ]),
      SectionCard(
        title: 'Awaiting property review',
        child: _reviewTable(_rows(data['reviews'])),
      ),
    ]);
  }
}

Map<String, int> _counts(Object? raw) => Map<String, int>.from(raw as Map);
List<Map<String, dynamic>> _rows(Object? raw) =>
    (raw as List).cast<Map<String, dynamic>>();

Component _kpi(String label, int value, String route) => AppLink(
  to: route,
  classes: 'kpi',
  children: [
    span(classes: 'k', [Component.text(label)]),
    span(classes: 'v', [Component.text('$value')]),
  ],
);

Component _bars(List<(String, int)> rows, {int? maximum}) {
  if (rows.isEmpty) return const InlineEmpty('No records yet.');
  final scale =
      maximum ?? rows.fold<int>(0, (max, row) => row.$2 > max ? row.$2 : max);
  return ul(classes: 'ad-viz-bars', [
    for (final (label, count) in rows)
      li([
        span([Component.text(label)]),
        strong([Component.text('$count')]),
        div(
          classes: 'ad-viz-track',
          attributes: const {'aria-hidden': 'true'},
          [
            if (scale > 0 && count > 0)
              span(attributes: {'style': 'width: ${count / scale * 100}%'}, []),
          ],
        ),
      ]),
  ]);
}

const _colors = [
  'var(--action)',
  '#64cfc6',
  'var(--warning)',
  '#a295e0',
  '#78a4a7',
  '#97a4bf',
];

Component _donut(List<(String, int)> rows) {
  final total = rows.fold(0, (sum, row) => sum + row.$2);
  var offset = 0;
  final segments = <String>[];
  for (final (index, row) in rows.indexed) {
    if (row.$2 == 0) continue;
    final start = offset / total * 100;
    offset += row.$2;
    segments.add(
      '${_colors[index % _colors.length]} $start% ${offset / total * 100}%',
    );
  }
  return div(classes: 'ad-viz-donut-layout', [
    div(
      classes: 'ad-viz-donut',
      attributes: {
        'aria-hidden': 'true',
        if (segments.isNotEmpty)
          'style': 'background: conic-gradient(${segments.join(', ')})',
      },
      [
        div([
          strong([Component.text('$total')]),
          const Component.text('Total properties'),
        ]),
      ],
    ),
    ul(classes: 'ad-viz-legend', [
      for (final (index, (label, count)) in rows.indexed)
        _legend(label, _colors[index % _colors.length], count: count),
      if (rows.isEmpty) li([const Component.text('No properties yet.')]),
    ]),
  ]);
}

Component _legend(String label, String color, {int? count}) => li([
  span(classes: 'ad-viz-key', attributes: {'style': 'background: $color'}, []),
  span([Component.text(label)]),
  if (count != null) strong([Component.text('$count')]),
]);

Component _workload(List<Map<String, dynamic>> rows, bool available) {
  if (!available) return const InlineEmpty('Agent workload is unavailable.');
  if (rows.isEmpty) return const InlineEmpty('No Agents registered yet.');
  int count(Map<String, dynamic> row, String key) => row[key] as int? ?? 0;
  List<int> active(Map<String, dynamic> row) => [
    count(row, 'requested'),
    count(row, 'ongoing') + count(row, 'needs_correction'),
    count(row, 'pending_review'),
  ];
  int sum(List<int> values) => values.fold(0, (total, value) => total + value);
  rows = [
    ...rows,
  ]..sort((first, second) => sum(active(second)).compareTo(sum(active(first))));
  final max = sum(active(rows.first));
  const labels = [
    'Pending requests',
    'Inspections in progress',
    'Awaiting Admin review',
  ];
  Component item(Map<String, dynamic> row) {
    final counts = active(row);
    return li([
      span([Component.text('${row['name']}')]),
      strong([Component.text('${count(row, 'completed')} completed')]),
      div(
        classes: 'ad-viz-track ad-viz-stacked',
        attributes: const {'aria-hidden': 'true'},
        [
          for (final (index, value) in counts.indexed)
            if (max > 0 && value > 0)
              span(
                attributes: {
                  'style':
                      'width: ${value / max * 100}%; background: ${_colors[index]}',
                },
                [],
              ),
        ],
      ),
      small([
        Component.text(
          '${counts[0]} requested · ${counts[1]} in progress · ${counts[2]} awaiting review',
        ),
      ]),
    ]);
  }

  return div(classes: 'stack', [
    ul(classes: 'ad-viz-legend ad-viz-inline', [
      for (final (index, label) in labels.indexed)
        _legend(label, _colors[index]),
    ]),
    ul(classes: 'ad-viz-bars', [for (final row in rows.take(6)) item(row)]),
    if (rows.length > 6)
      details([
        summary([const Component.text('View remaining Agents')]),
        ul(classes: 'ad-viz-bars', [for (final row in rows.skip(6)) item(row)]),
      ]),
  ]);
}

Component _reviewTable(List<Map<String, dynamic>> rows) => rows.isEmpty
    ? const InlineEmpty('No properties are awaiting review.')
    : DataTable(
        scrollLabel: 'Pending property reviews',
        columns: const [
          DataColumn('Property'),
          DataColumn('Location'),
          DataColumn('Assigned Agent'),
          DataColumn('Verification status'),
          DataColumn('Actions', actions: true),
        ],
        rows: [
          for (final row in rows)
            [
              Component.text(row['name'] as String? ?? 'Unnamed property'),
              Component.text(_location(row)),
              Component.text(row['agent'] as String? ?? 'Unassigned'),
              StatusBadge(
                row['status'] == 'under_review'
                    ? 'Under review'
                    : 'Awaiting review',
                tone: 'warning',
              ),
              ActionLink(
                'Review',
                href: '/admin/listing-detail?id=${row['id']}',
              ),
            ],
        ],
      );

String _location(Map<String, dynamic> row) {
  final parts = [row['city'], row['state']]
      .whereType<String>()
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toSet();
  return parts.isEmpty ? 'Location not recorded' : parts.join(', ');
}

String _label(String raw) {
  final value = raw.replaceAll('_', ' ').trim();
  return value.isEmpty
      ? 'Event not recorded'
      : '${value[0].toUpperCase()}${value.substring(1)}';
}

String _when(String raw) {
  final date = DateTime.tryParse(raw)?.toLocal();
  if (date == null) return 'Time not recorded';
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(date.day)}/${two(date.month)}/${date.year} · ${two(date.hour)}:${two(date.minute)}';
}
