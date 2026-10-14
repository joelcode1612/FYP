import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/bloc.dart';
import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web verification queue: property table with review links plus the
/// tours-awaiting-verification list with approve/reject actions.
///
/// Ported from `admin_verification_web_page.dart`. Same two loads as Flutter
/// (`loadDashboard` + `loadPendingTours`); tour actions call the same cubit
/// methods and report through an inline success card instead of a SnackBar.
class VerificationPage extends StatefulComponent {
  const VerificationPage({super.key});

  @override
  State<VerificationPage> createState() => _VerificationPageState();
}

class _VerificationPageState extends State<VerificationPage> {
  late final AdminCubit vm;
  String? _tourSuccess;

  @override
  void initState() {
    super.initState();
    vm = AppLocator.newAdminCubit();
    unawaited(vm.loadDashboard());
    unawaited(vm.loadPendingTours());
  }

  @override
  void dispose() {
    unawaited(vm.close());
    super.dispose();
  }

  Future<void> _approveTour(String id) async {
    await vm.approveTour(id);
    if (mounted) setState(() => _tourSuccess = 'Tour approved.');
  }

  Future<void> _rejectTour(String id) async {
    await vm.rejectTour(id);
    if (mounted) setState(() => _tourSuccess = 'Tour rejected.');
  }

  @override
  Component build(BuildContext context) {
    return CubitBuilder<AdminCubit, AdminState>(
      cubit: vm,
      builder: (context, _) {
        return AppLayout(
          role: AppRole.admin,
          currentRoute: '/admin/verification',
          title: 'Verification queue',
          subtitle: AppRole.admin.label,
          child: div(classes: 'stack', [
            div(classes: 'stack', [
              h2(classes: 'title', [Component.text('Awaiting review')]),
              p(classes: 'small muted', [
                Component.text(
                  'Manage → review → verify to keep listing quality.',
                ),
              ]),
            ]),
            vm.loading
                ? div(classes: 'card', [
                    p(classes: 'body muted', [Component.text('Loading…')]),
                  ])
                : vm.queue.isEmpty
                ? div(classes: 'card stack', [
                    span(classes: 'title', [Component.text('Queue is clear')]),
                    p(classes: 'body', [
                      Component.text(
                        'No properties are waiting for verification right now.',
                      ),
                    ]),
                  ])
                : div(classes: 'card', [
                    div(classes: 'table-scroll', [
                      table(classes: 'table', [
                        thead([
                          tr([
                            th([Component.text('Property')]),
                            th([Component.text('City')]),
                            th([Component.text('Rental')]),
                            th([Component.text('Size')]),
                            th([Component.text('Action')]),
                          ]),
                        ]),
                        tbody([
                          for (final p in vm.queue)
                            tr([
                              td([Component.text(p.title)]),
                              td([Component.text(p.city)]),
                              td([
                                Component.text(
                                  'RM${p.rentalRm.toStringAsFixed(0)}',
                                ),
                              ]),
                              td([
                                Component.text(
                                  '${p.sizeSqft.toStringAsFixed(0)} sq ft',
                                ),
                              ]),
                              td([
                                ActionLink(
                                  'Review',
                                  href: '/admin/verification-detail?id=${p.id}',
                                  variant: 'ghost',
                                ),
                              ]),
                            ]),
                        ]),
                      ]),
                    ]),
                  ]),
            div(classes: 'stack', [
              h2(classes: 'title', [
                Component.text('Tours awaiting verification'),
              ]),
              p(classes: 'small muted', [
                Component.text(
                  'Approve completed 360° tours for entrepreneurs.',
                ),
              ]),
            ]),
            if (_tourSuccess != null)
              div(classes: 'card stack', [
                span(classes: 'small text-success', [
                  Component.text(_tourSuccess!),
                ]),
                const ActionLink(
                  'Back to verification queue',
                  href: '/admin/verification',
                  variant: 'secondary',
                ),
              ]),
            if (vm.pendingTours.isEmpty)
              div(classes: 'card', [
                p(classes: 'body', [
                  Component.text('No tours are waiting for verification.'),
                ]),
              ])
            else
              div(classes: 'card', [
                div(classes: 'stack', [
                  for (final t in vm.pendingTours)
                    div(classes: 'row', [
                      div(classes: 'grow stack', [
                        span(classes: 'body', [Component.text(t.title)]),
                        span(classes: 'small muted', [
                          Component.text('${t.frameCount} frames'),
                        ]),
                      ]),
                      ActionButton(
                        'Reject',
                        variant: 'secondary',
                        onClick: () => unawaited(_rejectTour(t.id)),
                      ),
                      ActionButton(
                        'Approve',
                        onClick: () => unawaited(_approveTour(t.id)),
                      ),
                    ]),
                ]),
              ]),
          ]),
        );
      },
    );
  }
}
