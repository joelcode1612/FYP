import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/admin_review_split.dart';
import '../../components/ui.dart';
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
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      final admin = context.read(adminNotifierProvider.notifier);
      unawaited(admin.loadDashboard());
      unawaited(admin.loadPendingTours());
    });
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
      // The review split and the tour queue keep their own watches and
      // interaction state, so the chrome never rebuilds on a notification.
      child: const div(classes: 'stack stack--sections', [
        ReviewSplit(mode: ReviewMode.verification),
        _TourQueue(),
      ]),
    );
  }
}

/// Target-only section: tours awaiting verification (no source route).
/// Owns the approval notice state so approving/rejecting a tour rebuilds only
/// this card, never the layout or the review split.
class _TourQueue extends StatefulComponent {
  const _TourQueue();

  @override
  State<_TourQueue> createState() => _TourQueueState();
}

class _TourQueueState extends State<_TourQueue> {
  String? _success;

  Future<void> _approve(String id) async {
    await context.read(adminNotifierProvider.notifier).approveTour(id);
    if (mounted) setState(() => _success = 'Tour approved.');
  }

  Future<void> _reject(String id) async {
    await context.read(adminNotifierProvider.notifier).rejectTour(id);
    if (mounted) setState(() => _success = 'Tour rejected.');
  }

  @override
  Component build(BuildContext context) {
    final tours = context.watch(
      adminNotifierProvider.select((state) => state.pendingTours),
    );
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
        if (tours.isEmpty)
          p(classes: 'body', [
            Component.text('No tours are waiting for verification.'),
          ])
        else
          div(classes: 'stack', [
            for (final t in tours)
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
