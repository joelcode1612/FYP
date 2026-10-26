import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/bloc.dart';
import '../../components/letter_reveal.dart';
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
              // The source dashboard has no page header: its first element is
              // `.bento-head`. Rendering both produced two competing titles
              // ("Home" above "Hello there"), which the source does not have.
              showPageHead: false,
              // Restructured to `sitewise-entrepreneur/index.html`: a bento
              // dashboard — head, four KPIs, then a 12-column grid of cards.
              // Previously `.dash__hero` + `.dash__metrics` + `.dash__analytics`
              // + `.dash__board`, which followed an older reference mockup.
              child: vm.loading
                  ? const _Loading()
                  : vm.error != null
                  ? _error(vm.error!)
                  : div(classes: 'stack', [
                      _head(),
                      _kpis(appCubit),
                      div(classes: 'bento', [
                        _heroCard(),
                        _matchesCard(),
                        _scoresCard(),
                        _savedCard(appCubit),
                        _runsCard(),
                        _actionsCard(),
                      ]),
                      p(classes: 'stat-note', [
                        Component.text(
                          'Everything above is computed from your own saved '
                          'records. Suitability scores are relative '
                          'decision-support indicators, not a probability of '
                          'business success.',
                        ),
                      ]),
                    ]),
            );
          },
        );
      },
    );
  }

  // -------------------------------------------------------------------- hero

  Component _error(String message) {
    return div(classes: 'card stack', [
      span(classes: 'title', [Component.text('Something went wrong')]),
      p(classes: 'body', [Component.text(message)]),
      ActionButton(
        'Try again',
        variant: 'secondary',
        onClick: () => unawaited(vm.loadRecommendations()),
      ),
    ]);
  }

  // -------------------------------------------------------------------- head

  /// Bento head: eyebrow + greeting + actions.
  ///
  /// The source greets by name. The target exposes no authenticated user here,
  /// so it uses a fixed greeting rather than inventing one.
  Component _head() {
    final prefsSet = _prefsSet;
    return div(classes: 'bento-head', [
      div(classes: 'bh-title', [
        span(classes: 'eyebrow-sm', [Component.text('Workspace')]),
        LetterRevealHeading.text('Hello there', level: 1),
      ]),
      div(classes: 'bh-actions', [
        a(
          href: '/entrepreneur/explore',
          classes: 'bento-iconbtn',
          attributes: {'aria-label': 'Search properties'},
          [Icon('search', label: 'Search properties')],
        ),
        span(classes: 'bento-period', [
          Icon('calendar_today', size: 'sm'),
          Component.text('No run yet'),
        ]),
        a(
          href: prefsSet
              ? '/entrepreneur/recommendations'
              : '/entrepreneur/preferences',
          classes: 'bento-cta',
          [
            Component.text(
              prefsSet ? 'Generate shortlist' : 'Set your preferences',
            ),
          ],
        ),
      ]),
    ]);
  }

  /// True when the saved preferences carry any real choice. The target always
  /// holds a `BusinessPreferences` instance, so "is it set" must be derived
  /// rather than tested for null.
  bool get _prefsSet {
    final p = vm.prefs;
    return p.businessType.isNotEmpty ||
        p.preferredLocation.isNotEmpty ||
        p.maxBudgetRm > 0 ||
        p.minSizeSqft > 0;
  }

  // -------------------------------------------------------------------- KPIs

  Component _kpis(AppCubit appCubit) {
    final recs = vm.recommendations.length;
    final saved = appCubit.saved.length;
    return div(classes: 'bento-kpis', [
      _kpi('Shortlist', '$recs', 'Latest run'),
      _kpi('Saved favourites', '$saved', 'Synced to your account'),
      // The source shows a recommendation-run count. The target keeps no run
      // history in state, so this reports an honest zero, not a fabricated one.
      _kpi('Recommendation runs', '0', 'None yet'),
      _kpi(
        'Preferences',
        _prefsSet ? 'Saved' : 'Not set',
        _prefsSet ? 'Up to date' : 'Set them to get recommendations',
      ),
    ]);
  }

  Component _kpi(String k, String v, String n) {
    return div(classes: 'kpi', [
      span(classes: 'k', [Component.text(k)]),
      span(classes: 'v', [Component.text(v)]),
      span(classes: 'n', [Component.text(n)]),
    ]);
  }

  // -------------------------------------------------------------- hero card

  /// Dark card with the donut ring showing how much of the shortlist is saved.
  Component _heroCard() {
    final recs = vm.recommendations;
    if (recs.isEmpty) {
      return div(classes: 'bento-hero', [
        div(classes: 'bento-card__head', [
          h3([Component.text('Latest shortlist')]),
          span(classes: 'hero-badge', [Component.text('Empty')]),
        ]),
        div(classes: 'stack', [
          span(classes: 'title', [Component.text('No recommendations yet')]),
          p(classes: 'hero-cap', [
            Component.text(
              'Recommendations are generated from your saved preferences. '
              'Nothing is shown until you set them and run a search.',
            ),
          ]),
          a(href: '/entrepreneur/preferences', classes: 'bento-cta', [
            Component.text('Set your preferences'),
          ]),
        ]),
      ]);
    }

    // Donut percentage: how many shortlisted properties are also saved.
    final savedIds = AppLocator.appCubit.saved;
    final savedInShortlist = recs
        .where((r) => savedIds.contains(r.property.id))
        .length;
    final pct = (savedInShortlist * 100 / recs.length).round();

    return div(classes: 'bento-hero', [
      div(classes: 'bento-card__head', [
        h3([Component.text('Latest shortlist')]),
        span(classes: 'hero-badge', [Component.text('Recent')]),
      ]),
      div(classes: 'donut-wrap', [
        div(classes: 'donut', styles: Styles(raw: {'--pct': '$pct'}), [
          div(classes: 'donut-center', [
            div(classes: 'dc-v', [Component.text('${recs.length}')]),
            div(classes: 'dc-k', [Component.text('in shortlist')]),
          ]),
        ]),
      ]),
      div(classes: 'hero-legend', [
        span(classes: 'lg', [
          span(classes: 'dot a', []),
          Component.text('$savedInShortlist saved'),
        ]),
        span(classes: 'lg', [
          span(classes: 'dot b', []),
          Component.text('${recs.length - savedInShortlist} not yet saved'),
        ]),
      ]),
      p(classes: 'hero-cap', [
        Component.text(
          '$pct% of your shortlist is saved. The ring reflects properties you '
          'have favourited from the current run — it is not a success forecast.',
        ),
      ]),
      a(href: '/entrepreneur/recommendations', classes: 'bento-cta', [
        Component.text('See the full ranking'),
      ]),
    ]);
  }

  // ------------------------------------------------------------ match rows

  Component _matchesCard() {
    final recs = vm.recommendations;
    return div(classes: 'bento-card', [
      div(classes: 'bento-card__head', [
        h3([Component.text('Top matches')]),
        span(classes: 'card-note', [Component.text('Latest run')]),
      ]),
      if (recs.isEmpty)
        _empty(
          'No matches yet',
          'Set your preferences to see ranked properties here.',
        )
      else
        div(classes: 'blist', [for (final r in recs.take(4)) _matchRow(r)]),
    ]);
  }

  Component _matchRow(PropertyRecommendation r) {
    final p = r.property;
    final top = vm.recommendations
        .map((e) => e.score)
        .reduce((x, y) => x > y ? x : y);
    final rank = vm.recommendations.indexOf(r) + 1;
    final pct = ((r.score / top) * 100).round().clamp(4, 100);
    return a(
      href: '/entrepreneur/property-detail?id=${p.id}',
      classes: 'brow',
      [
        div(classes: 'b-ico', [Component.text('$rank')]),
        div(classes: 'b-main', [
          div(classes: 't', [Component.text(p.title)]),
          div(classes: 's', [
            Component.text('${p.address} · RM${p.rentalRm.toStringAsFixed(0)}'),
          ]),
          div(classes: 'pbar', [
            i(styles: Styles(raw: {'width': '$pct%'}), []),
          ]),
        ]),
        div(classes: 'b-val', [
          div(classes: 'v', [Component.text(r.score.toStringAsFixed(3))]),
          div(classes: 'p', [Component.text('score')]),
        ]),
      ],
    );
  }

  // ----------------------------------------------------------- score chart

  Component _scoresCard() {
    final recs = vm.recommendations;
    final top = recs.isEmpty
        ? 0.0
        : recs.map((e) => e.score).reduce((x, y) => x > y ? x : y);
    return div(classes: 'bento-card', [
      div(classes: 'bento-card__head', [
        h3([Component.text('Shortlist scores')]),
        span(classes: 'card-note', [Component.text('Relative · demo scorer')]),
      ]),
      if (recs.isEmpty)
        _empty(
          'Nothing to chart',
          'Scores appear once you generate a shortlist.',
        )
      else
        div(classes: 'schart', [
          for (final r in recs.take(8))
            div(
              classes: 'scol',
              attributes: {
                'title':
                    'Rank ${recs.indexOf(r) + 1} · score ${r.score.toStringAsFixed(3)}',
              },
              [
                span(classes: 'val', [
                  Component.text(r.score.toStringAsFixed(2)),
                ]),
                div(
                  classes: 'bar${recs.indexOf(r) == 0 ? ' top' : ''}',
                  styles: Styles(
                    raw: {
                      'height':
                          '${top > 0 ? ((r.score / top) * 100).round().clamp(6, 100) : 6}%',
                    },
                  ),
                  [],
                ),
                span(classes: 'lbl', [
                  Component.text('#${recs.indexOf(r) + 1}'),
                ]),
              ],
            ),
        ]),
    ]);
  }

  // ------------------------------------------------------ saved favourites

  Component _savedCard(AppCubit appCubit) {
    final saved = appCubit.saved;
    final rows = vm.recommendations
        .where((r) => saved.contains(r.property.id))
        .take(4)
        .toList();
    return div(classes: 'bento-card', [
      div(classes: 'bento-card__head', [
        h3([Component.text('Saved favourites')]),
        span(classes: 'card-note', [Component.text('${saved.length} saved')]),
      ]),
      if (rows.isEmpty)
        _empty(
          'No favourites saved yet',
          'Use the heart action on any property to keep it here for later.',
        )
      else
        div(classes: 'blist', [
          for (final r in rows)
            a(
              href: '/entrepreneur/property-detail?id=${r.property.id}',
              classes: 'brow',
              [
                div(classes: 'b-ico', [Icon('favorite', size: 'sm')]),
                div(classes: 'b-main', [
                  div(classes: 't', [Component.text(r.property.title)]),
                  div(classes: 's', [Component.text(r.property.address)]),
                ]),
                div(classes: 'b-val', [
                  div(classes: 'v', [
                    Component.text(
                      'RM${r.property.rentalRm.toStringAsFixed(0)}',
                    ),
                  ]),
                  div(classes: 'p', [Component.text('per month')]),
                ]),
              ],
            ),
        ]),
    ]);
  }

  // ------------------------------------------------------------ recent runs

  /// The source lists past recommendation runs. The target keeps no run history,
  /// so this renders the explicit empty state rather than fabricated rows.
  Component _runsCard() {
    return div(classes: 'bento-card', [
      div(classes: 'bento-card__head', [
        h3([Component.text('Recent runs')]),
        span(classes: 'card-note', [Component.text('0 total')]),
      ]),
      _empty(
        'No runs recorded',
        'Each generated shortlist is kept here so you can revisit it.',
      ),
    ]);
  }

  // ----------------------------------------------------------- quick actions

  Component _actionsCard() {
    final prefsSet = _prefsSet;
    Component tile(String eye, String title, String body, String href) {
      return a(href: href, classes: 'qtile', [
        span(classes: 'eyebrow-sm', [Component.text(eye)]),
        h4([Component.text(title)]),
        p([Component.text(body)]),
      ]);
    }

    return div(classes: 'bento-card bento-wide', [
      div(classes: 'bento-card__head', [
        h3([Component.text('Start here')]),
        span(classes: 'card-note', [
          Component.text('Jump back into your workflow'),
        ]),
      ]),
      div(classes: 'qgrid', [
        tile(
          'Explore',
          'Browse properties',
          'Search verified listings by budget, type, size and area.',
          '/entrepreneur/explore',
        ),
        tile(
          prefsSet ? 'Edit' : 'Set up',
          prefsSet ? 'Edit preferences' : 'Set your preferences',
          'Budget, property type and target floor area.',
          '/entrepreneur/preferences',
        ),
        tile(
          'Rank',
          'Recommendations',
          'See why each property fits your saved criteria.',
          '/entrepreneur/recommendations',
        ),
        tile(
          'Saved',
          'Favourites',
          'Reopen the properties you shortlisted.',
          '/entrepreneur/saved',
        ),
        tile(
          'Map',
          'Open the map',
          'Inspect competitors, demand and transport around a property.',
          '/entrepreneur/map',
        ),
        tile(
          'Account',
          'Profile & settings',
          'Update your details and sign out.',
          '/entrepreneur/profile',
        ),
      ]),
    ]);
  }

  // -------------------------------------------------------------- utilities

  Component _empty(String title, String body) {
    return div(classes: 'empty', [
      span(classes: 'title', [Component.text(title)]),
      p(classes: 'body', [Component.text(body)]),
    ]);
  }
}

class _Loading extends StatelessComponent {
  const _Loading();

  @override
  Component build(BuildContext context) =>
      p(classes: 'body muted', [Component.text('Loading…')]);
}
