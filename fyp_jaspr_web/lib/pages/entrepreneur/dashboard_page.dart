import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/bloc.dart';
import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web entrepreneur dashboard, restructured to the reference mockup's layout:
///
///   ┌────────────────────────────────┬──────────────┐
///   │ hero + 3 overlapping metrics   │ Listing      │
///   │ analytics: factor chart +      │ Board        │
///   │ 2 mini cards                   │ (sticky)     │
///   └────────────────────────────────┴──────────────┘
///
/// **Layout comes from the mockup; every visual property comes from
/// `DESIGN.md`.** The mockup is a Tailwind + Inter + FontAwesome + Unsplash
/// + soft-shadow design, so it is used as a *structural* reference only:
///
/// | Mockup | Here |
/// |---|---|
/// | Unsplash photos | the existing gradient/shopfront placeholder |
/// | `shadow-soft` / `shadow-float` | `1px --border`, `elevation: 0` |
/// | `backdrop-blur-md` chips | opaque `surface` + border |
/// | Inter / extrapolated sizes | Sora headings, IBM Plex Sans body |
/// | FontAwesome | Material Symbols (same set as mobile) |
/// | weekday footfall bars | real `LocationFactor` scores |
/// | "-2% vs last month" | dropped — no historical data exists |
///
/// Nothing is fabricated: every figure is either a live count, the loaded
/// recommendation set, or the `LocationAnalysis` for the top pick.
class DashboardPage extends StatefulComponent {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  late final EntrepreneurCubit vm;

  @override
  void initState() {
    super.initState();
    vm = AppLocator.newEntrepreneurCubit();
    unawaited(_load());
  }

  /// Loads the ranked recommendations, then the location analysis for the
  /// **top** pick. The analysis is what feeds the intelligence chart and the
  /// competitor count; both are optional, so a failure there must not blank the
  /// page.
  Future<void> _load() async {
    try {
      await vm.loadRecommendations();
    } catch (_) {
      return;
    }
    if (vm.recommendations.isEmpty) return;
    final topId = vm.recommendations.first.property.id;
    try {
      await vm.loadAnalysis(topId);
    } catch (_) {
      // No analysis available — the chart and competitor cards fall back to a
      // plain message rather than inventing numbers.
    }
  }

  @override
  void dispose() {
    unawaited(vm.close());
    super.dispose();
  }

  double get _avgScore {
    final scores = vm.recommendations.map((r) => r.score).toList();
    if (scores.isEmpty) return 0;
    return scores.reduce((a, b) => a + b) / scores.length;
  }

  @override
  Component build(BuildContext context) {
    return CubitBuilder<AppCubit, AppState>(
      cubit: AppLocator.appCubit,
      builder: (context, _) {
        final appCubit = AppLocator.appCubit;
        return CubitBuilder<EntrepreneurCubit, EntrepreneurState>(
          cubit: vm,
          builder: (context, _) {
            return AppLayout(
              role: AppRole.entrepreneur,
              currentRoute: '/entrepreneur',
              title: 'Home',
              subtitle:
                  'Your top recommended sites, the location intelligence behind them, and how many you have shortlisted.',
              child: div(classes: 'dash', [
                div(classes: 'dash__main', [
                  _hero(),
                  _metrics(appCubit),
                  _analytics(),
                ]),
                _board(appCubit),
              ]),
            );
          },
        );
      },
    );
  }

  // -------------------------------------------------------------------- hero

  Component _hero() => div(classes: 'dash__hero', [
    div(classes: 'dash__hero-body', [
      span(classes: 'overline', [Component.text('Sitewise')]),
      h1(classes: 'dash__hero-title', [
        Component.text('Discover your next flagship F&B site.'),
      ]),
      p(classes: 'dash__hero-lead', [
        Component.text(
          'We analyse footfall, competitors and cadastre data across the '
          'Klang Valley to rank properties by evidence, not gut feel.',
        ),
      ]),
    ]),
    div(classes: 'visual visual--map dash__hero-art', [
      div(classes: 'visual__grid', []),
    ]),
  ]);

  // ------------------------------------------------- three metric cards

  Component _metrics(AppCubit appCubit) {
    final recs = vm.recommendations.length;
    final compared = appCubit.compared.length;
    return div(classes: 'dash__metrics', [
      _MetricCard(
        label: 'Recommended sites',
        value: '$recs',
        icon: 'auto_awesome',
        barLabel: 'High match',
        pct: (recs * 100 / 3).clamp(0, 100).toInt(),
        tone: 'action',
      ),
      _MetricCard(
        label: 'Compared properties',
        value: '$compared / 3',
        icon: 'compare_arrows',
        barLabel: compared == 0 ? 'Slots open' : '$compared selected',
        pct: (compared * 100 / 3).clamp(0, 100).toInt(),
        tone: 'neutral',
      ),
      // A real link, not a decorative card: it goes to the preferences page.
      a(
        href: '/entrepreneur/preferences',
        classes: 'dash__metric dash__metric--cta',
        [
          span(classes: 'icon-tile', [Icon('tune', size: 'lg')]),
          span(classes: 'dash__metric-title', [
            Component.text('Refine preferences'),
          ]),
          span(classes: 'small', [Component.text('Adjust budget & footprint')]),
        ],
      ),
    ]);
  }

  // -------------------------------------------------------------- analytics

  Component _analytics() => div(classes: 'dash__analytics', [
    div(classes: 'card stack', [
      div(classes: 'row', [
        div(classes: 'grow stack', [
          h2(classes: 'title', [Component.text('Location intelligence')]),
          p(classes: 'small', [
            Component.text(
              vm.analysis == null
                  ? 'Evidence factors for your top pick'
                  : 'Evidence factors for ${vm.analysis!.propertyId}',
            ),
          ]),
        ]),
      ]),
      if (vm.analysis == null || vm.analysis!.factors.isEmpty)
        p(classes: 'body', [
          Component.text(
            'Load a property to see its evidence factors — population, '
            'accessibility, competition and demand.',
          ),
        ])
      else
        for (final f in vm.analysis!.factors)
          WeightBar(label: f.name, pct: f.score.round()),
    ]),

    div(classes: 'dash__mini-col', [
      // Competitors is a real count from the loaded analysis. The mockup's
      // "-2% vs last month" delta is deliberately absent: there is no
      // historical series anywhere in the data layer.
      div(classes: 'card stack', [
        span(classes: 'overline', [Component.text('Competition')]),
        span(classes: 'metric', [
          Component.text(
            vm.analysis == null ? '—' : '${vm.analysis!.competitorCount}',
          ),
        ]),
        p(classes: 'small', [
          Component.text(
            vm.analysis == null
                ? 'Competitor count appears once a property is analysed.'
                : 'Competing F&B outlets near the selected site.',
          ),
        ]),
      ]),
      div(classes: 'card stack', [
        span(classes: 'overline', [Component.text('Suitability')]),
        span(classes: 'metric text-action', [
          Component.text('${_avgScore.toStringAsFixed(0)} / 100'),
        ]),
        p(classes: 'small', [
          Component.text(
            'Mean suitability across your ${vm.recommendations.length} '
            'ranked picks.',
          ),
        ]),
      ]),
    ]),
  ]);

  // ------------------------------------------------------------------- board

  Component _board(AppCubit appCubit) {
    final recs = vm.recommendations;
    return div(classes: 'dash__board', [
      div(classes: 'dash__board-head', [
        div(classes: 'grow stack', [
          h2(classes: 'title-lg', [Component.text('Listing Board')]),
          span(classes: 'small', [
            Component.text('Top AI-ranked sites for your concept'),
          ]),
        ]),
        const ActionLink(
          'See all',
          href: '/entrepreneur/recommendations',
          variant: 'ghost',
        ),
      ]),
      div(classes: 'dash__board-body', [
        if (vm.loading)
          const _Loading()
        else if (recs.isEmpty)
          const _Empty()
        else
          for (final r in recs) _boardCard(appCubit, r),
      ]),
    ]);
  }

  Component _boardCard(AppCubit appCubit, PropertyRecommendation r) {
    final p = r.property;
    final verified = p.verification == VerificationStatus.verified;
    return a(
      href: '/entrepreneur/property-detail?id=${p.id}',
      classes: 'dash__card',
      [
        // Placeholder media, same treatment as property_card.dart — the
        // `visual--map` gradient, never a photograph.
        div(classes: 'visual visual--map dash__card-media', [
          Icon('storefront', size: 'lg', label: p.title),
          if (verified)
            span(classes: 'dash__badge dash__badge--ok', [
              Icon('verified', size: 'sm'),
              Component.text('Verified'),
            ]),
          if (p.hasTour)
            span(classes: 'dash__badge dash__badge--dark', [
              Icon('threesixty', size: 'sm'),
              Component.text('360°'),
            ]),
        ]),
        div(classes: 'dash__card-body', [
          span(classes: 'dash__price', [
            Component.text(p.rentalDisplay),
            span(classes: 'tiny', [Component.text(' / month')]),
          ]),
          span(classes: 'dash__card-title', [Component.text(p.title)]),
          span(classes: 'dash__card-loc', [
            Icon('place', size: 'sm'),
            Component.text('${p.city}, ${p.state}'),
          ]),
          const DividerClass(),
          div(classes: 'row', [
            span(classes: 'small grow', [
              Component.text('${p.sizeSqft.toStringAsFixed(0)} sq ft'),
            ]),
            span(classes: _scoreBadge(r.score), [
              Component.text('${r.score.toStringAsFixed(0)} match'),
            ]),
          ]),
        ]),
      ],
    );
  }

  /// The documented score ramp, as a pill tone.
  static String _scoreBadge(double score) {
    if (score >= 75) return 'dash__match dash__match--ok';
    if (score >= 55) return 'dash__match dash__match--action';
    return 'dash__match dash__match--muted';
  }
}

// ===========================================================================
// Supporting components
// ===========================================================================

class _Loading extends StatelessComponent {
  const _Loading();

  @override
  Component build(BuildContext context) =>
      p(classes: 'body muted', [Component.text('Loading…')]);
}

class _Empty extends StatelessComponent {
  const _Empty();

  @override
  Component build(BuildContext context) => div(classes: 'card stack', [
    span(classes: 'overline', [Component.text('Listing board')]),
    h3(classes: 'title', [Component.text('No matches yet')]),
    p(classes: 'body', [
      Component.text(
        'Loosen your budget or size filters to see more shoplots.',
      ),
    ]),
  ]);
}

/// One of the three overlapping metric cards.
class _MetricCard extends StatelessComponent {
  final String label;
  final String value;
  final String icon;
  final String barLabel;
  final int pct;
  final String tone;

  const _MetricCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.barLabel,
    required this.pct,
    required this.tone,
  });

  @override
  Component build(BuildContext context) {
    return div(classes: 'dash__metric', [
      div(classes: 'row', [
        div(classes: 'grow stack', [
          span(classes: 'dash__metric-label', [Component.text(label)]),
          span(classes: 'dash__metric-value', [Component.text(value)]),
        ]),
        span(classes: 'icon-tile', [Icon(icon, size: 'lg')]),
      ]),
      const DividerClass(),
      WeightBar(label: barLabel, pct: pct),
    ]);
  }
}

/// Thin separator. Jaspr has no `hr` styling hook in this tree, so it is an
/// empty styled div carrying the design system's hairline class.
class DividerClass extends StatelessComponent {
  const DividerClass();

  @override
  Component build(BuildContext context) => div(classes: 'dash__rule', []);
}
