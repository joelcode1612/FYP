import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../data/auth_service.dart';
import '../../layouts/app_layout.dart';

/// The signed-in owner id from the server-verified profile. Each navigation is
/// a fresh document, so the family argument is stable for the page's lifetime.
String _ownerId() => WebAuth.profile?['user_id'] as String? ?? '';

/// Owner listings, laid out as the source's `properties.html`.
///
/// ```text
/// .page-head   "Listings" · "My commercial properties" · add action
/// .filters     .grid-2 → search field · status select
/// .rows        .row-card  (media · title/address/rent · actions)
/// ```
///
/// The source shows the owner's listings as **management rows** — each with
/// View status / Edit / 360° tour — not as the browse grid used on Explore.
/// The previous version reused the 3-column `.pgrid` card, so the owner had no
/// per-listing actions at all.
@client
class PropertiesPage extends StatefulComponent {
  const PropertiesPage({super.key});

  @override
  State<PropertiesPage> createState() => _PropertiesPageState();
}

class _PropertiesPageState extends State<PropertiesPage> {
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
      currentRoute: '/owner/properties',
      title: 'My commercial properties',
      eyebrow: 'Listings',
      subtitle:
          'The commercial spaces you have listed. Each row shows the asking '
          'rental, built-up area and current verification state.',
      actions: const [
        ActionLink('Add property', href: '/owner/add-property', icon: 'add'),
      ],
      // Inside the layout, so search/filter publishes rebuild only the
      // content, never the chrome.
      child: const _Content(),
    );
  }
}

class _Content extends StatelessComponent {
  const _Content();

  @override
  Component build(BuildContext context) {
    final state = context.watch(ownerNotifierProvider(_ownerId()));
    final owner = context.read(ownerNotifierProvider(_ownerId()).notifier);
    final properties = owner.filteredProperties;

    return state.loading
        ? const _Loading()
        : div(classes: 'stack stack--md', [
            _filters(state, owner),
            if (properties.isEmpty)
              EmptyState(
                title: 'You have no listings yet',
                body:
                    'Create your first commercial property listing. It '
                    'stays private until an administrator approves it.',
                action: const ActionLink(
                  'Add property',
                  href: '/owner/add-property',
                  variant: 'primary',
                ),
              )
            else
              div(classes: 'rows', [
                for (final p in properties) _row(p),
              ]),
          ]);
  }

  // ------------------------------------------------------------------ filters

  Component _filters(OwnerState state, OwnerNotifier owner) =>
      div(classes: 'filters', [
        div(classes: 'grid-2', [
          div(classes: 'field', [
            span(classes: 'field__label', [Component.text('Search')]),
            input(
              attributes: {
                'type': 'search',
                'placeholder': 'Title, address or city',
                if (state.query.isNotEmpty) 'value': state.query,
              },
              events: events<String>(onInput: owner.setQuery),
            ),
          ]),
          div(classes: 'field', [
            span(classes: 'field__label', [Component.text('Status')]),
            select(
              events: events<String>(
                onInput: (raw) => owner.setStatusFilter(switch (raw) {
                  'Draft' => VerificationStatus.draft,
                  'Pending review' => VerificationStatus.pending,
                  'Approved' => VerificationStatus.verified,
                  'Rejected' => VerificationStatus.rejected,
                  _ => null,
                }),
              ),
              [
                option(
                  value: 'All statuses',
                  attributes: {if (state.statusFilter == null) 'selected': ''},
                  [Component.text('All statuses')],
                ),
                for (final (label, status) in const [
                  ('Draft', VerificationStatus.draft),
                  ('Pending review', VerificationStatus.pending),
                  ('Approved', VerificationStatus.verified),
                  ('Rejected', VerificationStatus.rejected),
                ])
                  option(
                    value: label,
                    attributes: {
                      if (state.statusFilter == status) 'selected': '',
                    },
                    [Component.text(label)],
                  ),
              ],
            ),
          ]),
        ]),
      ]);

  // --------------------------------------------------------------------- rows

  Component _row(CommercialProperty prop) => div(classes: 'row-card', [
    span(classes: 'row-media', [Icon('storefront', size: 'lg')]),
    div(classes: 'row-main', [
      h3([Component.text(prop.title)]),
      div(classes: 'meta', [Component.text('${prop.address}, ${prop.city}')]),
      div(classes: 'meta', [
        Component.text(
          '${prop.rentalDisplay} · ${prop.sizeSqft.toStringAsFixed(0)} sq ft · '
          '${prop.propertyType}',
        ),
      ]),
      div(classes: 'badges', [
        StatusBadge(
          prop.verification.label,
          tone: toneForVerification(prop.verification),
          dot: true,
        ),
        if (prop.hasTour) const StatusBadge('360° tour', tone: 'action'),
        // Management responsibility comes from the backend, which derives it
        // from a real Agent assignment, the Owner identity or a documented
        // stewardship policy. An owner seeing "Managed by Agent" here means an
        // administrator actually assigned one — never a UI default.
        StatusBadge(
          prop.managerName == null || prop.managerName!.trim().isEmpty
              ? prop.managementLabel
              : '${prop.managementLabel} — ${prop.managerName}',
          tone: prop.managementLabel.contains('Agent')
              ? 'action'
              : prop.managementLabel.contains('SiteWise')
                  ? 'neutral'
                  : 'warning',
        ),
      ]),
    ]),
    div(classes: 'row-actions', [
      ActionLink(
        'View status',
        href: '/owner/property-detail?id=${prop.id}',
        variant: 'secondary',
      ),
      ActionLink(
        'Edit',
        href: '/owner/add-property?id=${prop.id}',
        variant: 'secondary',
      ),
      if (prop.hasTour)
        ActionLink(
          '360° tour',
          href: '/owner/tour-preview?id=${prop.id}',
          variant: 'secondary',
        ),
    ]),
  ]);
}

class _Loading extends StatelessComponent {
  const _Loading();

  @override
  Component build(BuildContext context) => div(classes: 'loading', [
    span(classes: 'spinner', []),
    Component.text('Loading listings…'),
  ]);
}
