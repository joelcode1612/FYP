import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/bloc.dart';
import '../../components/property_card.dart';
import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web entrepreneur dashboard: spacious location-decision workspace with
/// summary cards, a desktop recommendation grid and a map preview.
///
/// Ported from `entrepreneur_dashboard_web_page.dart` in the Flutter web tree.
/// The Flutter version rebuilds on `AppCubit` + `EntrepreneurViewModel` and
/// reads listings through `ServiceLocator`; this version rebuilds on the
/// shared `AppLocator.appCubit` and a per-page `EntrepreneurCubit` via
/// [CubitBuilder]. Recommendation links travel as `?id=` query params instead
/// of `settings.arguments`, and the stylised map panel is a static placeholder
/// whose pins are plain links.
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
    unawaited(vm.loadRecommendations());
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
              subtitle: AppRole.entrepreneur.label,
              child: div(classes: 'stack', [
                div(classes: 'card stack', [
                  h1(classes: 'title-lg', [
                    Component.text('Find your next F&B site'),
                  ]),
                  p(classes: 'body', [
                    Component.text(
                      'Tell Sitewise your concept and budget — we rank Klang '
                      'Valley shoplots by evidence, not gut feel.',
                    ),
                  ]),
                  div(classes: 'btn-row', [
                    const ActionLink(
                      'Set business preferences',
                      href: '/entrepreneur/preferences',
                      variant: 'secondary',
                    ),
                    const ActionLink(
                      'Explore properties',
                      href: '/entrepreneur/explore',
                      variant: 'secondary',
                    ),
                  ]),
                ]),
                div(
                  attributes: const {'style': 'gap:12px'},
                  classes: 'row',
                  [
                    div(classes: 'grow', [
                      StatCard(
                        label: 'Recommended',
                        value: '${vm.recommendations.length}',
                        icon: 'auto_awesome',
                      ),
                    ]),
                    div(classes: 'grow', [
                      StatCard(
                        label: 'Saved',
                        value: '${appCubit.saved.length}',
                        icon: 'bookmark_border',
                      ),
                    ]),
                    div(classes: 'grow', [
                      StatCard(
                        label: 'Compared',
                        value: '${appCubit.compared.length}/3',
                        icon: 'compare_arrows',
                      ),
                    ]),
                  ],
                ),
                div(
                  attributes: const {'style': 'gap:8px'},
                  classes: 'row',
                  [
                    div(classes: 'grow stack', [
                      h2(classes: 'title', [
                        Component.text('Top picks for you'),
                      ]),
                      p(classes: 'small', [
                        Component.text(
                          'Based on ${vm.prefs.businessType} · up to '
                          'RM${vm.prefs.maxBudgetRm.toStringAsFixed(0)}',
                        ),
                      ]),
                    ]),
                    const ActionLink(
                      'See all',
                      href: '/entrepreneur/recommendations',
                      variant: 'ghost',
                    ),
                  ],
                ),
                if (vm.loading)
                  const _Loading()
                else
                  div(classes: 'card-grid', [
                    for (final r in vm.recommendations.take(3))
                      PropertyCard(
                        property: r.property,
                        href:
                            '/entrepreneur/property-detail?id=${r.property.id}',
                        rankBanner: r.reason,
                        saved: appCubit.isSaved(r.property.id),
                        compared: appCubit.isCompared(r.property.id),
                        onToggleSaved: () =>
                            appCubit.toggleSaved(r.property.id),
                        onToggleCompared: () =>
                            appCubit.toggleCompared(r.property.id),
                      ),
                  ]),
                div(classes: 'stack', [
                  h2(classes: 'title', [
                    Component.text('Location intelligence'),
                  ]),
                  p(classes: 'small', [
                    Component.text(
                      'Where your top picks sit in the Klang Valley.',
                    ),
                  ]),
                ]),
                _MapPanel(
                  pins: [
                    for (final r in vm.recommendations.take(3))
                      _MapPin(
                        id: r.property.id,
                        label: r.property.title,
                        latitude: r.property.latitude,
                        longitude: r.property.longitude,
                      ),
                  ],
                ),
              ]),
            );
          },
        );
      },
    );
  }
}

class _Loading extends StatelessComponent {
  const _Loading();

  @override
  Component build(BuildContext context) {
    return div(classes: 'card', [
      p(classes: 'body muted', [Component.text('Loading…')]),
    ]);
  }
}

/// One pin on the stylised map panel, positioned with the same lat/lng
/// proportions as the Flutter `SitewiseMapPanel`.
class _MapPin {
  final String id;
  final String label;
  final double latitude;
  final double longitude;

  const _MapPin({
    required this.id,
    required this.label,
    required this.latitude,
    required this.longitude,
  });

  double get _x => ((longitude - 100.3) / 3.5).clamp(-0.9, 0.9).toDouble();

  double get _y => -((latitude - 1.5) / 4.0).clamp(-0.9, 0.9).toDouble();

  String get position =>
      'position:absolute;left:${((_x + 1) / 2 * 100).toStringAsFixed(1)}%;'
      'top:${((1 - _y) / 2 * 100).toStringAsFixed(1)}%;';
}

/// Stylised Klang Valley map placeholder. Interactive map tiles are not
/// available in the web prototype, so each pin is a link to its property and
/// the same pins are listed underneath as text links.
class _MapPanel extends StatelessComponent {
  final List<_MapPin> pins;
  const _MapPanel({required this.pins});

  @override
  Component build(BuildContext context) {
    return div(classes: 'card stack', [
      div(classes: 'visual visual--map', [
        div(classes: 'visual__grid', []),
        for (final pin in pins)
          a(
            href: '/entrepreneur/property-detail?id=${pin.id}',
            attributes: {'style': pin.position, 'title': pin.label},
            [Icon('place', label: pin.label)],
          ),
      ]),
      p(classes: 'small', [
        Component.text(
          'Stylised Klang Valley map — interactive map tiles require the '
          'mobile app. Each pin links to its property page.',
        ),
      ]),
      ul(classes: 'stack', [
        for (final pin in pins)
          li([
            a(
              href: '/entrepreneur/property-detail?id=${pin.id}',
              classes: 'text-action',
              [Component.text(pin.label)],
            ),
          ]),
      ]),
    ]);
  }
}
