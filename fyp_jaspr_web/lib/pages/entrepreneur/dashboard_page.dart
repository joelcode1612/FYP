import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
// The KPI count uses the web catalogue repository, not the shared one.
import 'package:shared_logic/shared_logic.dart' hide ApiPropertyRepository;

import '../../components/ui.dart';
import '../../data/assessment_api.dart';
import '../../data/api_property_repository.dart';
import '../../data/auth_service.dart';
import '../../layouts/app_layout.dart';

/// Web entrepreneur home, restructured to the workspace-home mockup:
///
/// ```text
/// ┌──────────────────────────────────────────┐
/// │ Welcome back, NAME 👋 + subtitle          │
/// │ 4-KPI row (catalogue / saved / asmts /   │
/// │           reports)                        │
/// │ Current Assessment card (thumbnail,      │
/// │   progress, current stage, Continue)     │
/// │ Quick Actions (3 cards)                  │
/// │ Recent Assessments (rows + View All)     │
/// └──────────────────────────────────────────┘
/// ```
///
/// Every figure is live: the catalogue read, the account's saved shortlist,
/// and the persisted assessment history (`GET /api/v1/assessments/me`) — or
/// an honest zero / em dash. Nothing from the mockup's sample numbers
/// (12 / 4 / 2 / 1, "Alex", "Taman Universiti Shoplot") is fabricated here.
@client
class DashboardPage extends StatefulComponent {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  /// One parallel load for everything the KPI row and the Recent Assessments
  /// list need. The Current Assessment card keeps its own loader so a slow
  /// read never holds up the rest of the dashboard.
  late Future<HomeStats> _stats = _loadStats();

  Future<HomeStats> _loadStats() async {
    final history = await const AssessmentApi().history(limit: 50);
    if (!history.ok) {
      return HomeStats(failure: history.failure);
    }
    final rows = history.value!.items;
    // The catalogue count is auxiliary: a failed read shows an em dash on one
    // KPI instead of failing the whole dashboard.
    int? catalogue;
    try {
      catalogue = (await ApiPropertyRepository().getProperties()).length;
    } on Object {
      catalogue = null;
    }
    return HomeStats(
      assessments: history.value!.total,
      reports: rows.where((r) => r.reportAvailable).length,
      recent: rows.take(4).toList(),
      catalogueCount: catalogue,
    );
  }

  void _reload() => setState(() => _stats = _loadStats());

  /// First word of the backend-verified profile name — never a hardcoded
  /// demo identity. An empty name degrades to a plain welcome.
  String get _welcomeName {
    final profile = WebAuth.profile;
    final raw =
        ((profile?['full_name'] ?? profile?['name']) as String?)?.trim() ?? '';
    if (raw.isEmpty) return '';
    return raw.split(RegExp(r'\s+')).first;
  }

  @override
  Component build(BuildContext context) {
    final saved = context.watch(
      appNotifierProvider.select((state) => state.saved),
    );
    final name = _welcomeName;
    return AppLayout(
      role: AppRole.entrepreneur,
      currentRoute: '/entrepreneur',
      title: 'Home',
      // The welcome header is the page's own first element — no separate
      // page-title band above it.
      showPageHead: false,
      child: div(classes: 'stack stack--sections sw-dash', [
        _head(name),
        FutureBuilder<HomeStats>(
          future: _stats,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Skeleton(variant: 'block', count: 3);
            }
            final stats = snapshot.data;
            if (stats == null) {
              return _statsError('No response from the data service.');
            }
            if (stats.failure != null) {
              return _statsError(stats.failure!.message);
            }
            return div(classes: 'stack stack--sections', [
              _kpis(stats, saved),
              // Compact overview of the most recently updated saved
              // assessment. It loads on its own so a slow or failed read
              // never holds up the rest of the dashboard.
              const _CurrentAssessment(),
              _quickActions(saved),
              _recent(stats.recent),
            ]);
          },
        ),
        // DESIGN.md §17: a concise, visible disclaimer near decision-support
        // output. Progress percentages here are server-derived stage counts,
        // never model scores, and this note keeps that boundary explicit.
        p(classes: 'stat-note', [
          Component.text(
            'Sitewise supports location decision-making. Assessments and '
            'recommendations do not guarantee business success or confirm '
            'regulatory approval. Verify important property and licensing '
            'information independently.',
          ),
        ]),
      ]),
    );
  }

  // ------------------------------------------------------------------- head

  Component _head(String name) {
    return header(classes: 'sw-dash-head', [
      p(classes: 'sw-dash-kicker', [
        Component.text('Entrepreneur Workspace'),
      ]),
      h1(classes: 'sw-dash-title', [
        Component.text(name.isEmpty ? 'Welcome back' : 'Welcome back, $name'),
        span(classes: 'sw-dash-wave', attributes: const {'aria-hidden': 'true'}, [
          Component.text('👋'),
        ]),
      ]),
      p(classes: 'sw-dash-sub', [
        Component.text(
          'Find, assess and choose the right commercial location for your '
          'business.',
        ),
      ]),
    ]);
  }

  Component _statsError(String message) {
    return div(classes: 'card stack', [
      span(classes: 'title', [Component.text('Something went wrong')]),
      p(classes: 'body', [Component.text(message)]),
      ActionButton('Try again', variant: 'secondary', onClick: _reload),
    ]);
  }

  // -------------------------------------------------------------------- KPIs

  Component _kpis(HomeStats stats, Set<String> saved) {
    return div(classes: 'sw-kpi-grid', [
      _kpi(
        'place',
        '#1d4ed8',
        'Explore Properties',
        stats.catalogueCount == null
            ? '—'
            : '${stats.catalogueCount}',
        'Commercial listings',
        '/entrepreneur/explore',
      ),
      _kpi(
        'bookmark',
        '#7c3aed',
        'Saved Properties',
        '${saved.length}',
        saved.length == 1 ? 'Property shortlisted' : 'Properties shortlisted',
        '/entrepreneur/saved',
      ),
      _kpi(
        'fact_check',
        '#059669',
        'Assessments',
        '${stats.assessments}',
        'Started by you',
        '/entrepreneur/assessments',
      ),
      _kpi(
        'description',
        '#475569',
        'Reports',
        '${stats.reports}',
        stats.reports == 1 ? 'Report ready' : 'Reports ready',
        '/entrepreneur/assessments',
      ),
    ]);
  }

  Component _kpi(
    String icon,
    String color,
    String label,
    String value,
    String note,
    String href,
  ) => AppLink(
    to: href,
    classes: 'kpi-card sw-kpi-button',
    children: [
      div(classes: 'kpi-top', [
        div(
          classes: 'kpi-ico',
          styles: Styles(raw: {'background': '${color}14', 'color': color}),
          [Icon(icon, size: 'sm')],
        ),
        span(classes: 'kpi-label', [Component.text(label)]),
      ]),
      div(classes: 'kpi-value', [Component.text(value)]),
      div(classes: 'kpi-note', [Component.text(note)]),
    ],
  );

  // ------------------------------------------------------------ quick actions

  Component _quickActions(Set<String> saved) {
    return section(classes: 'sw-dash-section', [
      div(classes: 'sw-dash-section-head', [
        h2([Component.text('Quick Actions')]),
      ]),
      div(classes: 'sw-dash-quick-grid', [
        _quick(
          'search',
          'Explore Properties',
          'Discover commercial properties in your area.',
          '/entrepreneur/explore',
        ),
        _quick(
          'auto_awesome',
          'View Recommendations',
          'See properties matched to your preferences.',
          '/entrepreneur/recommendations',
        ),
        _quick(
          'bookmark',
          'Saved Properties',
          saved.isEmpty
              ? 'Review your shortlisted properties.'
              : 'Review your ${saved.length} shortlisted '
                    '${saved.length == 1 ? 'property' : 'properties'}.',
          '/entrepreneur/saved',
        ),
      ]),
    ]);
  }

  Component _quick(String icon, String title, String hint, String href) =>
      AppLink(
        to: href,
        classes: 'sw-dash-quick',
        children: [
          span(classes: 'sw-dash-quick-tile', [Icon(icon, size: 'md')]),
          strong([Component.text(title)]),
          small([Component.text(hint)]),
        ],
      );

  // ------------------------------------------------------- recent assessments

  Component _recent(List<AssessmentRecord> rows) {
    return section(classes: 'sw-dash-section', [
      div(classes: 'sw-dash-section-head', [
        h2([Component.text('Recent Assessments')]),
        AppLink(
          to: '/entrepreneur/assessments',
          classes: 'sw-dash-viewall',
          children: [
            Component.text('View All'),
            span(attributes: const {'aria-hidden': 'true'}, [
              Component.text('→'),
            ]),
          ],
        ),
      ]),
      if (rows.isEmpty)
        div(classes: 'sw-dash-recent', [
          div(classes: 'sw-home-empty', [
            Icon('fact_check', size: 'lg'),
            p(classes: 'sw-home-detail', [
              Component.text(
                'No assessments yet. Open a property and begin the five-stage '
                'location assessment — it is saved to your account as you go.',
              ),
            ]),
            AppLink(
              to: '/entrepreneur/explore',
              classes: 'sw-home-primary',
              children: [
                Component.text('Find a property to assess '),
                span(attributes: const {'aria-hidden': 'true'}, [
                  Component.text('→'),
                ]),
              ],
            ),
          ]),
        ])
      else
        div(classes: 'sw-dash-recent', [
          for (final record in rows) _recentRow(record),
        ]),
    ]);
  }

  Component _recentRow(AssessmentRecord record) {
    final property = record.property;
    final place = property == null
        ? 'Property ${record.propertyId}'
        : [
            property.city,
            property.state,
          ].where((part) => part.trim().isNotEmpty).join(', ');
    final pct = record.progressPercent.clamp(0, 100);
    return AppLink(
      to: '/entrepreneur/assessment?id=${record.propertyId}',
      classes: 'sw-dash-rrow',
      children: [
        _thumb(property?.imageUrl, property == null),
        span(classes: 'sw-dash-rrow-copy', [
          strong([
            Component.text(
              property?.title ?? 'Listing no longer in the catalogue',
            ),
          ]),
          small([Component.text(place)]),
        ]),
        StatusBadge(
          record.isCompleted ? 'Completed' : 'In progress',
          tone: record.isCompleted ? 'success' : 'action',
        ),
        span(classes: 'sw-dash-rrow-track${record.isCompleted ? ' sw-dash-rrow-track--done' : ''}', [
          span(
            styles: Styles(raw: {'width': '$pct%'}),
            [],
          ),
        ]),
        span(classes: 'sw-dash-rrow-pct', [Component.text('$pct%')]),
        Icon('chevron_right', size: 'sm'),
      ],
    );
  }

  /// Listing photo when the catalogue has one; a neutral placeholder tile
  /// when it does not (a removed listing shows an icon, never a fake photo).
  Component _thumb(String? imageUrl, bool removed) {
    final url = imageUrl;
    if (url == null || url.isEmpty) {
      return div(classes: 'sw-dash-thumb', [
        Icon(removed ? 'storefront' : 'image', size: 'md'),
      ]);
    }
    return div(classes: 'sw-dash-thumb', [
      img(
        src: url,
        alt: 'Property photo',
        width: 120,
        height: 88,
        attributes: const {'loading': 'lazy'},
      ),
    ]);
  }
}

/// Everything the KPI row and Recent Assessments section need, from one
/// parallel backend read. `catalogueCount == null` means the catalogue read
/// failed and the card shows an em dash rather than a fabricated zero.
class HomeStats {
  final AssessmentFailure? failure;
  final int assessments;
  final int reports;
  final List<AssessmentRecord> recent;
  final int? catalogueCount;

  const HomeStats({
    this.failure,
    this.assessments = 0,
    this.reports = 0,
    this.recent = const [],
    this.catalogueCount,
  });
}

/// The most recently updated saved assessment, restyled to the mockup's
/// "Current Assessment" card: photo, title, location, progress bar with
/// "N of 5 stages completed", the current stage as a pill, and one Continue
/// action.
///
/// Every figure is read from `GET /api/v1/assessments/me/current`. The backend
/// resolves "most recently updated" when several assessments exist, so this
/// card never picks a record by its own rule and never invents one when the
/// entrepreneur has not started an assessment.
///
/// Not annotated `@client`: Jaspr allows one per library and `DashboardPage`
/// already carries it. A nested `StatefulComponent` inside a hydrated `@client`
/// subtree is still interactive — the same pattern as `_Directory` in
/// `pages/admin/users_page.dart`.
class _CurrentAssessment extends StatefulComponent {
  const _CurrentAssessment();

  @override
  State<_CurrentAssessment> createState() => _CurrentAssessmentState();
}

class _CurrentAssessmentState extends State<_CurrentAssessment> {
  static const _api = AssessmentApi();

  late Future<ApiResult<AssessmentRecord?>> _future = _api.current();

  void _reload() => setState(() => _future = _api.current());

  @override
  Component build(BuildContext context) {
    return FutureBuilder<ApiResult<AssessmentRecord?>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _frame(const Skeleton(variant: 'row', count: 3));
        }
        final result = snapshot.data;
        if (result == null) return _frame(_inlineError('No response.', null));
        if (!result.ok) {
          return _frame(
            _inlineError(result.failure!.message, result.failure!.kind),
          );
        }
        final record = result.value;
        if (record == null) return _frame(_empty());
        return _frame(_summary(record));
      },
    );
  }

  /// The shared card frame, so loading, empty, error and summary states all
  /// occupy the same place in the page and the layout never jumps.
  Component _frame(Component body) => section(classes: 'sw-dash-section', [
    div(classes: 'sw-dash-section-head', [
      h2([Component.text('Current Assessment')]),
      AppLink(
        to: '/entrepreneur/assessments',
        classes: 'sw-dash-viewall',
        children: [
          Component.text('View all assessments'),
          span(attributes: const {'aria-hidden': 'true'}, [
            Component.text('→'),
          ]),
        ],
      ),
    ]),
    div(classes: 'sw-dash-ca', [body]),
  ]);

  Component _empty() => div(classes: 'sw-home-empty sw-dash-ca-empty', [
    Icon('fact_check', size: 'lg'),
    p(classes: 'sw-home-detail', [
      Component.text(
        'No assessment started yet. Open a property and begin the '
        'five-stage location assessment — it is saved to your account as '
        'you go, so you can leave it part-finished.',
      ),
    ]),
    AppLink(
      to: '/entrepreneur/explore',
      classes: 'sw-home-primary',
      children: [
        Component.text('Find a property to assess '),
        span(attributes: const {'aria-hidden': 'true'}, [Component.text('→')]),
      ],
    ),
  ]);

  /// A failure here is contained: the rest of the dashboard is still usable,
  /// so this renders a short notice with a retry rather than an error page.
  /// An expired session says so instead of pretending there are no records.
  Component _inlineError(String message, AssessmentFailureKind? kind) {
    final signedOut = kind == AssessmentFailureKind.unauthorized;
    return div(classes: 'sw-home-empty sw-dash-ca-empty', [
      Icon(signedOut ? 'lock' : 'error', size: 'lg'),
      p(classes: 'sw-home-detail', [
        Component.text(
          signedOut
              ? 'Your session is not authorised to read assessments. Sign in '
                    'again to see your saved progress.'
              : 'The current assessment could not be loaded. $message',
        ),
      ]),
      if (signedOut)
        AppLink(
          to: '/login',
          classes: 'sw-home-primary',
          children: [Component.text('Go to sign in')],
        )
      else
        ActionButton('Try again', variant: 'secondary', onClick: _reload),
    ]);
  }

  Component _summary(AssessmentRecord record) {
    final property = record.property;
    final stage = record.stageByKey(record.currentStageKey);
    final pct = record.progressPercent.clamp(0, 100);
    return div(classes: 'sw-dash-ca-body', [
      h3([
        Component.text(property?.title ?? 'Listing no longer in the catalogue'),
      ]),
      p(classes: 'sw-dash-ca-loc', [
        Icon('place', size: 'sm'),
        Component.text(
          property == null
              ? 'Property ${record.propertyId}'
              : [property.address, property.city]
                    .where((part) => part.trim().isNotEmpty)
                    .join(', '),
        ),
      ]),
      div(classes: 'sw-home-progress-copy', [
        span([
          Component.text(
            record.isCompleted
                ? 'All ${record.totalStages} stages completed'
                : '${record.completedStages} of ${record.totalStages} stages '
                      'completed',
          ),
        ]),
        strong([Component.text('$pct%')]),
      ]),
      div(
        classes: 'sw-home-progress-track',
        attributes: {
          'role': 'progressbar',
          'aria-label': 'Assessment progress',
          'aria-valuenow': '$pct',
          'aria-valuemin': '0',
          'aria-valuemax': '100',
        },
        [
          span(
            styles: Styles(raw: {'width': '$pct%'}),
            [],
          ),
        ],
      ),
      div(classes: 'sw-dash-stage-row', [
        span([Component.text('Current Stage:')]),
        StatusBadge(
          stage?.title ?? (record.isCompleted ? 'Completed' : 'In progress'),
          tone: record.isCompleted ? 'success' : 'action',
        ),
      ]),
      div(classes: 'sw-dash-ca-actions', [
        AppLink(
          to: '/entrepreneur/assessment?id=${record.propertyId}',
          classes: 'sw-home-primary',
          children: [
            Component.text(
              record.isCompleted ? 'Review Assessment' : 'Continue Assessment',
            ),
            span(attributes: const {'aria-hidden': 'true'}, [
              Component.text(' →'),
            ]),
          ],
        ),
      ]),
    ]);
  }
}
