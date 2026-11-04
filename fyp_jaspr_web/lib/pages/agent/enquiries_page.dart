import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/dashboard_kit.dart';
import '../../components/ui.dart';
import '../../data/agent_records.dart';
import '../../layouts/app_layout.dart';

/// Enquiry list for an agent.
///
/// ## There is no enquiry storage
///
/// Nothing in the schema or the live API can hold a message between a
/// prospective tenant and an agent: no `enquiries` table, no contact-button
/// event, no endpoint. These rows are the brief's proposed shape of the
/// screen, kept to the five fields an enquiry actually needs.
///
/// Two consequences are enforced here rather than mentioned:
/// * **No phone numbers or messaging deep links.** A contact affordance would
///   point at a number that does not exist, so the row states how the enquiry
///   arrived instead of pretending an agent can reply from this page.
/// * **No lead scoring.** Quality scores need enquiry history to rank
///   against; without it a score would be decoration.
class AgentEnquiriesPage extends StatelessComponent {
  const AgentEnquiriesPage({super.key});

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.agent,
      currentRoute: '/agent/enquiries',
      title: 'Enquiries',
      subtitle:
          'What a prospective tenant asked about, which listing it concerns, '
          'and where the conversation stands.',
      eyebrow: 'Staff portal · agent',
      actions: [
        ActionLink(
          'Assigned listings',
          href: '/agent/listings',
          variant: 'secondary',
        ),
      ],
      child: div(classes: 'stack', [
        Callout(
          'Prototype screen. Enquiries have no backend: no table stores them '
          'and no contact event creates one. The rows below describe the '
          'shape of the workflow, not messages anyone has sent.',
          tone: 'warning',
          icon: 'shield',
        ),
        SectionCard(
          title: 'Inbox · ${demoEnquiries.length} demonstration enquiries',
          flush: true,
          child: DataTable(
            columns: const [
              DataColumn('Reference'),
              DataColumn('Enquirer'),
              DataColumn('Listing'),
              DataColumn('Source'),
              DataColumn('Received'),
              DataColumn('Status'),
            ],
            rows: [
              for (final enquiry in demoEnquiries)
                [
                  Component.text(enquiry.id),
                  CellIdentity(
                    title: enquiry.enquirer,
                    caption: 'No contact details are stored',
                  ),
                  Component.text(enquiry.property),
                  Component.text(enquiry.contact),
                  Component.text(enquiry.received),
                  Pill(
                    enquiry.status,
                    tone: switch (enquiry.status) {
                      'New' => 'action',
                      'Closed' => 'neutral',
                      _ => 'warning',
                    },
                  ),
                ],
            ],
          ),
        ),
        div(classes: 'bento', [_proposedCard(), _excludedCard()]),
      ]),
    );
  }

  /// What an enquiry would need to become real, stated as the schema it lacks.
  Component _proposedCard() {
    return div(classes: 'bento-card bento-wide', [
      div(classes: 'bento-card__head', [
        h3([Component.text('To make this page real')]),
        span(classes: 'card-note', [Component.text('Proposed')]),
      ]),
      DataTable(
        columns: const [
          DataColumn('Storage'),
          DataColumn('Holds'),
          DataColumn('Unblocks'),
        ],
        rows: [
          [
            Component.text('enquiries'),
            Component.text(
              'listing, agent, enquirer, contact, message, status',
            ),
            Component.text('This inbox, with real rows and a status you set'),
          ],
          [
            Component.text('contact events'),
            Component.text('which listing a button was pressed on, and when'),
            Component.text('Enquiry creation without an agent typing it in'),
          ],
          [
            Component.text('property_assignments'),
            Component.text('listing → agent → owner'),
            Component.text('Filtering the inbox to listings you actually hold'),
          ],
        ],
      ),
      p(classes: 'stat-note', [
        Component.text(
          'Proposed only. No migration has been written and the schema is '
          'unchanged, so none of these tables exist yet.',
        ),
      ]),
    ]);
  }

  Component _excludedCard() {
    return div(classes: 'bento-card', [
      div(classes: 'bento-card__head', [
        h3([Component.text('Deliberately not shown')]),
        span(classes: 'card-note', [Component.text('Scope')]),
      ]),
      div(classes: 'aside-list', [
        for (final item in const [
          ('Score', 'No enquiry history exists to rank a lead against.'),
          ('WhatsApp', 'A number would be invented, not retrieved.'),
          ('CRM view', 'Owner and pipeline data are not modelled.'),
          ('Auto-reply', 'Nothing confirms an agent identity server-side.'),
        ])
          AsideRow(badge: '—', title: item.$1, caption: item.$2),
      ]),
    ]);
  }
}
