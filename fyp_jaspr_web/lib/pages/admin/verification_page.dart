import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/admin_review_split.dart';
import '../../components/bloc.dart';
import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web verification queue, ported to the source `admin/review.html` split
/// layout: a status-tabbed `.queue` of listings on the left and a detail
/// `.panel` (evidence, photos, verification evidence, decision bar) on the
/// right, both inside a `.split`.
///
/// The source `review.html` is purely property verification — no tours. The
/// "Tours awaiting verification" block below is a *target-only* addition (the
/// source `tours.html` has no web route); it is kept so the capability is not
/// lost, but it is not part of the source review design.
@client
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
          title: 'Property verification',
          eyebrow: 'Verification',
          subtitle:
              'Review the submitted record against the evidence the owner '
              'provided. Approval verifies the listing details — it does not '
              'grant permission to operate a food business.',
          child: div(classes: 'stack stack--sections', [
            ReviewSplit(vm: vm, mode: ReviewMode.verification),

            // --- Target-only: tours awaiting verification (no source route) ---
            SectionCard(
              title: 'Tours awaiting verification',
              child: div(classes: 'stack', [
                p(classes: 'small muted', [
                  Component.text(
                    'Approve completed 360° tours so entrepreneurs can view '
                    'them. This workflow is not part of the source review '
                    'design.',
                  ),
                ]),
                if (_tourSuccess != null)
                  div(classes: 'card stack', [
                    span(classes: 'small text-success', [
                      Component.text(_tourSuccess!),
                    ]),
                  ]),
                if (vm.pendingTours.isEmpty)
                  p(classes: 'body', [
                    Component.text('No tours are waiting for verification.'),
                  ])
                else
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
            ),
          ]),
        );
      },
    );
  }
}
