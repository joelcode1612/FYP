import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_provider_compat/jaspr_provider_compat.dart' as provider;
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';
import '../../state/owner_view_model.dart';

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
  late final OwnerViewModel vm;

  @override
  void initState() {
    super.initState();
    vm = AppLocator.newOwnerViewModel();
    unawaited(vm.load());
  }

  @override
  void dispose() {
    vm.dispose();
    super.dispose();
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
      // Inside the layout, so search/filter emits rebuild only the content,
      // never the chrome.
      child: provider.ChangeNotifierProvider<OwnerViewModel>.value(
        value: vm,
        child: provider.Consumer<OwnerViewModel>(
          builder: (context, vm, child) {
            final properties = vm.filteredProperties;

            return vm.loading
                ? const _Loading()
                : div(classes: 'stack stack--md', [
                    _filters(),
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
          },
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ filters

  Component _filters() => div(classes: 'filters', [
    div(classes: 'grid-2', [
      div(classes: 'field', [
        span(classes: 'field__label', [Component.text('Search')]),
        input(
          attributes: {
            'type': 'search',
            'placeholder': 'Title, address or city',
            if (vm.query.isNotEmpty) 'value': vm.query,
          },
          events: events<String>(onInput: vm.setQuery),
        ),
      ]),
      div(classes: 'field', [
        span(classes: 'field__label', [Component.text('Status')]),
        select(
          events: events<String>(
            onInput: (raw) => vm.setStatusFilter(switch (raw) {
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
              attributes: {if (vm.statusFilter == null) 'selected': ''},
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
                attributes: {if (vm.statusFilter == status) 'selected': ''},
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
