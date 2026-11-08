/// Live reads and writes for the five administrator operations pages
/// (Ownership reviews, Agents, Campaigns, Activity, Surveys).
///
/// Everything here goes through the same bearer-aware bridge the rest of the
/// web tree uses ([WebAuth.request] in `auth_service.dart`): the access token
/// is attached by the platform (Supabase session in the browser, the
/// `sitewise_token` cookie during SSR), every call is same-origin `/api/*` and
/// the Jaspr proxy forwards it to FastAPI, which enforces **administrator +
/// `aal2`** server-side on every staff route. This file transports and maps —
/// it never decides authorization and never fabricates a record.
///
/// Endpoints consumed (all exist in `backend/src/sitewise/api/v1/staff.py`
/// and `properties.py`):
///
/// | Method | Path                                    | Used by |
/// |--------|-----------------------------------------|---------|
/// | GET    | `/api/v1/staff/agents`                  | Agent management directory |
/// | POST   | `/api/v1/staff/agents`                  | Invite dialog |
/// | PATCH  | `/api/v1/staff/agents/{id}/status`      | Suspend / reactivate |
/// | GET    | `/api/v1/staff/invitations`             | Invitation table |
/// | GET    | `/api/v1/staff/audit`                   | System activity timeline |
/// | GET    | `/api/v1/properties/`                   | Ownership review queue |
///
/// No endpoint is invented here: `Survey campaigns` and `Community surveys`
/// have **no backend surface at all**, which is why those two pages render an
/// explicit unavailable state instead of calling this repository.
library;

import 'auth_service.dart';

/// One agent account row from `GET /api/v1/staff/agents`.
///
/// The backend merges the local enforcement-mirror profile (`_mirror_payload`)
/// with the Supabase `agent` profile (`agent_profile`), which is present only
/// once the profile row exists — every field is therefore read defensively.
class StaffAgent {
  final String userId;
  final String fullName;
  final String email;
  final String phone;
  final String role;
  final String status;

  /// `""` when the Supabase `agent` profile row does not exist yet.
  final String agentId;

  /// `""` when the agent has no linked `company` row.
  final String companyId;

  const StaffAgent({
    required this.userId,
    required this.fullName,
    required this.email,
    required this.phone,
    required this.role,
    required this.status,
    required this.agentId,
    required this.companyId,
  });

  factory StaffAgent.fromJson(Map<String, dynamic> row) {
    final profile = row['agent_profile'];
    return StaffAgent(
      userId: '${row['user_id'] ?? ''}',
      fullName: '${row['full_name'] ?? ''}'.trim(),
      email: '${row['email'] ?? ''}',
      phone: '${row['phone_number'] ?? ''}',
      role: '${row['role'] ?? ''}',
      status: '${row['account_status'] ?? ''}',
      agentId: profile is Map<String, dynamic>
          ? '${profile['agent_id'] ?? ''}'
          : '',
      companyId: profile is Map<String, dynamic>
          ? '${profile['company_id'] ?? ''}'
          : '',
    );
  }

  /// Display name: the legal name when present, the email otherwise — the
  /// same fallback `ApiUserRepository` applies, so headers cannot disagree
  /// with the user directory for the same account.
  String get displayName => fullName.isNotEmpty ? fullName : email;
}

/// One row of `GET /api/v1/staff/invitations`.
///
/// `staff_invitations` columns are read defensively (the backend returns the
/// table `select("*")` verbatim), so an added or renamed column can never
/// break the table render.
class StaffInvitation {
  final String email;
  final String status;
  final String createdAt;
  final String invitedById;

  const StaffInvitation({
    required this.email,
    required this.status,
    required this.createdAt,
    required this.invitedById,
  });

  factory StaffInvitation.fromJson(Map<String, dynamic> row) => StaffInvitation(
    email: '${row['invited_email'] ?? row['email'] ?? ''}',
    status: '${row['status'] ?? ''}',
    createdAt: '${row['created_at'] ?? ''}',
    invitedById: '${row['invited_by_user_id'] ?? ''}',
  );
}

/// One row of `GET /api/v1/staff/audit` (the `role_change_audit` table).
class AuditEvent {
  final String action;
  final String affectedEmail;
  final String affectedUserId;
  final String performedByEmail;
  final String createdAt;
  final String? previousRole;
  final String? newRole;
  final String? previousStatus;
  final String? newStatus;
  final Map<String, dynamic>? details;

  const AuditEvent({
    required this.action,
    required this.affectedEmail,
    required this.affectedUserId,
    required this.performedByEmail,
    required this.createdAt,
    this.previousRole,
    this.newRole,
    this.previousStatus,
    this.newStatus,
    this.details,
  });

  factory AuditEvent.fromJson(Map<String, dynamic> row) => AuditEvent(
    action: '${row['action'] ?? ''}',
    affectedEmail: '${row['affected_email'] ?? ''}',
    affectedUserId: '${row['affected_user_id'] ?? ''}',
    performedByEmail: '${row['performed_by_email'] ?? ''}',
    createdAt: '${row['created_at'] ?? ''}',
    previousRole: row['previous_role'] as String?,
    newRole: row['new_role'] as String?,
    previousStatus: row['previous_status'] as String?,
    newStatus: row['new_status'] as String?,
    details: row['details'] is Map<String, dynamic>
        ? row['details'] as Map<String, dynamic>
        : null,
  );

  /// Grouping key for the activity filters: `staff.invited` → `staff`.
  String get group => action.contains('.') ? action.split('.').first : action;

  /// The account the event concerns, for search and the subject line.
  String get subject =>
      affectedEmail.isNotEmpty ? affectedEmail : affectedUserId;
}

/// One owner-linked listing from `GET /api/v1/properties/` — the real
/// ownership-claim signal this backend keeps (`property.user_id` is stamped
/// from the verified identity and cannot be set by a client).
///
/// There is **no claim/ownership-request table** and **no decision endpoint**;
/// this row is the honest, minimal queue the existing API can produce. The
/// page says so instead of implying a workflow the backend cannot back.
class OwnershipRequest {
  final int propertyId;
  final String title;
  final String status;

  /// The claiming account, `null` when the row has no owning identity.
  final String? ownerUserId;

  /// Free-text location fields the row actually carries; `""` when unset.
  final String area;

  const OwnershipRequest({
    required this.propertyId,
    required this.title,
    required this.status,
    required this.ownerUserId,
    required this.area,
  });

  factory OwnershipRequest.fromJson(Map<String, dynamic> row) {
    final owner = row['user_id'];
    final district = '${row['district_id'] ?? ''}';
    final normalized = '${row['normalized_address'] ?? ''}';
    return OwnershipRequest(
      propertyId: (row['property_id'] as num?)?.toInt() ?? 0,
      title: '${row['title'] ?? ''}'.trim(),
      status: '${row['status'] ?? ''}'.trim(),
      ownerUserId: owner == null ? null : '$owner',
      area: normalized.isNotEmpty
          ? normalized
          : district.isNotEmpty
          ? district
          : '',
    );
  }

  /// Display title: the recorded title, falling back to the record id so a
  /// title-less row is still addressable rather than rendering as a blank
  /// card.
  String get displayName => title.isNotEmpty ? title : '#$propertyId';

  /// Untouched rows carry no status (`NULL`), which is what "awaiting a
  /// decision" means here — never an invented label.
  bool get awaitingDecision => status.isEmpty;
}

/// Reads/writes for the operations pages. Instances are cheap; `AppLocator`
/// exposes one shared instance.
class AdminApi {
  const AdminApi();

  /// Strips the VM/JS exception prefixes the bridge can add, so dialogs show
  /// the backend's own `detail` sentence ("This email already belongs to an
  /// existing Supabase account. ...") instead of `Error: ...`.
  static String message(Object error) {
    var raw = error.toString();
    raw = raw.replaceFirst(
      RegExp(r'^((Bad state|Exception|Error|StateError)(\([^)]*\))?):\s*'),
      '',
    );
    raw = raw.replaceFirst(RegExp(r'^(Exception|Error)\([^)]*\):\s*'), '');
    final trimmed = raw.trim();
    return trimmed.isEmpty ? 'The request could not be completed.' : trimmed;
  }

  /// Wraps a bare-array response the way both bridges do (`{'data': [...]}`).
  static List<Map<String, dynamic>> _rows(dynamic payload) {
    if (payload is Map<String, dynamic>) {
      final data = payload['data'];
      if (data is List) return data.cast<Map<String, dynamic>>();
      return [payload];
    }
    if (payload is List) return payload.cast<Map<String, dynamic>>();
    return const [];
  }

  // --- Agent management -----------------------------------------------------

  /// `GET /api/v1/staff/agents` — accounts whose role is `agent`.
  Future<List<StaffAgent>> listAgents() async {
    final payload = await WebAuth.request('/api/v1/staff/agents');
    return _rows(payload).map(StaffAgent.fromJson).toList(growable: false);
  }

  /// `POST /api/v1/staff/agents` — provisions the identity and emails the
  /// Supabase password-setup link.
  ///
  /// Throws the backend's `detail` sentence on failure; the invite dialog
  /// renders it verbatim (notably the 409 that asks for
  /// `allowExisting: true` before an existing account may receive staff
  /// access).
  Future<Map<String, dynamic>> createAgent({
    required String fullName,
    required String email,
    String? phoneNumber,
    String? companyName,
    bool allowExisting = false,
  }) {
    return WebAuth.request(
      '/api/v1/staff/agents',
      method: 'POST',
      body: {
        'full_name': fullName,
        'email': email,
        if (phoneNumber != null && phoneNumber.isNotEmpty)
          'phone_number': phoneNumber,
        if (companyName != null && companyName.isNotEmpty)
          'company_name': companyName,
        'allow_existing': allowExisting,
      },
    );
  }

  /// `PATCH /api/v1/staff/agents/{id}/status` — the backend constrains the
  /// target to `active` / `suspended` and rejects a no-op with 409, so this
  /// method never soft-fails into a silent success.
  Future<Map<String, dynamic>> setAgentStatus(String userId, String status) =>
      WebAuth.request(
        '/api/v1/staff/agents/$userId/status',
        method: 'PATCH',
        body: {'account_status': status},
      );

  /// `GET /api/v1/staff/invitations` — Supabase invite tracking.
  Future<List<StaffInvitation>> listInvitations() async {
    final payload = await WebAuth.request('/api/v1/staff/invitations');
    return _rows(payload).map(StaffInvitation.fromJson).toList(growable: false);
  }

  // --- System activity ------------------------------------------------------

  /// `GET /api/v1/staff/audit?affected_user_id=` — newest first, capped at
  /// 200 rows server-side. When [affectedUserId] is null the whole retained
  /// window is returned; the page states both limits out loud.
  Future<List<AuditEvent>> listAudit({String? affectedUserId}) async {
    final payload = await WebAuth.request(
      affectedUserId == null || affectedUserId.isEmpty
          ? '/api/v1/staff/audit'
          : '/api/v1/staff/audit?affected_user_id=${Uri.encodeQueryComponent(affectedUserId)}',
    );
    return _rows(payload).map(AuditEvent.fromJson).toList(growable: false);
  }

  // --- Ownership reviews ----------------------------------------------------

  /// `GET /api/v1/properties/` — the local `property` catalogue (capped at
  /// 200 rows; the endpoint itself accepts `offset`).
  ///
  /// Public browse by design, but the queue is rendered inside the
  /// administrator shell, and every decision on this build stays blocked
  /// until a decision endpoint exists — see the ownership page's callout.
  Future<List<OwnershipRequest>> listOwnershipRequests() async {
    final rows = <OwnershipRequest>[];
    var offset = 0;
    const limit = 200;
    while (true) {
      final payload = await WebAuth.request(
        '/api/v1/properties/?limit=$limit&offset=$offset',
      );
      final page = _rows(payload);
      rows.addAll(page.map(OwnershipRequest.fromJson));
      if (page.length < limit) break;
      offset += page.length;
      if (offset >= 2000) break;
    }
    return List.unmodifiable(rows);
  }
}
