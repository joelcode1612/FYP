import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/admin_ops_kit.dart';
import '../../components/dashboard_kit.dart';
import '../../components/ui.dart';
import '../../layouts/app_layout.dart';

/// Survey campaigns — the administrator's area-research campaign screen.
///
/// ## The blocker, stated first
///
/// This backend has **no campaign model at all**: no table, no migration, no
/// repository, no endpoint. The design's `SV-####` campaigns, response
/// counts and open/close toggles were reviewed against the API and exist only
/// in the preview (`docs/11_ROLE_MODEL_MFA_DELIVERABLES.md` §5.2 documents the
/// intent, not an implementation). So this page does the only honest thing:
///
/// * renders its structure and its intent (what the screen will govern),
/// * shows one explicit unavailable state instead of an empty-looking
///   directory that implies data is merely missing,
/// * pins the primary action **disabled** with the reason next to it,
/// * lists the exact backend surface that would have to exist — read-only
///   documentation, not fabricated campaign rows.
///
/// Nothing here is stored locally and nothing here claims a campaign was
/// created. When the API lands, this shell keeps its layout and swaps the
/// empty state for the live list.
@client
class AdminCampaignsPage extends StatefulComponent {
  const AdminCampaignsPage({super.key});

  @override
  State<AdminCampaignsPage> createState() => _AdminCampaignsPageState();
}

class _AdminCampaignsPageState extends State<AdminCampaignsPage> {
  /// No data is loaded, and no local draft store is faked: a draft that
  /// survives only in this browser tab would read as a saved campaign.
  bool _specOpen = false;

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.admin,
      currentRoute: '/admin/campaigns',
      title: 'Survey campaigns',
      eyebrow: 'Operations',
      subtitle:
          'Coordinate area-based research: draft, open, close and track '
          'response totals per study area.',
      actions: [
        ActionButton(
          'New campaign',
          icon: 'add',
          // Disabled on purpose: see the callout below the hero.
          onClick: null,
        ),
      ],
      child: div(classes: 'stack ops-fade', [
        OpsHero(
          icon: 'campaign',
          title: 'Research planning is designed but not yet provisioned',
          body:
              'Campaign lifecycle (draft → open → closed) and per-area '
              'response counters are specified in the approved design. The '
              'backend does not implement them, so this screen will not '
              'show campaign rows until it does.',
          action: ActionButton(
            'New campaign',
            icon: 'add',
            variant: 'secondary',
            onClick: null,
          ),
        ),
        Callout(
          'No survey-campaign functionality exists on this backend: there is '
          'no campaigns table, no create/open/close endpoint and no response '
          'store, so the actions above are disabled rather than simulated. '
          'Creating a draft only in this browser tab would look saved while '
          'being saved nowhere.',
          tone: 'warning',
          icon: 'construction',
        ),
        SectionCard(
          title: 'Campaign overview',
          child: EmptyState(
            title: 'No campaigns exist',
            body:
                'This environment has never had a campaign record to list. '
                'Once the campaign API is implemented, every row shown here '
                'is created through it on the server — this page keeps no '
                'local drafts.',
          ),
        ),
        SectionCard(
          title: 'Backend surface this page is waiting for',
          action: [
            ActionButton(
              _specOpen ? 'Hide detail' : 'Show detail',
              variant: 'ghost',
              onClick: () => setState(() => _specOpen = !_specOpen),
            ),
          ],
          flush: true,
          child: DataTable(
            columns: const [
              DataColumn('Capability'),
              DataColumn('Expected endpoint'),
              DataColumn('State'),
            ],
            rows: [
              [
                Component.text('List campaigns'),
                CellIdentity(
                  title: 'GET /api/v1/surveys/campaigns',
                  caption: 'Query by area and status',
                ),
                const StatusBadge('Not implemented', tone: 'danger'),
              ],
              [
                Component.text('Create a draft'),
                CellIdentity(
                  title: 'POST /api/v1/surveys/campaigns',
                  caption: 'Title, area, response target',
                ),
                const StatusBadge('Not implemented', tone: 'danger'),
              ],
              [
                Component.text('Open / close a campaign'),
                CellIdentity(
                  title: 'PATCH /api/v1/surveys/campaigns/{id}/status',
                  caption: 'Administrator + MFA, audited',
                ),
                const StatusBadge('Not implemented', tone: 'danger'),
              ],
              [
                Component.text('Report response totals'),
                CellIdentity(
                  title: 'GET /api/v1/surveys/campaigns/{id}/responses',
                  caption: 'Counts only — never participant answers',
                ),
                const StatusBadge('Not implemented', tone: 'danger'),
              ],
            ],
            emptyLabel: 'No capability rows.',
          ),
        ),
        if (_specOpen)
          Callout(
            'Implementation note: campaign storage would need a new table, '
            'which is out of scope for this build — no schema change is '
            'allowed without explicit approval. The list above is the '
            'contract the page already codes against.',
            tone: 'info',
            icon: 'info',
          ),
      ]),
    );
  }
}
