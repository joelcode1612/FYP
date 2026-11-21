import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/letter_reveal.dart';
import '../../components/ui.dart';
import '../../data/auth_service.dart';
import '../../layouts/app_layout.dart';

/// Owner home, restructured to the bento grid used across the app.
///
/// The previous version rendered its **own** `PageHead` on top of the one
/// `AppLayout` already provides, so the dashboard showed two competing titles,
/// and it laid content out as `.metrics` + `.rows` + a `.grid-3` of
/// `.form-section` steps — a pre-bento layout. This rebuilds it as:
///
/// ```text
/// .bento-head    eyebrow + greeting + actions
/// .bento-kpis    4 KPI tiles
/// .bento         hero (portfolio health) · wide (recent listings)
///               · 3 step cards ("How listing works")
/// ```
///
/// Every figure is a live count from the owner notifier; nothing is fabricated.
@client
class DashboardPage extends StatefulComponent {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

/// The signed-in owner id from the server-verified profile. Each navigation is
/// a fresh document, so the family argument is stable for the page's lifetime.
String _ownerId() => WebAuth.profile?['user_id'] as String? ?? '';

class _DashboardPageState extends State<DashboardPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      unawaited(context.read(ownerNotifierProvider(_ownerId()).notifier).load());
    });
  }

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.owner,
      currentRoute: '/owner',
      title: 'Your portfolio',
      // The source dashboard has no page header — its first element is
      // `.bento-head` (eyebrow + greeting + actions). Rendering both the
      // layout header and the bento head produced two competing titles,
      // which the source does not have.
      showPageHead: false,
      // The shells below re-render only on loading/error; the chrome and the
      // static heading never rebuild on a data emit.
      child: const _Shells(),
    );
  }
}

/// One watch for the whole dashboard body: the page is a single projection of
/// the owner state (counts, hero, recent rows all read `properties`).
class _Shells extends StatelessComponent {
  const _Shells();

  @override
  Component build(BuildContext context) {
    final slice = context.watch(
      ownerNotifierProvider(_ownerId()).select(
        (state) => (loading: state.loading, error: state.error),
      ),
    );
    if (slice.loading) return const BentoSkeleton();
    if (slice.error != null) return _Error(slice.error!);
    return div(classes: 'stack', [
      const _Head(),
      const _Kpis(),
      const _HealthCard(),
      const _ListingsCard(),
      _stepCard(
        'Step 1',
        'Create the listing',
        'Title, address, rent, size, type and photos.',
      ),
      _stepCard(
        'Step 2',
        'Submit for review',
        'An administrator checks the details and photos.',
      ),
      _stepCard(
        'Step 3',
        'Publish and add a tour',
        'Once approved, entrepreneurs can see it and you can '
            'submit a 360° tour.',
      ),
      p(classes: 'stat-note', [
        Component.text(
          'Every figure above is a live count from your saved records. '
          'Verification status reflects the current state of each listing in '
          'the record store.',
        ),
      ]),
    ]);
  }
}

class _Error extends StatelessComponent {
  const _Error(this.message);

  final String message;

  @override
  Component build(BuildContext context) => EmptyState(
    title: 'Something went wrong',
    body: message,
    action: ActionButton(
      'Try again',
      variant: 'primary',
      onClick: () => unawaited(
        context.read(ownerNotifierProvider(_ownerId()).notifier).load(),
      ),
    ),
  );
}

// -------------------------------------------------------------------- head

class _Head extends StatelessComponent {
  const _Head();

  @override
  Component build(BuildContext context) {
    return div(classes: 'bento-head', [
      div(classes: 'bh-title', [
        span(classes: 'eyebrow-sm', [
          Component.text('Public portal · property owner'),
        ]),
        LetterRevealHeading.text('Your portfolio', level: 1),
        p(classes: 'muted', [
          Component.text(
            'Manage your commercial listings, track their verification '
            'status, and publish 360° tours.',
          ),
        ]),
      ]),
      div(classes: 'bh-actions', [
        AppLink(
          to: '/owner/add-property',
          classes: 'bento-cta',
          children: [Component.text('Add property')],
        ),
        AppLink(
          to: '/owner/properties',
          classes: 'bento-period',
          children: [Component.text('Manage listings')],
        ),
        AppLink(
          to: '/owner/tours',
          classes: 'bento-period',
          children: [Component.text('360° tours')],
        ),
      ]),
    ]);
  }
}

// -------------------------------------------------------------------- KPIs

/// Reads through the notifier so the derived counts (`countByStatus`,
/// `withTourCount`) stay in `shared_logic`; its own slice watch drives the
/// rebuild.
class _Kpis extends StatelessComponent {
  const _Kpis();

  @override
  Component build(BuildContext context) {
    final props = context.watch(
      ownerNotifierProvider(_ownerId()).select((state) => state.properties),
    );
    final tours = context.watch(
      ownerNotifierProvider(_ownerId()).select((state) => state.tours),
    );
    final owner = context.read(ownerNotifierProvider(_ownerId()).notifier);
    final verified = owner.countByStatus(VerificationStatus.verified);
    final pending = owner.countByStatus(VerificationStatus.pending);
    final rejected = owner.countByStatus(VerificationStatus.rejected);
    return div(classes: 'bento-kpis', [
      _kpi('Live listings', '${props.length}', '$verified approved'),
      _kpi(
        '360° tours',
        '${tours.length}',
        '${owner.withTourCount} '
            '${owner.withTourCount == 1 ? 'listing' : 'listings'} with a tour',
      ),
      _kpi('Awaiting review', '$pending', 'Administrator checks each listing'),
      _kpi('Rejected', '$rejected', 'Needs changes before publishing'),
    ]);
  }
}

Component _kpi(String k, String v, String n) {
  return div(classes: 'kpi', [
    span(classes: 'k', [Component.text(k)]),
    span(classes: 'v', [Component.text(v)]),
    span(classes: 'n', [Component.text(n)]),
  ]);
}

// ----------------------------------------------------- portfolio health

/// Dark hero card with a donut showing the share of listings that are
/// approved versus still in flight (pending + rejected).
class _HealthCard extends StatelessComponent {
  const _HealthCard();

  @override
  Component build(BuildContext context) {
    final props = context.watch(
      ownerNotifierProvider(_ownerId()).select((state) => state.properties),
    );
    final owner = context.read(ownerNotifierProvider(_ownerId()).notifier);
    final total = props.length;
    final approved = owner.countByStatus(VerificationStatus.verified);
    final inFlight = total - approved;
    final pct = total > 0 ? (approved * 100 ~/ total) : 0;

    if (total == 0) {
      return div(classes: 'bento-hero', [
        div(classes: 'bento-card__head', [
          h3([Component.text('Portfolio health')]),
          span(classes: 'hero-badge', [Component.text('Empty')]),
        ]),
        div(classes: 'stack', [
          span(classes: 'title', [Component.text('No listings yet')]),
          p(classes: 'hero-cap', [
            Component.text(
              'Add your first commercial property to start the verification '
              'process. Its status will appear here at every step.',
            ),
          ]),
          AppLink(
            to: '/owner/add-property',
            classes: 'bento-cta',
            children: [Component.text('Add your first property')],
          ),
        ]),
      ]);
    }

    return div(classes: 'bento-hero', [
      div(classes: 'bento-card__head', [
        h3([Component.text('Portfolio health')]),
        span(classes: 'hero-badge', [Component.text('$total listings')]),
      ]),
      div(classes: 'donut-wrap', [
        div(classes: 'donut', styles: Styles(raw: {'--pct': '$pct'}), [
          div(classes: 'donut-center', [
            div(classes: 'dc-v', [Component.text('$pct%')]),
            div(classes: 'dc-k', [Component.text('approved')]),
          ]),
        ]),
      ]),
      div(classes: 'hero-legend', [
        span(classes: 'lg', [
          span(classes: 'dot a', []),
          Component.text('$approved approved'),
        ]),
        span(classes: 'lg', [
          span(classes: 'dot b', []),
          Component.text('$inFlight pending or rejected'),
        ]),
      ]),
      p(classes: 'hero-cap', [
        Component.text(
          '$pct% of your listings are approved. The ring reflects current '
          'verification status from the record store, not a forecast.',
        ),
      ]),
      AppLink(
        to: '/owner/properties',
        classes: 'bento-cta',
        children: [Component.text('Manage listings')],
      ),
    ]);
  }
}

// ----------------------------------------------------------- listings

class _ListingsCard extends StatelessComponent {
  const _ListingsCard();

  @override
  Component build(BuildContext context) {
    final props = context.watch(
      ownerNotifierProvider(_ownerId()).select((state) => state.properties),
    );
    return div(classes: 'bento-card bento-wide', [
      div(classes: 'bento-card__head', [
        h3([Component.text('Recent listings')]),
        span(classes: 'card-note', [Component.text('${props.length} total')]),
      ]),
      if (props.isEmpty)
        EmptyState(
          title: 'No listings yet',
          body:
              'Add your first commercial property to start the verification '
              'process. You will see its status here at every step — draft, '
              'pending review, approved or rejected.',
          action: const ActionLink(
            'Add your first property',
            href: '/owner/add-property',
            variant: 'primary',
          ),
        )
      else
        div(classes: 'blist', [for (final p in props.take(4)) _listingRow(p)]),
    ]);
  }
}

Component _listingRow(CommercialProperty p) {
  return AppLink(
    to: '/owner/property-detail?id=${p.id}',
    classes: 'brow',
    children: [
      div(classes: 'b-ico', [Icon('storefront', size: 'lg')]),
      div(classes: 'b-main', [
        div(classes: 't', [Component.text(p.title)]),
        div(classes: 's', [Component.text('${p.address}, ${p.city}')]),
        div(classes: 'badges', [
          StatusBadge(
            p.verification.label,
            tone: toneForVerification(p.verification),
            dot: true,
          ),
          if (p.hasTour) const StatusBadge('360° tour', tone: 'action'),
        ]),
      ]),
      div(classes: 'b-val', [
        div(classes: 'v', [Component.text(p.rentalDisplay)]),
        div(classes: 'p', [Component.text('per month')]),
      ]),
    ],
  );
}

// -------------------------------------------------------------- how works

Component _stepCard(String eyebrow, String title, String body) {
  return div(classes: 'bento-card', [
    span(classes: 'eyebrow-sm', [Component.text(eyebrow)]),
    h3([Component.text(title)]),
    p(classes: 'muted', [Component.text(body)]),
  ]);
}
