import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/admin_review_split.dart';
import '../../layouts/app_layout.dart';

/// Web listings, ported to the source `admin/review.html` split layout.
///
/// The source review design is one page: a status-tabbed `.queue` on the left
/// and a detail `.panel` on the right. This route shows every property
/// (all listings, default tab All); `/admin/verification` shows the
/// awaiting-review subset (default tab Pending). Both share [ReviewSplit].
@client
class ListingsPage extends StatefulComponent {
  const ListingsPage({super.key});

  @override
  State<ListingsPage> createState() => _ListingsPageState();
}

class _ListingsPageState extends State<ListingsPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      unawaited(
        context.read(adminNotifierProvider.notifier).loadDashboard(),
      );
    });
  }

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.admin,
      currentRoute: '/admin/listings',
      // The page header is rendered by `AppLayout`; a page must not render
      // its own `PageHead` or the title appears twice.
      title: 'Listings',
      eyebrow: 'Verification',
      subtitle:
          'Every commercial property on the platform, across all owners. '
          'Open a listing to review its details or decide whether it '
          'should be verified.',
      // ReviewSplit scopes its own watches, so the chrome never rebuilds on a
      // notification.
      child: const div(
        classes: 'stack stack--sections',
        [ReviewSplit(mode: ReviewMode.listings)],
      ),
    );
  }
}
