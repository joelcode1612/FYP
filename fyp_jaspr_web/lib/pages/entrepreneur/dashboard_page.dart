import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/bloc.dart';
import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web entrepreneur home, restructured to the reference
/// `SiteWise_Location_Hero_Integrated.html`:
///
///   ┌─────────────────────────────────────┐
///   │ Location hero  (headline + map)      │
///   │ Workspace action center              │
///   │ 4-KPI grid                           │
///   └─────────────────────────────────────┘
///
/// The reference is a blue / Archivo Tailwind prototype. It is used as a
/// *structural* and *visual* reference only — the app's own token system
/// (`--action #1d4ed8`, `--success #0d9488`, Archivo) already matches it, so
/// nothing is re-themed. Every figure is a live count, the loaded
/// recommendation set, or an honest zero — no fabricated "sample study".
@client
class DashboardPage extends StatefulComponent {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage>
    with PreloadStateMixin<DashboardPage> {
  EntrepreneurCubit? _vm;

  EntrepreneurCubit get vm => _vm ??= AppLocator.newEntrepreneurCubit();

  /// Illustrative catchment radius — purely presentational, mirrors the
  /// reference's 500 m / 1 km toggle. No real geodata is shown.
  int _radiusIndex = 0;
  static const _radii = [500, 1000];

  @override
  Future<void> preloadState() => _load();

  @override
  void initState() {
    super.initState();
    if (_vm == null) unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await vm.loadRecommendations();
    } catch (_) {
      // The page renders its honest empty state if recommendations fail.
    }
  }

  @override
  void dispose() {
    final cubit = _vm;
    if (cubit != null) unawaited(cubit.close());
    super.dispose();
  }

  bool get _prefsSet {
    final p = vm.prefs;
    return p.businessType.isNotEmpty ||
        p.preferredLocation.isNotEmpty ||
        p.maxBudgetRm > 0 ||
        p.minSizeSqft > 0;
  }

  @override
  Component build(BuildContext context) {
    return CubitBuilder<AppCubit, AppState>(
      cubit: AppLocator.appCubit,
      builder: (context, _) {
        return CubitBuilder<EntrepreneurCubit, EntrepreneurState>(
          cubit: vm,
          builder: (context, _) {
            return AppLayout(
              role: AppRole.entrepreneur,
              currentRoute: '/entrepreneur',
              title: 'Home',
              // The reference's first element is the hero itself — there is no
              // separate page-title band above it.
              showPageHead: false,
              child: vm.loading
                  ? const _Loading()
                  : vm.error != null
                      ? _error(vm.error!)
                      : div(classes: 'stack stack--sections sw-home', [
                          _hero(),
                          _actionCenter(),
                          _kpis(AppLocator.appCubit),
                          p(classes: 'stat-note', [
                            Component.text(
                              'Recommendations, saved selections and preferences '
                              'come from your session. The location preview and '
                              'catchment ring are illustrative only — no live map '
                              'or measured demand is shown. Scores are relative '
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

  // -------------------------------------------------------------------- error

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

  // --------------------------------------------------------------------- hero

  Component _hero() {
    final radius = _radii[_radiusIndex];
    return section(classes: 'sw-lh-hero', [
      div(classes: 'sw-lh-grid', [
        div(classes: 'sw-lh-copy', [
          p(classes: 'sw-lh-eyebrow', [
            span(classes: 'sw-lh-eyebrow-rule', attributes: const {
              'aria-hidden': 'true',
            }, []),
            Component.text('F&B LOCATION INTELLIGENCE'),
          ]),
          h1(classes: 'sw-lh-title', [
            Component.text('Is this location worth the '),
            em([Component.text('lease?')]),
          ]),
          p(classes: 'sw-lh-lead', [
            Component.text(
              'Before you commit to a commercial space, understand the rent, the '
              'surrounding area and how well the property fits your F&B business.',
            ),
          ]),
          div(classes: 'sw-lh-actions', [
            AppLink(
              to: '/entrepreneur/recommendations',
              classes: 'sw-lh-button sw-lh-button-primary',
              children: [
                Component.text('Assess a location'),
                _arrow(),
              ],
            ),
            AppLink(
              to: '/entrepreneur/explore',
              classes: 'sw-lh-button sw-lh-button-secondary',
              children: [
                Component.text('Explore properties'),
                _arrow(),
              ],
            ),
          ]),
          p(classes: 'sw-lh-caveat', [
            Icon('info', size: 'sm'),
            Component.text(
              'Inspect evidence and outstanding checks before you sign. Location '
              'analysis is decision support, not a guarantee of business success.',
            ),
          ]),
        ]),
        div(classes: 'sw-lh-visual', [_mapFrame(radius)]),
      ]),
      _builtFor(),
    ]);
  }

  Component _arrow() => svg(
        attributes: {
          'viewBox': '0 0 24 24',
          'width': '17',
          'height': '17',
          'fill': 'none',
          'stroke': 'currentColor',
          'stroke-width': '2',
          'stroke-linecap': 'round',
          'stroke-linejoin': 'round',
          'aria-hidden': 'true',
        },
        [
          path(
            attributes: {
              'd': 'M5 12h14M13 6l6 6-6 6',
            },
            [],
          ),
        ],
      );

  /// Illustrative neighbourhood preview built from CSS (no SVG namespace, no
  /// live geodata). The 500 m / 1 km toggle only scales the drawn ring.
  Component _mapFrame(int radius) {
    return div(classes: 'sw-lh-map-frame', [
      div(classes: 'sw-lh-map-head', [
        span(classes: 'sw-lh-window-dots', attributes: const {
          'aria-hidden': 'true',
        }, [
          i([]),
          i([]),
          i([]),
        ]),
        span(classes: 'sw-lh-map-headname', [
          Icon('place', size: 'sm'),
          Component.text('SITEWISE '),
          span(classes: 'sw-lh-map-headsub', [
            Component.text('/ NEIGHBOURHOOD VIEW'),
          ]),
        ]),
        span(classes: 'sw-lh-demo-mark', [Component.text('ILLUSTRATIVE')]),
      ]),
      div(classes: 'sw-lh-map-body', [
        _mapSvg(),
        div(classes: 'sw-lh-map-key', [
          _keyDot('sw-lh-key-dot-blue', 'Property'),
          _keyDot('sw-lh-key-dot-green', 'Nearby F&B'),
          _keyDot('sw-lh-key-dot-dark', 'Other places'),
        ]),
        div(
          classes: 'sw-lh-map-switch',
          attributes: const {'role': 'group'},
          [
            button(
              classes: _radiusIndex == 0
                  ? 'sw-lh-radius-selected'
                  : '',
              attributes: {
                'type': 'button',
                'aria-pressed': _radiusIndex == 0 ? 'true' : 'false',
              },
              events: events(
                onClick: () => setState(() => _radiusIndex = 0),
              ),
              [Component.text('500 m')],
            ),
            button(
              classes: _radiusIndex == 1
                  ? 'sw-lh-radius-selected'
                  : '',
              attributes: {
                'type': 'button',
                'aria-pressed': _radiusIndex == 1 ? 'true' : 'false',
              },
              events: events(
                onClick: () => setState(() => _radiusIndex = 1),
              ),
              [Component.text('1 km')],
            ),
          ],
        ),
        span(
          classes: 'sw-lh-map-bottomnote',
          attributes: const {'role': 'status'},
          [
            Component.text(
              'Schematic catchment · ${radius == 500 ? '500 m' : '1 km'} '
              'illustration',
            ),
          ],
        ),
      ]),
      p(classes: 'sw-lh-map-foot', [
        Component.text(
          'Location preview for demonstration only. No live map or measured '
          'catchment is displayed.',
        ),
      ]),
    ]);
  }

  /// Illustrative neighbourhood preview built as a real inline SVG — no live
  /// geodata. Mirrors the reference's patterned street grid, catchment ring,
  /// coloured pins and "Sample location" label. The 500 m / 1 km toggle only
  /// scales the drawn catchment ring (the reference draws a single 140-px ring).
  Component _mapSvg() {
    final ringR = _radiusIndex == 1 ? 190 : 140;
    const cx = '308';
    const cy = '210';
    return svg(
      viewBox: '0 0 600 410',
      attributes: const {
        'role': 'img',
        'aria-labelledby': 'sw-lh-map-title sw-lh-map-desc',
        'preserveAspectRatio': 'xMidYMid slice',
      },
      [
        Component.element(
          tag: 'title',
          attributes: const {'id': 'sw-lh-map-title'},
          children: [Component.text('Illustrative neighbourhood catchment')],
        ),
        Component.element(
          tag: 'desc',
          attributes: const {'id': 'sw-lh-map-desc'},
          children: [
            Component.text(
              'A schematic street grid with a sample commercial property at the '
              'centre, plus surrounding cafe, transit and amenity markers. This '
              'is not a live geographic map.',
            ),
          ],
        ),
        Component.element(
          tag: 'defs',
          children: [
            Component.element(
              tag: 'pattern',
              attributes: {
                'id': 'sw-lh-small-blocks',
                'width': '56',
                'height': '54',
                'patternUnits': 'userSpaceOnUse',
                'patternTransform': 'rotate(-8)',
              },
              children: [
                Component.element(
                  tag: 'rect',
                  attributes: {
                    'x': '0',
                    'y': '0',
                    'width': '56',
                    'height': '54',
                    'fill': '#f4f7fa',
                  },
                ),
                Component.element(
                  tag: 'path',
                  attributes: {
                    'd': 'M0 0H56M0 0V54',
                    'fill': 'none',
                    'stroke': '#e0e6ec',
                    'stroke-width': '2',
                  },
                ),
                Component.element(
                  tag: 'path',
                  attributes: {
                    'd': 'M29 0V54M0 26H56',
                    'fill': 'none',
                    'stroke': '#e8edf1',
                    'stroke-width': '1',
                  },
                ),
              ],
            ),
          ],
        ),
        Component.element(
          tag: 'rect',
          attributes: {
            'width': '600',
            'height': '410',
            'fill': 'url(#sw-lh-small-blocks)',
          },
        ),
        Component.element(
          tag: 'g',
          attributes: {
            'stroke': '#ffffff',
            'stroke-linecap': 'round',
            'fill': 'none',
          },
          children: [
            Component.element(
              tag: 'path',
              attributes: {
                'd': 'M-30 70C145 93 185 96 344 83S526 63 627 49',
                'stroke-width': '20',
              },
            ),
            Component.element(
              tag: 'path',
              attributes: {
                'd': 'M-27 266C137 248 213 263 340 255S533 264 627 233',
                'stroke-width': '17',
              },
            ),
            Component.element(
              tag: 'path',
              attributes: {
                'd': 'M116 -35C142 77 154 160 150 265S160 363 157 440',
                'stroke-width': '21',
              },
            ),
            Component.element(
              tag: 'path',
              attributes: {
                'd': 'M392 -40C411 83 398 155 418 247S419 363 429 447',
                'stroke-width': '19',
              },
            ),
            Component.element(
              tag: 'path',
              attributes: {
                'd': 'M-30 350C159 329 234 337 326 345S530 350 618 364',
                'stroke-width': '11',
              },
            ),
          ],
        ),
        Component.element(
          tag: 'g',
          attributes: {
            'stroke': '#d5dce4',
            'stroke-width': '1',
            'fill': 'none',
            'opacity': '.72',
          },
          children: [
            Component.element(
              tag: 'path',
              attributes: {
                'd': 'M-30 70C145 93 185 96 344 83S526 63 627 49',
              },
            ),
            Component.element(
              tag: 'path',
              attributes: {
                'd': 'M-27 266C137 248 213 263 340 255S533 264 627 233',
              },
            ),
            Component.element(
              tag: 'path',
              attributes: {
                'd': 'M116 -35C142 77 154 160 150 265S160 363 157 440',
              },
            ),
            Component.element(
              tag: 'path',
              attributes: {
                'd': 'M392 -40C411 83 398 155 418 247S419 363 429 447',
              },
            ),
          ],
        ),
        Component.element(
          tag: 'g',
          attributes: {
            'fill': '#99a7b7',
            'font-family': 'Arial, sans-serif',
            'font-size': '11',
            'font-weight': '600',
            'opacity': '.93',
          },
          children: [
            Component.element(
              tag: 'text',
              attributes: {
                'x': '28',
                'y': '78',
                'transform': 'rotate(7 28 78)',
              },
              children: [Component.text('Market Street')],
            ),
            Component.element(
              tag: 'text',
              attributes: {
                'x': '401',
                'y': '82',
                'transform': 'rotate(-8 401 82)',
              },
              children: [Component.text('Commercial Avenue')],
            ),
            Component.element(
              tag: 'text',
              attributes: {
                'x': '35',
                'y': '253',
                'transform': 'rotate(-5 35 253)',
              },
              children: [Component.text('Station Road')],
            ),
            Component.element(
              tag: 'text',
              attributes: {
                'x': '439',
                'y': '269',
                'transform': 'rotate(-6 439 269)',
              },
              children: [Component.text('Jalan Utama')],
            ),
            Component.element(
              tag: 'text',
              attributes: {
                'x': '146',
                'y': '159',
                'transform': 'rotate(82 146 159)',
              },
              children: [Component.text('Retail Walk')],
            ),
            Component.element(
              tag: 'text',
              attributes: {
                'x': '395',
                'y': '144',
                'transform': 'rotate(80 395 144)',
              },
              children: [Component.text('Main Street')],
            ),
            Component.element(
              tag: 'text',
              attributes: {
                'x': '42',
                'y': '354',
              },
              children: [Component.text('Neighbourhood Lane')],
            ),
          ],
        ),
        Component.element(
          tag: 'circle',
          attributes: {
            'cx': cx,
            'cy': cy,
            'r': '$ringR',
            'fill': 'rgba(29,78,216,.07)',
            'stroke': '#3b82f6',
            'stroke-width': '2',
            'stroke-opacity': '.75',
          },
        ),
        Component.element(
          tag: 'circle',
          attributes: {
            'cx': cx,
            'cy': cy,
            'r': '18',
            'fill': '#fff',
            'stroke': '#cbd9f2',
            'stroke-width': '1.5',
          },
        ),
        Component.element(
          tag: 'path',
          attributes: {
            'd':
                'M308 174c-11 0-19 9-19 20 0 14 19 32 19 32s19-18 19-32c0-11-8-20-19-20z',
            'fill': '#1d4ed8',
            'stroke': '#ffffff',
            'stroke-width': '2.5',
          },
        ),
        Component.element(
          tag: 'circle',
          attributes: {
            'cx': '308',
            'cy': '194',
            'r': '6',
            'fill': '#fff',
          },
        ),
        Component.element(
          tag: 'g',
          children: [
            Component.element(
              tag: 'circle',
              attributes: {
                'cx': '217',
                'cy': '146',
                'r': '6',
                'fill': '#0d9488',
                'stroke': '#fff',
                'stroke-width': '3',
              },
            ),
            Component.element(
              tag: 'circle',
              attributes: {
                'cx': '376',
                'cy': '122',
                'r': '6',
                'fill': '#0d9488',
                'stroke': '#fff',
                'stroke-width': '3',
              },
            ),
            Component.element(
              tag: 'circle',
              attributes: {
                'cx': '424',
                'cy': '250',
                'r': '6',
                'fill': '#0d9488',
                'stroke': '#fff',
                'stroke-width': '3',
              },
            ),
            Component.element(
              tag: 'circle',
              attributes: {
                'cx': '251',
                'cy': '296',
                'r': '6',
                'fill': '#0d9488',
                'stroke': '#fff',
                'stroke-width': '3',
              },
            ),
            Component.element(
              tag: 'circle',
              attributes: {
                'cx': '366',
                'cy': '311',
                'r': '6',
                'fill': '#1e293b',
                'stroke': '#fff',
                'stroke-width': '3',
              },
            ),
            Component.element(
              tag: 'circle',
              attributes: {
                'cx': '182',
                'cy': '229',
                'r': '6',
                'fill': '#1e293b',
                'stroke': '#fff',
                'stroke-width': '3',
              },
            ),
          ],
        ),
        Component.element(
          tag: 'g',
          attributes: {
            'font-family': 'Arial, sans-serif',
            'font-size': '11',
            'font-weight': '700',
            'fill': '#24334c',
          },
          children: [
            Component.element(
              tag: 'rect',
              attributes: {
                'x': '326',
                'y': '175',
                'width': '116',
                'height': '27',
                'rx': '7',
                'fill': '#fff',
                'stroke': '#d8e1ee',
              },
            ),
            Component.element(
              tag: 'text',
              attributes: {
                'x': '338',
                'y': '192',
              },
              children: [Component.text('Sample location')],
            ),
          ],
        ),
      ],
    );
  }

  Component _keyDot(String cls, String label) => span([
        i(classes: cls, attributes: const {'aria-hidden': 'true'}, []),
        Component.text(label),
      ]);

  Component _builtFor() => div(
        classes: 'sw-lh-built-for',
        attributes: const {'aria-label': 'F&B businesses supported'},
        [
          span(classes: 'sw-lh-built-caption', [Component.text('BUILT FOR')]),
          _builtItem('local_cafe', 'Cafés'),
          _builtItem('restaurant', 'Restaurants'),
          _builtItem('bakery_dining', 'Bakeries'),
          _builtItem('takeout_dining', 'Takeaway'),
          _builtItem('store', 'Cloud kitchens'),
        ],
      );

  Component _builtItem(String icon, String label) => span([
        Icon(icon, size: 'sm'),
        Component.text(label),
      ]);

  // ---------------------------------------------------------- action center

  Component _actionCenter() {
    final recs = vm.recommendations;
    final saved = AppLocator.appCubit.saved;
        final top = recs.isNotEmpty
        ? recs.reduce((r1, r2) => r1.score > r2.score ? r1 : r2)
        : null;

    return section(classes: 'sw-home-action-center', [
      div(classes: 'sw-home-action-heading', [
        div([
          p(classes: 'sw-home-kicker', [Component.text('YOUR WORKSPACE')]),
          h2([Component.text('Continue where you left off')]),
          p([
            Component.text(
              'Pick up an assessment, review your shortlist, or start a new '
              'property search.',
            ),
          ]),
        ]),
        span(
          classes: 'sw-home-demo-pill',
          [Component.text(_prefsSet ? 'Preferences saved' : 'Set preferences')],
        ),
      ]),
      div(classes: 'sw-home-action-grid', [
        // Latest shortlist card — real top recommendation, no sample study.
        div(classes: 'sw-home-current', [
          div(classes: 'sw-home-row sw-home-study-head', [
            span(classes: 'sw-home-kicker', [Component.text('LATEST SHORTLIST')]),
            if (top != null)
              span(classes: 'sw-home-status', [
                span(classes: 'sw-home-status-dot', attributes: const {
                  'aria-hidden': 'true',
                }, []),
                Component.text('${recs.length} ranked'),
              ]),
          ]),
          if (top == null)
            _emptyStudy()
          else ...[
            h3([Component.text(top.property.title)]),
            p(classes: 'sw-home-detail', [
              Component.text(
                '${top.property.address} · '
                'RM${top.property.rentalRm.toStringAsFixed(0)}',
              ),
            ]),
            div(classes: 'sw-home-progress-copy', [
              span([Component.text('Match score')]),
              strong([Component.text(top.score.toStringAsFixed(2))]),
            ]),
            div(
              classes: 'sw-home-progress-track',
              attributes: const {
                'role': 'progressbar',
                'aria-label': 'Top match score',
              },
              [
                span(
                  styles: Styles(raw: {
                    'width':
                        '${((top.score / 1).clamp(0, 1) * 100).round()}%',
                  }),
                  [],
                ),
              ],
            ),
            div(classes: 'sw-home-row sw-home-study-bottom', [
              span([Component.text('Top of ${recs.length} recommendations')]),
              AppLink(
                to: '/entrepreneur/recommendations',
                classes: 'sw-home-primary',
                children: [
                  Component.text('Review recommendations '),
                  span(attributes: const {'aria-hidden': 'true'}, [
                    Component.text('→'),
                  ]),
                ],
              ),
            ]),
          ],
        ]),
        // Next actions shortcuts.
        section(classes: 'sw-home-next', [
          div(classes: 'sw-home-next-heading', [
            h3([Component.text('Your next actions')]),
            span([Component.text('3 shortcuts')]),
          ]),
          div(classes: 'sw-home-actions', [
            _actionButton(
              'bookmark',
              'Review saved locations',
              saved.isEmpty
                  ? 'No favourites saved yet'
                  : '${saved.length} ${saved.length == 1 ? 'property' : 'properties'} shortlisted',
              '/entrepreneur/saved',
            ),
            _actionButton(
              'storefront',
              'Manage my properties',
              'Register or review your own listings',
              '/entrepreneur/my-properties',
            ),
            _actionButton(
              'tune',
              'Refine business requirements',
              'Adjust your concept, rent and space preferences',
              _prefsSet
                  ? '/entrepreneur/recommendations'
                  : '/entrepreneur/preferences',
            ),
          ]),
        ]),
      ]),
    ]);
  }

  Component _emptyStudy() => div(classes: 'sw-home-empty', [
        Icon('search', size: 'lg'),
        p(classes: 'sw-home-detail', [
          Component.text(
            'No recommendations yet. Set your preferences to generate a '
            'ranked shortlist.',
          ),
        ]),
        AppLink(
          to: '/entrepreneur/preferences',
          classes: 'sw-home-primary',
          children: [
            Component.text('Set your preferences '),
            span(attributes: const {'aria-hidden': 'true'}, [
              Component.text('→'),
            ]),
          ],
        ),
      ]);

  Component _actionButton(
    String icon,
    String title,
    String hint,
    String href,
  ) =>
      AppLink(
        to: href,
        classes: 'sw-home-action',
        children: [
          span(classes: 'sw-home-action-symbol', [
            Icon(icon, size: 'md'),
          ]),
          span(classes: 'sw-home-action-copy', [
            strong([Component.text(title)]),
            small([Component.text(hint)]),
          ]),
          span(classes: 'sw-home-action-arrow', attributes: const {
            'aria-hidden': 'true',
          }, [Component.text('→')]),
        ],
      );

  // -------------------------------------------------------------------- KPIs

  Component _kpis(AppCubit appCubit) {
    final recs = vm.recommendations.length;
    final saved = appCubit.saved.length;
    return div(classes: 'sw-kpi-grid', [
      _kpi(
        'auto_awesome',
        '#1d4ed8',
        'Recommendations',
        '$recs',
        'Ranked matches',
        '/entrepreneur/recommendations',
      ),
      _kpi(
        'bookmark',
        '#059669',
        'Saved favourites',
        '$saved',
        saved == 1 ? 'Property shortlisted' : 'Properties shortlisted',
        '/entrepreneur/saved',
      ),
      _kpi(
        'tune',
        '#e11d48',
        'Preferences',
        _prefsSet ? 'Set' : '—',
        _prefsSet ? 'Up to date' : 'Set them to get matches',
        '/entrepreneur/preferences',
      ),
      _kpi(
        'history',
        '#475569',
        'Assessment runs',
        '0',
        'None yet',
        '/entrepreneur/recommendations',
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
  ) =>
      AppLink(
        to: href,
        classes: 'kpi-card sw-kpi-button',
        children: [
          div(classes: 'kpi-top', [
            div(
              classes: 'kpi-ico',
              styles: Styles(raw: {
                'background': '${color}14',
                'color': color,
              }),
              [Icon(icon, size: 'sm')],
            ),
            span(classes: 'kpi-label', [Component.text(label)]),
          ]),
          div(classes: 'kpi-value', [Component.text(value)]),
          div(classes: 'kpi-note', [Component.text(note)]),
        ],
      );
}

class _Loading extends StatelessComponent {
  const _Loading();

  @override
  Component build(BuildContext context) =>
      p(classes: 'body muted', [Component.text('Loading…')]);
}
