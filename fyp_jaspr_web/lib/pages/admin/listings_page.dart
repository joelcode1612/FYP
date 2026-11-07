import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/admin_review_split.dart';
import '../../components/bloc.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web listings, ported to the source `admin/review.html` split layout.
///
/// The source review design is one page: a status-tabbed `.queue` on the left
/// and a detail `.panel` on the right. This route shows every property
/// (`vm.listings`, default tab All); `/admin/verification` shows the
/// awaiting-review subset (default tab Pending). Both share [ReviewSplit].
@client
class ListingsPage extends StatefulComponent {
  const ListingsPage({super.key});

  @override
  State<ListingsPage> createState() => _ListingsPageState();
}

class _ListingsPageState extends State<ListingsPage> {
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
      // Scoped to the data slices ReviewSplit renders, and inside the layout,
      // so the chrome never rebuilds on a VM emit.
      child: CubitBuilder<AdminCubit, AdminState>(
        cubit: vm,
        when: (prev, next) =>
            prev.queue != next.queue || prev.listings != next.listings,
        builder: (context, _) => div(classes: 'stack stack--sections', [
          ReviewSplit(vm: vm, mode: ReviewMode.listings),
        ]),
      ),
    );
  }
}
