import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_provider_compat/jaspr_provider_compat.dart' as provider;
import 'package:shared_logic/shared_logic.dart';

import '../../components/admin_review_split.dart';
import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';
import '../../state/admin_view_model.dart';

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
  late final AdminViewModel vm;

  @override
  void initState() {
    super.initState();
    vm = AppLocator.newAdminViewModel();
    unawaited(vm.loadDashboard());
    unawaited(vm.loadPendingTours());
  }

  @override
  void dispose() {
    vm.dispose();
    super.dispose();
  }

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.admin,
      currentRoute: '/admin/verification',
      title: 'Property verification',
      eyebrow: 'Verification',
      subtitle:
          'Review the submitted record against the evidence the owner '
          'provided. Approval verifies the listing details — it does not '
          'grant permission to operate a food business.',
      // Scoped to the data slices the two sections render, and inside the
      // layout, so the chrome never rebuilds on a notification (the review
      // split and the tour queue keep their own interaction state).
      child: provider.ChangeNotifierProvider<AdminViewModel>.value(
        value: vm,
        child: provider.Selector<AdminViewModel, _ReviewData>(
          selector: (context, vm) => (
            queue: vm.queue,
            listings: vm.listings,
            pendingTours: vm.pendingTours,
          ),
          builder: (context, data, child) =>
              div(classes: 'stack stack--sections', [
                ReviewSplit(vm: vm, mode: ReviewMode.verification),
                _TourQueue(vm: vm),
              ]),
        ),
      ),
    );
  }
}

/// The three lists the review split and the tour queue render together.
/// Selecting them as one value rebuilds that subtree exactly when the
/// previous `buildWhen` predicate would have.
typedef _ReviewData = ({
  List<CommercialProperty> queue,
  List<CommercialProperty> listings,
  List<VirtualTour> pendingTours,
});

/// Target-only section: tours awaiting verification (no source route).
/// Owns the approval notice state so approving/rejecting a tour rebuilds only
/// this card, never the layout or the review split.
class _TourQueue extends StatefulComponent {
  final AdminViewModel vm;

  const _TourQueue({required this.vm});

  @override
  State<_TourQueue> createState() => _TourQueueState();
}

class _TourQueueState extends State<_TourQueue> {
  String? _success;

  AdminViewModel get vm => component.vm;

  Future<void> _approve(String id) async {
    await vm.approveTour(id);
    if (mounted) setState(() => _success = 'Tour approved.');
  }

  Future<void> _reject(String id) async {
    await vm.rejectTour(id);
    if (mounted) setState(() => _success = 'Tour rejected.');
  }

  @override
  Component build(BuildContext context) {
    return SectionCard(
      title: 'Tours awaiting verification',
      child: div(classes: 'stack', [
        p(classes: 'small muted', [
          Component.text(
            'Approve completed 360° tours so entrepreneurs can view '
            'them. This workflow is not part of the source review '
            'design.',
          ),
        ]),
        if (_success != null)
          div(classes: 'card stack', [
            span(classes: 'small text-success', [Component.text(_success!)]),
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
                  onClick: () => unawaited(_reject(t.id)),
                ),
                ActionButton(
                  'Approve',
                  onClick: () => unawaited(_approve(t.id)),
                ),
              ]),
          ]),
      ]),
    );
  }
}
