import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../components/verification_detail_view.dart';
import '../../layouts/app_layout.dart';

/// Standalone listing verification detail (`/admin/listing-detail?id=…`).
///
/// Loads the same backend detail the review split uses
/// (`/api/v1/staff/properties/{id}/verification`) and renders the shared
/// [VerificationDetailView] — documents, per-dimension decisions and audit
/// history — with a back link into the queue. The legacy
/// `/admin/verification-detail` path redirects here with the id preserved.
@client
class ListingDetailPage extends StatefulComponent {
  final String id;

  const ListingDetailPage({super.key, required this.id});

  @override
  State<ListingDetailPage> createState() => _ListingDetailPageState();
}

class _ListingDetailPageState extends State<ListingDetailPage> {
  String _loadedId = '';

  @override
  void initState() {
    super.initState();
    _load(component.id);
  }

  void _load(String id) {
    if (id.isEmpty) return;
    _loadedId = id;
    Future.microtask(() {
      if (!mounted) return;
      unawaited(
        context.read(adminNotifierProvider.notifier).loadReviewDetail(id),
      );
    });
  }

  AdminNotifier get _notifier => context.read(adminNotifierProvider.notifier);

  @override
  Component build(BuildContext context) {
    if (component.id.isEmpty) return _page(_notFound());

    final (detail, error, loading) = context.watch(
      adminNotifierProvider.select(
        (state) => (state.reviewDetail, state.error, state.loading),
      ),
    );

    // Stale-guard: only render a detail that belongs to this id — a slower
    // earlier request must not show through after a quick id change.
    final matches =
        detail != null && '${detail.property.propertyId}' == _loadedId;

    return _page(
      matches
          ? div(classes: 'stack stack--sections', [
              const ActionLink(
                'Back to listings',
                href: '/admin/listings',
                variant: 'ghost',
                icon: 'arrow_back',
              ),
              const VerificationDetailView(),
            ])
          : div(classes: 'card stack', [
              if (error != null && !loading) ...[
                span(classes: 'title', [Component.text('Could not load')]),
                p(classes: 'body muted', [Component.text(error)]),
                ActionButton(
                  'Try again',
                  onClick: () =>
                      unawaited(_notifier.loadReviewDetail(_loadedId)),
                  variant: 'secondary',
                ),
              ] else
                p(classes: 'body muted', [const Component.text('Loading…')]),
            ]),
    );
  }

  Component _page(Component child) {
    return AppLayout(
      role: AppRole.admin,
      currentRoute: '/admin/listings',
      title: 'Listing detail',
      eyebrow: 'Verification',
      subtitle:
          'One listing as submitted, with the evidence and history you need '
          'to decide each dimension independently.',
      child: child,
    );
  }

  Component _notFound() {
    return div(classes: 'card stack', [
      span(classes: 'title', [Component.text('Record not found')]),
      p(classes: 'body', [
        Component.text(
          'No property matches this id. It may have been removed.',
        ),
      ]),
      const ActionLink(
        'Back to listings',
        href: '/admin/listings',
        variant: 'secondary',
      ),
    ]);
  }
}
