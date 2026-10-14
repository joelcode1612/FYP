import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/bloc.dart';
import '../../components/property_card.dart';
import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web admin dashboard: stat row plus a desktop grid of the pending queue.
///
/// Ported from `admin_dashboard_web_page.dart` in the Flutter web tree. The
/// Flutter version rebuilds on `AppCubit` for the shell and pulls data through
/// the per-page `AdminViewModel`; here the page owns one [AdminCubit] from
/// [AppLocator.newAdminCubit] and rebuilds on it via [CubitBuilder].
/// Detail ids travel as `?id=` query params instead of `settings.arguments`.
class DashboardPage extends StatefulComponent {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  late final AdminCubit vm;

  @override
  void initState() {
    super.initState();
    vm = AppLocator.newAdminCubit();
    unawaited(vm.loadDashboard());
  }

  @override
  void dispose() {
    unawaited(vm.close());
    super.dispose();
  }

  @override
  Component build(BuildContext context) {
    return CubitBuilder<AdminCubit, AdminState>(
      cubit: vm,
      builder: (context, _) {
        return AppLayout(
          role: AppRole.admin,
          currentRoute: '/admin',
          title: 'Admin Dashboard',
          subtitle:
              'Platform-wide signal: how many listings and accounts are active, and what is waiting for review.',
          child: vm.loading
              ? _loading()
              : vm.error != null
              ? _error(vm.error!)
              : _body(),
        );
      },
    );
  }

  Component _loading() {
    return div(classes: 'card', [
      p(classes: 'body muted', [Component.text('Loading overview…')]),
    ]);
  }

  Component _error(String message) {
    return div(classes: 'card stack', [
      span(classes: 'title', [Component.text('Something went wrong')]),
      p(classes: 'body', [Component.text(message)]),
      ActionButton(
        'Try again',
        variant: 'secondary',
        onClick: () => unawaited(vm.loadDashboard()),
      ),
    ]);
  }

  Component _body() {
    return div(classes: 'stack', [
      div(classes: 'row row--top', [
        div(classes: 'grow stack', [
          h2(classes: 'title-lg', [Component.text('Good day, Admin')]),
          p(classes: 'body muted', [
            Component.text(
              'Review queue, users and listing quality at a glance.',
            ),
          ]),
        ]),
        const ActionLink(
          'View queue',
          href: '/admin/verification',
          variant: 'secondary',
        ),
      ]),
      div(classes: 'row', [
        for (final s in _stats()) div(classes: 'grow', [s]),
      ]),
      h2(classes: 'title', [Component.text('Pending verification')]),
      if (vm.queue.isEmpty)
        div(classes: 'card', [
          p(classes: 'body', [
            Component.text('Queue is clear. No properties awaiting review.'),
          ]),
        ])
      else
        div(classes: 'card-grid', [
          for (final p in vm.queue.take(3))
            PropertyCard(
              property: p,
              href: '/admin/verification-detail?id=${p.id}',
            ),
        ]),
    ]);
  }

  List<Component> _stats() => [
    _stat(
      'Pending verifications',
      '${vm.queue.length}',
      'verified',
      delta: vm.queue.isEmpty ? 'Clear' : 'Needs review',
    ),
    _stat('Total listings', '${vm.listings.length}', 'business'),
    _stat('Registered users', '${vm.users.length}', 'people'),
  ];

  /// Same composition as [StatCard] plus the optional success-coloured delta
  /// the Flutter `SitewiseStatCard` renders in the icon row.
  Component _stat(String label, String value, String icon, {String? delta}) {
    return div(classes: 'stat', [
      div(classes: 'row', [
        Icon(icon, size: 'sm'),
        span(classes: 'grow', []),
        if (delta != null)
          span(classes: 'small text-success', [Component.text(delta)]),
      ]),
      span(classes: 'overline', [Component.text(label)]),
      div(classes: 'metric text-ink', [Component.text(value)]),
    ]);
  }
}
