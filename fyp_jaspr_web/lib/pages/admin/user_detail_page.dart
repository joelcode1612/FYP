import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web user detail: profile card beside account metadata.
///
/// Ported from `admin_user_detail_web_page.dart`. The Flutter page reads the
/// user straight from `ServiceLocator.userRepo` with a `FutureBuilder`; this
/// version does the same via [AppLocator.userRepo], and treats a null result
/// (or an empty `?id=`) as the guide's "record not found" empty state instead
/// of an endless loading card.
class UserDetailPage extends StatelessComponent {
  final String id;

  const UserDetailPage({super.key, required this.id});

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.admin,
      currentRoute: '/admin/users',
      title: 'User detail',
      eyebrow: 'Accounts',
      subtitle:
          'One account in full — role, status, join date and recent activity.',
      child: id.isEmpty
          ? _notFound()
          : FutureBuilder<SitewiseUser?>(
              future: AppLocator.userRepo.getUserById(id),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.done &&
                    snap.data == null) {
                  return _notFound();
                }
                if (!snap.hasData) return _loading();
                return _body(snap.data!);
              },
            ),
    );
  }

  Component _loading() {
    return const Skeleton(variant: 'row', count: 6);
  }

  Component _notFound() {
    return EmptyState(
      title: 'Record not found',
      body: 'No user matches this id. It may have been removed.',
      action: const ActionLink(
        'Back to users',
        href: '/admin/users',
        variant: 'secondary',
      ),
    );
  }

  Component _body(SitewiseUser user) {
    return div(classes: 'stack stack--md', [
      const Breadcrumbs(['Users']),
      div(classes: 'grid-2', [
        div(classes: 'card', [
          div(classes: 'row', [
            span(classes: 'avatar', [Component.text(user.name[0])]),
            div(classes: 'grow stack', [
              span(classes: 'title', [Component.text(user.name)]),
              span(classes: 'body', [Component.text(user.email)]),
              span(classes: 'small muted', [
                Component.text('${user.role.label} · ${user.status}'),
              ]),
            ]),
          ]),
        ]),
        div(classes: 'card stack', [
          span(classes: 'title', [Component.text('Account')]),
          _row('Location', user.location),
          _row(
            'Joined',
            '${user.joinedAt.day}/${user.joinedAt.month}/${user.joinedAt.year}',
          ),
        ]),
      ]),
    ]);
  }

  Component _row(String label, String value) {
    return div(classes: 'row', [
      span(classes: 'small muted', [Component.text(label)]),
      span(classes: 'small grow', [Component.text(value)]),
    ]);
  }
}
