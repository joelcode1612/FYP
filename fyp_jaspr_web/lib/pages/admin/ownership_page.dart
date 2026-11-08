import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/admin_ops_kit.dart';
import '../../components/dashboard_kit.dart';
import '../../components/ui.dart';
import '../../data/admin_api.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Ownership reviews — the administrator's queue of owner-linked listings.
///
/// ## What is real
///
/// * The queue is `GET /api/v1/properties/` (the local catalogue). Listing
///   ownership (`property.user_id`) is stamped server-side from the verified
///   identity — a client cannot forge it — so "linked to a claimant" means an
///   authenticated account actually holds this record.
/// * The claimant line resolves through the admin user API
///   (`userRepo.getUserById`), administrator + `aal2` enforced upstream.
///
/// ## What does not exist (stated on the page, not hidden)
///
/// There is **no ownership-claim model and no decision endpoint** on this
/// backend: no claim id, no document/evidence upload, no reason field, no
/// approve/reject route. The approved preview's `CL-####` claims, evidence
/// lists and decision dialog are *design intent*, not backing this build
/// could pretend to have — so the decision controls render disabled with the
/// exact blocker beside them, and the evidence region says plainly that no
/// document model exists. A queue row that cannot be decided is honest; a
/// green "Approved" toast writing nothing is not.
///
/// Layout follows the preview (metric row → queue | detail split) rebuilt on
/// `.panel` / `.btn` / `.st` so every shared theme applies unchanged.
@client
class AdminOwnershipPage extends StatefulComponent {
  const AdminOwnershipPage({super.key});

  @override
  State<AdminOwnershipPage> createState() => _OwnershipState();
}

class _OwnershipState extends State<AdminOwnershipPage> {
  bool _loading = true;
  String? _error;
  List<OwnershipRequest> _rows = const [];
  int? _selectedId;
  String _query = '';

  /// Resolved claimant for the selected row (`null` = no linked account,
  /// while [_ownerLoading] shows the lookup in flight).
  SitewiseUser? _owner;
  bool _ownerLoading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await AppLocator.adminApi.listOwnershipRequests();
      if (!mounted) return;
      int? selection;
      for (final row in rows) {
        if (row.awaitingDecision) {
          selection ??= row.propertyId;
        }
      }
      selection ??= rows.isEmpty ? null : rows.first.propertyId;
      setState(() {
        _rows = rows;
        _loading = false;
        _selectedId = selection;
      });
      _resolveOwner();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = AdminApi.message(error);
      });
    }
  }

  OwnershipRequest? get _selected {
    for (final row in _rows) {
      if (row.propertyId == _selectedId) return row;
    }
    return null;
  }

  List<OwnershipRequest> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _rows;
    return _rows
        .where(
          (row) =>
              '${row.displayName} ${row.area} ${row.status} '
                      '${row.ownerUserId ?? ''}'
                  .toLowerCase()
                  .contains(q),
        )
        .toList(growable: false);
  }

  /// Resolves the claimant identity for the current selection. Failures are
  /// shown as a placeholder line on the detail, never as a fabricated name.
  Future<void> _resolveOwner() async {
    final row = _selected;
    final ownerId = row?.ownerUserId;
    if (ownerId == null || ownerId.isEmpty) {
      setState(() {
        _owner = null;
        _ownerLoading = false;
      });
      return;
    }
    setState(() {
      _ownerLoading = true;
      _owner = null;
    });
    final owner = await AppLocator.userRepo.getUserById(ownerId);
    if (!mounted) return;
    setState(() {
      _owner = owner;
      _ownerLoading = false;
    });
  }

  void _select(int id) {
    setState(() => _selectedId = id);
    _resolveOwner();
  }

  // --- Fragments ------------------------------------------------------------

  Component _stats() {
    if (_loading) {
      return div(classes: 'ops-stats', [
        for (final icon in const ['fact_check', 'badge', 'schedule'])
          div(classes: 'ops-stat', [
            span(classes: 'ops-tile', [Icon(icon)]),
            div(classes: 'ops-stat__body', [const Skeleton(variant: 'text')]),
          ]),
      ]);
    }
    final linked = _rows.where((row) => row.ownerUserId != null).length;
    final awaiting = _rows.where((row) => row.awaitingDecision).length;
    final unavailable = _error != null;
    return div(classes: 'ops-stats', [
      OpsStat(
        icon: 'fact_check',
        label: 'Listings recorded',
        value: unavailable ? '—' : '${_rows.length}',
        note: unavailable ? 'Catalogue unavailable' : 'Local property records',
      ),
      OpsStat(
        icon: 'badge',
        label: 'Linked to a claimant',
        value: unavailable ? '—' : '$linked',
        note: unavailable
            ? 'Catalogue unavailable'
            : 'Ownership set by the server',
      ),
      OpsStat(
        icon: 'schedule',
        label: 'Awaiting a decision',
        value: unavailable ? '—' : '$awaiting',
        note: unavailable ? 'Catalogue unavailable' : 'No recorded status yet',
      ),
    ]);
  }

  Component _queuePanel() {
    return SectionCard(
      title: 'Review queue',
      child: div(classes: 'stack', [
        p(classes: 'ops-qrow__meta', [
          Component.text('Select a listing to inspect what the API records.'),
        ]),
        SearchInput(
          label: 'Search requests',
          placeholder: 'Title, area or status',
          ariaLabel: 'Search ownership requests',
          onInput: (value) => setState(() => _query = value),
        ),
        _queueBody(),
      ]),
    );
  }

  Component _queueBody() {
    if (_loading) return const Skeleton(variant: 'row', count: 4);
    if (_error != null) {
      return div(classes: 'stack', [
        InlineEmpty('The property catalogue could not be read: $_error'),
        ActionButton('Try again', variant: 'secondary', onClick: _load),
      ]);
    }
    final rows = _filtered;
    if (rows.isEmpty) {
      return InlineEmpty(
        _rows.isEmpty
            ? 'No owner-linked listings exist yet, so there is nothing to '
                  'review. The queue fills when an authenticated account '
                  'creates a listing.'
            : 'No requests match this search.',
      );
    }
    return div(classes: 'ops-list', [
      for (final row in rows)
        button(
          classes: 'ops-qrow',
          attributes: {
            'type': 'button',
            'aria-pressed': row.propertyId == _selectedId ? 'true' : 'false',
          },
          events: events(onClick: () => _select(row.propertyId)),
          [
            div(classes: 'ops-qrow__head', [
              span(classes: 'ops-qrow__id', [
                Component.text('PROPERTY #${row.propertyId}'),
              ]),
              row.awaitingDecision
                  ? StatusBadge('Unreviewed', tone: 'warning')
                  : StatusBadge(row.status, tone: 'neutral'),
            ]),
            span(classes: 'ops-qrow__title', [Component.text(row.displayName)]),
            span(classes: 'ops-qrow__meta', [
              Component.text(
                [
                  if (row.area.isNotEmpty) row.area,
                  if (row.ownerUserId != null)
                    'Claimant on file'
                  else
                    'No linked account',
                ].join(' · '),
              ),
            ]),
          ],
        ),
    ]);
  }

  Component _detailPanel() {
    return SectionCard(title: 'Request details', child: _detailBody());
  }

  Component _detailBody() {
    if (_loading) return const Skeleton(variant: 'row', count: 5);
    if (_error != null) {
      return InlineEmpty('Details are unavailable while the load fails.');
    }
    final row = _selected;
    if (row == null) {
      return InlineEmpty(
        'Select a listing from the queue to see its recorded details.',
      );
    }

    final ownerId = row.ownerUserId;
    final ownerLine = ownerId == null
        ? 'No linked account — the record carries no owning identity.'
        : _ownerLoading
        ? 'Looking up account…'
        : _owner == null
        ? 'Account $ownerId (not readable from the directory)'
        : '${_owner!.name} · ${_owner!.email}';

    return div(classes: 'stack', [
      div(classes: 'ops-detail-head', [
        span(classes: 'ops-qrow__id', [
          Component.text('PROPERTY #${row.propertyId}'),
        ]),
        row.awaitingDecision
            ? const StatusBadge('Unreviewed', tone: 'warning')
            : StatusBadge(
                row.status.isEmpty ? 'Unreviewed' : row.status,
                tone: 'neutral',
              ),
      ]),
      div([
        InfoRow(icon: 'storefront', label: 'Listing', value: row.displayName),
        InfoRow(icon: 'person', label: 'Claimant', value: ownerLine),
        InfoRow(
          icon: 'pin_drop',
          label: 'Area',
          value: row.area.isNotEmpty ? row.area : 'Not recorded on this row',
        ),
        InfoRow(
          icon: 'rule',
          label: 'Recorded status',
          value: row.status.isNotEmpty ? row.status : 'None recorded',
        ),
      ]),
      hr(classes: 'ops-rule'),
      h3(classes: 'ops-subhead', [Component.text('Submitted evidence')]),
      InlineEmpty(
        'No evidence documents exist to show: this backend has no ownership '
        'claim, document or review-note model. Identity documents referenced '
        'by the design preview are not stored anywhere this API can read.',
      ),
      // Decisions: rendered, disabled, and explained — never simulated.
      div(classes: 'ops-card__actions', [
        ActionButton('Approve', onClick: null, icon: 'check'),
        ActionButton(
          'Request information',
          onClick: null,
          variant: 'secondary',
        ),
        ActionButton('Reject', onClick: null, variant: 'danger-outline'),
      ]),
      ActionNotice(
        'Decisions are blocked on this build. The backend exposes no '
        'approve/reject route, no review reason field and no audit trail for '
        'ownership changes, so a recorded decision would be stored nowhere. '
        'Until that endpoint exists, this screen reads the real queue and '
        'writes nothing.',
        tone: 'warn',
      ),
    ]);
  }

  @override
  Component build(BuildContext context) {
    return AppLayout(
      role: AppRole.admin,
      currentRoute: '/admin/ownership',
      title: 'Ownership reviews',
      eyebrow: 'Operations',
      subtitle:
          'Owner-linked listings awaiting a recorded decision. Every number '
          'and row comes from the live property catalogue; claims holding no '
          'review record are shown as unreviewed.',
      actions: [ActionButton('Refresh', onClick: _load, variant: 'secondary')],
      child: div(classes: 'stack ops-fade', [
        Callout(
          'Ownership decisions are read-only on this build: there is no '
          'claim, evidence or decision API behind them. The queue itself is '
          'live — owner identity is stamped by the server, never by the '
          'browser.',
          tone: 'warning',
          icon: 'gpp_maybe',
        ),
        _stats(),
        div(classes: 'ops-split', [_queuePanel(), _detailPanel()]),
      ]),
    );
  }
}
