import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/dashboard_kit.dart';
import '../../components/ui.dart';
import '../../data/agent_records.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// One assigned listing, read-only.
///
/// Kept separate from the entrepreneur and admin detail pages on purpose: those
/// render role-specific affordances (save/compare, approve/reject). An agent
/// has no authorised write path — `ApiPropertyRepository.updateProperty`
/// throws, and assignment is not a server concept — so this view shows the
/// record and states what the agent can and cannot do with it.
class AgentPropertyDetailPage extends StatefulComponent {
  final String id;

  const AgentPropertyDetailPage({super.key, required this.id});

  @override
  State<AgentPropertyDetailPage> createState() =>
      _AgentPropertyDetailPageState();
}

class _AgentPropertyDetailPageState extends State<AgentPropertyDetailPage> {
  late final Future<CommercialProperty?> future;

  @override
  void initState() {
    super.initState();
    future = AppLocator.properties.detail(component.id);
  }

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.agent,
      currentRoute: '/agent/listings',
      title: 'Listing record',
      eyebrow: 'Staff portal · agent',
      subtitle: 'The imported dataset behind one assigned unit.',
      actions: [
        ActionLink(
          'Back to listings',
          href: '/agent/listings',
          variant: 'secondary',
        ),
      ],
      child: FutureBuilder<CommercialProperty?>(
        future: future,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return snapshot.connectionState == ConnectionState.done
                ? EmptyState(
                    title: 'Listing not found',
                    body:
                        'No record with id “${component.id}” exists in the '
                        'catalog. Assigned-listing links carry the id from the '
                        'dataset, so a stale bookmark is the usual cause.',
                    action: ActionLink(
                      'Back to listings',
                      href: '/agent/listings',
                    ),
                  )
                : div(classes: 'loading', [
                    span(classes: 'spinner', []),
                    Component.text('Loading listing…'),
                  ]);
          }
          final property = snapshot.data!;
          return div(classes: 'stack', [
            Callout(
              'Read-only. Editing needs an assignment the server recognises, '
              'and the repository refuses writes from the web client, so no '
              'form is offered here.',
              tone: 'info',
              icon: 'lock',
            ),
            div(classes: 'bento', [
              _factsCard(property),
              _statusCard(property),
              _demandCard(property),
              _ownerCard(property),
            ]),
          ]);
        },
      ),
    );
  }

  Component _factsCard(CommercialProperty property) {
    return div(classes: 'bento-card bento-wide', [
      div(classes: 'bento-card__head', [
        h3([Component.text(property.title)]),
        span(classes: 'card-note', [Component.text(property.id)]),
      ]),
      DataTable(
        columns: const [DataColumn('Attribute'), DataColumn('Recorded value')],
        rows: [
          [
            Component.text('Location'),
            Component.text(
              '${property.address}, ${property.city} ${property.postcode}, '
              '${property.state}',
            ),
          ],
          [Component.text('Type'), Component.text(property.propertyType)],
          [
            Component.text('Floor area'),
            Component.text('${property.sizeSqft.toStringAsFixed(0)} sqft'),
          ],
          [
            Component.text('Asking rent'),
            Component.text(property.rentalDisplay),
          ],
          [
            Component.text('Rent per sqft'),
            Component.text(
              property.rentalPerSqft > 0
                  ? 'RM ${property.rentalPerSqft.toStringAsFixed(2)}'
                  : 'Not derivable (no area recorded)',
            ),
          ],
          [
            Component.text('Coordinates'),
            Component.text(
              '${property.latitude.toStringAsFixed(5)}, '
              '${property.longitude.toStringAsFixed(5)}',
            ),
          ],
        ],
      ),
    ]);
  }

  Component _statusCard(CommercialProperty property) {
    return div(classes: 'bento-card', [
      div(classes: 'bento-card__head', [
        h3([Component.text('Review state')]),
        Pill(
          AgentRecords.listingLabel(property.verification),
          tone: AgentRecords.listingTone(property.verification),
        ),
      ]),
      div(classes: 'aside-list', [
        AsideRow(
          badge: property.suitabilityScore.toStringAsFixed(0),
          tone: 'teal',
          title: 'Suitability index',
          caption: 'Stored with the imported row, not computed on this page.',
        ),
        AsideRow(
          badge: property.hasTour ? '360' : '—',
          tone: property.hasTour ? 'blue' : 'neutral',
          title: 'Virtual tour',
          caption: property.hasTour
              ? 'A panorama is attached to this record.'
              : 'No tour is attached to this record.',
        ),
        AsideRow(
          badge: '↻',
          title: 'Last change',
          caption:
              'The dataset carries no modification timestamp, so the date a '
              'status changed is unknown.',
        ),
      ]),
    ]);
  }

  Component _demandCard(CommercialProperty property) {
    return div(classes: 'bento-card', [
      div(classes: 'bento-card__head', [
        h3([Component.text('Demand signals')]),
        span(classes: 'card-note', [Component.text('None captured')]),
      ]),
      Callout(
        'Views, impressions and enquiries for this unit are not available. '
        'No interaction event is recorded anywhere in this project, so the '
        'agent-facing metrics stay empty until the events exist.',
        tone: 'warning',
        icon: 'visibility_off',
      ),
      if (property.requirements.isNotEmpty)
        div(classes: 'badges', [
          for (final requirement in property.requirements)
            Pill(requirement, tone: 'neutral'),
        ]),
    ]);
  }

  Component _ownerCard(CommercialProperty property) {
    return div(classes: 'bento-card bento-wide', [
      div(classes: 'bento-card__head', [
        h3([Component.text('Ownership')]),
        span(classes: 'card-note', [Component.text('Not modelled')]),
      ]),
      p(classes: 'muted', [
        Component.text(
          '${AgentRecords.ownerLabel(property)}. The API serves listing rows '
          'without an owner reference, so an agent cannot see whose unit this '
          'is, contact them, or prove they are authorised to represent it. An '
          'assignment table would supply all three.',
        ),
      ]),
    ]);
  }
}
