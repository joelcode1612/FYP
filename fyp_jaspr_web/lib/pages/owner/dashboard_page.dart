import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/bloc.dart';
import '../../components/letter_reveal.dart';
import '../../components/ui.dart';
import '../../data/app_locator.dart';
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
/// Every figure is a live count from [OwnerCubit]; nothing is fabricated.
class DashboardPage extends StatefulComponent {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  late final OwnerCubit vm;

  @override
  void initState() {
    super.initState();
    vm = AppLocator.newOwnerCubit();
    unawaited(vm.load());
  }

  @override
  void dispose() {
    unawaited(vm.close());
    super.dispose();
  }

  @override
  Component build(BuildContext context) {
    return CubitBuilder<OwnerCubit, OwnerState>(
      cubit: vm,
      builder: (context, _) {
        return AppLayout(
          role: AppRole.owner,
          currentRoute: '/owner',
          title: 'Your portfolio',
          // The source dashboard has no page header — its first element is
          // `.bento-head` (eyebrow + greeting + actions). Rendering both the
          // layout header and the bento head produced two competing titles,
          // which the source does not have.
          showPageHead: false,
          child: vm.loading
              ? const _Loading()
              : div(classes: 'stack', [
                  _head(),
                  _kpis(),
                  div(classes: 'bento', [
                    _healthCard(),
                    _listingsCard(),
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
                  ]),
                  p(classes: 'stat-note', [
                    Component.text(
                      'Every figure above is a live count from your saved '
                      'records. Verification status reflects the current state '
                      'of each listing in the record store.',
                    ),
                  ]),
                ]),
        );
      },
    );
  }

  // -------------------------------------------------------------------- head

  Component _head() {
    return div(classes: 'bento-head', [
      div(classes: 'bh-title', [
        span(classes: 'eyebrow-sm', [Component.text('Owner workspace')]),
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

  // -------------------------------------------------------------------- KPIs

  Component _kpis() {
    final props = vm.properties;
    final verified = vm.countByStatus(VerificationStatus.verified);
    final pending = vm.countByStatus(VerificationStatus.pending);
    final rejected = vm.countByStatus(VerificationStatus.rejected);
    return div(classes: 'bento-kpis', [
      _kpi('Live listings', '${props.length}', '$verified approved'),
      _kpi(
        '360° tours',
        '${vm.tours.length}',
        '${vm.withTourCount} '
            '${vm.withTourCount == 1 ? 'listing' : 'listings'} with a tour',
      ),
      _kpi('Awaiting review', '$pending', 'Administrator checks each listing'),
      _kpi('Rejected', '$rejected', 'Needs changes before publishing'),
    ]);
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
  Component _healthCard() {
    final props = vm.properties;
    final total = props.length;
    final approved = vm.countByStatus(VerificationStatus.verified);
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

  // ----------------------------------------------------------- listings

  Component _listingsCard() {
    final props = vm.properties;
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
}

class _Loading extends StatelessComponent {
  const _Loading();

  @override
  Component build(BuildContext context) => div(classes: 'loading', [
    span(classes: 'spinner', []),
    Component.text('Loading your portfolio…'),
  ]);
}
