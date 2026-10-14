import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/bloc.dart';
import '../../components/property_card.dart';
import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web owner dashboard: portfolio stats row, primary actions and a desktop
/// grid of the latest listings.
///
/// Ported from `owner_dashboard_web_page.dart` in the Flutter web tree. The
/// Flutter version rebuilds on both `AppCubit` and `OwnerViewModel`; saved /
/// compare toggles never appear on owner cards, so this version only rebuilds
/// on a per-page [OwnerCubit] created via [AppLocator.newOwnerCubit].
/// The 'Capture 360° tour' action is mobile-only — capture resumes a live
/// camera session — so it renders as a disabled hint instead of a link.
class DashboardPage extends StatefulComponent {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  late final OwnerCubit vm;

  @override
  void initState() {
    super.initState();
    vm = AppLocator.newOwnerCubit();
    unawaited(vm.load());
  }

  @override
  void dispose() {
    unawaited(vm.close());
    super.dispose();
  }

  @override
  Component build(BuildContext context) {
    return CubitBuilder<OwnerCubit, OwnerState>(
      cubit: vm,
      builder: (context, _) {
        return AppLayout(
          role: AppRole.owner,
          currentRoute: '/owner',
          title: 'Home',
          subtitle:
              'How your listings are performing and what needs your attention.',
          child: vm.loading
              ? const _Loading()
              : div(classes: 'stack', [
                  div(classes: 'stack', [
                    h2(classes: 'title-lg', [Component.text('Your portfolio')]),
                    p(classes: 'small', [
                      Component.text(
                        'Listings, verification status and tours.',
                      ),
                    ]),
                  ]),
                  div(classes: 'stat-grid', [
                    StatCard(
                      label: 'Live listings',
                      value: '${vm.properties.length}',
                      icon: 'storefront',
                    ),
                    StatCard(
                      label: '360° tours',
                      value: '${vm.tours.length}',
                      icon: 'threesixty',
                    ),
                    _EnquiriesStat(value: '18', delta: '+4'),
                  ]),
                  div(classes: 'btn-row', [
                    const ActionLink(
                      'Add a property',
                      href: '/owner/add-property',
                      icon: 'add_business',
                    ),
                    const ActionButton(
                      'Capture 360° tour',
                      onClick: null,
                      variant: 'secondary',
                      icon: 'camera_alt',
                    ),
                    span(classes: 'small muted', [
                      Component.text('Capture runs in the mobile app'),
                    ]),
                  ]),
                  h2(classes: 'title-lg', [Component.text('Latest listings')]),
                  div(classes: 'card-grid', [
                    for (final p in vm.properties.take(3))
                      PropertyCard(
                        property: p,
                        href: '/owner/property-detail?id=${p.id}',
                      ),
                  ]),
                ]),
        );
      },
    );
  }
}

/// Enquiries tile — the Flutter `SitewiseStatCard` shows a `delta` chip that
/// the shared `StatCard` does not carry, so this tile composes it directly.
class _EnquiriesStat extends StatelessComponent {
  final String value;
  final String delta;

  const _EnquiriesStat({required this.value, required this.delta});

  @override
  Component build(BuildContext context) {
    return div(classes: 'stat', [
      div(classes: 'row', [
        Icon('mail_outline', size: 'sm'),
        span(classes: 'grow', []),
        span(classes: 'small text-success', [Component.text(delta)]),
      ]),
      span(classes: 'overline', [Component.text('Enquiries (30d)')]),
      div(classes: 'metric text-ink', [Component.text(value)]),
    ]);
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
