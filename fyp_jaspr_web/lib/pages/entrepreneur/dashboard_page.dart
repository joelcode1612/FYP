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
  /// The dashboard loads each data source independently, so one failed or slow
  /// read never blanks the whole page: the header, Quick Actions and the
  /// Current Assessment card always render; a failed read degrades only the
  /// section that needs it (an em dash on the KPI, an inline retry on Recent).
  late Future<HistoryLoad> _history = _loadHistory();
  late Future<int?> _catalogue = _loadCatalogueCount();

  /// Assessment history for the Assessments/Reports KPIs and the Recent
  /// Assessments list. Failure travels as data with the backend's message.
  Future<HistoryLoad> _loadHistory() async {
    final history = await const AssessmentApi().history(limit: 50);
    if (!history.ok) {
      return HistoryLoad(failure: history.failure);
    }
    return HistoryLoad(value: history.value!);
  }

  /// Catalogue size for the Explore KPI. Null (a failed read) shows an em
  /// dash on one KPI instead of failing anything else.
  Future<int?> _loadCatalogueCount() async {
    try {
      return (await ApiPropertyRepository().getProperties()).length;
    } on Object {
      return null;
    }
  }

  void _reloadHistory() => setState(() => _history = _loadHistory());

  void _reloadCatalogue() => setState(() => _catalogue = _loadCatalogueCount());

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
        // KPI row: each counter degrades to an em dash when its own read
        // fails; the other cards keep their real values.
        _kpis(saved),
        // Compact overview of the most recently updated saved assessment.
        // It loads on its own so a slow or failed read never holds up the
        // rest of the dashboard.
        const _CurrentAssessment(),
        _quickActions(saved),
        _recent(),
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

  // -------------------------------------------------------------------- KPIs

  Component _kpis(Set<String> saved) {
    return div(classes: 'sw-kpi-grid', [
      _kpi(
        'place',
        '#1d4ed8',
        'Explore Properties',
        _catalogueKpiValue(),
        Component.text('Commercial listings'),
        '/entrepreneur/explore',
      ),
      _kpi(
        'bookmark',
        '#7c3aed',
        'Saved Properties',
        Component.text('${saved.length}'),
        Component.text(saved.length == 1
            ? 'Property shortlisted'
            : 'Properties shortlisted'),
        '/entrepreneur/saved',
      ),
      _kpi(
        'fact_check',
        '#059669',
        'Assessments',
        _historyKpiValue((history) => '${history.total}'),
        Component.text('Started by you'),
        '/entrepreneur/assessments',
      ),
      _kpi(
        'description',
        '#475569',
        'Reports',
        _historyKpiValue((history) =>
            '${history.items.where((r) => r.reportAvailable).length}'),
        _reportsKpiNote(),
        '/entrepreneur/assessments',
      ),
    ]);
  }

  /// Explore KPI value. Null (a failed catalogue read) shows an em dash — an
  /// honest "not available right now", never a fabricated zero. The read is
  /// fast, so the em dash is momentary on a healthy server.
  Component _catalogueKpiValue() {
    return FutureBuilder<int?>(
      future: _catalogue,
      builder: (context, snapshot) {
        final count = snapshot.data;
        if (snapshot.connectionState != ConnectionState.done || count == null) {
          return Component.text('—');
        }
        return Component.text('$count');
      },
    );
  }

  /// Assessments/Reports KPI values over the shared history future. A failed
  /// or in-flight read shows an em dash while the Recent Assessments section
  /// below carries the actual error and its scoped retry.
  Component _historyKpiValue(String Function(AssessmentHistory) format) {
    return FutureBuilder<HistoryLoad>(
      future: _history,
      builder: (context, snapshot) {
        final load = snapshot.data;
        if (snapshot.connectionState != ConnectionState.done ||
            load == null ||
            load.failure != null) {
          return Component.text('—');
        }
        return Component.text(format(load.value!));
      },
    );
  }

  /// Keeps the original singular/plural wording; falls back to the neutral
  /// plural while the read is in flight or failed.
  Component _reportsKpiNote() {
    return FutureBuilder<HistoryLoad>(
      future: _history,
      builder: (context, snapshot) {
        final load = snapshot.data;
        final reports = (snapshot.connectionState == ConnectionState.done &&
                load != null &&
                load.failure == null)
            ? load.value!.items.where((r) => r.reportAvailable).length
            : null;
        return Component.text(reports == 1 ? 'Report ready' : 'Reports ready');
      },
    );
  }

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

  Component _kpi(
    String icon,
    String color,
    String label,
    Component value,
    Component note,
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
      div(classes: 'kpi-value', [value]),
      div(classes: 'kpi-note', [note]),
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

  /// Recent Assessments owns the history read's error state: a failure here
  /// renders an inline retry scoped to this section only — the KPI row, the
  /// Current Assessment card and Quick Actions remain usable.
  Component _recent() {
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
      FutureBuilder<HistoryLoad>(
        future: _history,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return div(
              classes: 'sw-dash-recent',
              [const Skeleton(variant: 'row', count: 2)],
            );
          }
          final load = snapshot.data;
          if (load == null || load.failure != null) {
            return div(
              classes: 'sw-dash-recent',
              [_recentError(load?.failure?.message)],
            );
          }
          final rows = load.value!.items.take(4).toList();
          return div(classes: 'sw-dash-recent', [
            if (rows.isEmpty) _recentEmpty() else ...[
              for (final record in rows) _recentRow(record),
            ],
          ]);
        },
      ),
    ]);
  }

  /// A failure is contained here and never pretends the account has no
  /// assessments. The message is the (already user-facing) backend sentence.
  Component _recentError(String? message) {
    return div(classes: 'sw-home-empty', [
      Icon('error', size: 'lg'),
      p(classes: 'sw-home-detail', [
        Component.text(
          'Recent assessments could not be loaded. '
          '${message ?? 'No response from the data service.'}',
        ),
      ]),
      ActionButton('Try again', variant: 'secondary', onClick: _reloadHistory),
    ]);
  }

  Component _recentEmpty() {
    return div(classes: 'sw-home-empty', [
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

/// The assessment-history read, carried as a value so the KPI counters and
/// the Recent Assessments list can degrade independently of the rest of the
/// dashboard. Exactly one of [failure] / [value] is set, mirroring ApiResult.
class HistoryLoad {
  final AssessmentFailure? failure;
  final AssessmentHistory? value;

  const HistoryLoad({this.failure, this.value});
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
