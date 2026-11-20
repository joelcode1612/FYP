import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../application/services/service_locator.dart';
import '../../../../core/theme/sitewise_m3.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../widgets/m3_kit.dart';
import '../shell/provider_tab_scope.dart';
import 'provider_models.dart';
import 'provider_profile_edit_sheet.dart';
import 'provider_ui.dart';
import 'provider_workspace_service.dart';

/// Owner / Agent profile, redesigned.
///
/// One page serves both provider roles — the workspace's routing contract
/// maps `owner` and `agent` onto the same `/provider` stack — and the layout
/// branches on the authenticated role, never on a client-side guess:
///
/// * **Property Owner** — identity + account overview, the honest identity
///   (e-KYC) state, the administrator-reviewed account verification, the
///   listing destinations and account actions.
/// * **Agent** — the simplified agent details (verification status, agency,
///   joined date), per-listing authorizations and account actions.
///
/// Every value is read from the authenticated API: `/auth/me` for the
/// identity and the account's joined date, `ProviderListingsService` for the
/// role's authorized listing counts, `/provider/verification` for the account
/// verification, and `/staff/me/listings` for the agent's own profile row and
/// assignments. Where the backend has no field (e-KYC, REN) the screen says
/// so instead of inventing one.
class ProviderProfileMobilePage extends ConsumerStatefulWidget {
  const ProviderProfileMobilePage({super.key});

  @override
  ConsumerState<ProviderProfileMobilePage> createState() =>
      _ProviderProfileMobilePageState();
}

class _ProviderProfileMobilePageState
    extends ConsumerState<ProviderProfileMobilePage> {
  Future<Map<String, dynamic>>? _me;
  Future<ProviderWorkspace>? _workspace;
  Future<ProviderVerification>? _verification;

  /// The agent's own profile row and assigned listings
  /// (`GET /api/v1/staff/me/listings`). Null future for owners.
  Future<AgentSelfOverview?>? _agent;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final role = ref.read(authNotifierProvider).user?.role;
    final me = ProviderWorkspaceService.profile();
    final workspace = ProviderListingsService.load(role ?? AppRole.owner);
    final verification = ProviderWorkspaceService.verification();
    final agent = role == AppRole.agent ? _loadAgentSelf() : null;
    if (!mounted) return;
    setState(() {
      _me = me;
      _workspace = workspace;
      _verification = verification;
      _agent = agent;
    });
    // Every request is already in flight. Waiting for each keeps the
    // swipe-down indicator up until the whole profile is current.
    await Future.wait([
      settleRefresh(me),
      settleRefresh(workspace),
      settleRefresh(verification),
      if (agent != null) settleRefresh(agent),
    ]);
  }

  /// The authenticated agent's profile row plus their authorized
  /// assignments. Any failure (transport, MFA gate) resolves to null and
  /// the sections report that they could not be read.
  Future<AgentSelfOverview?> _loadAgentSelf() async {
    try {
      final self = await ServiceLocator.agentListings.selfOverview();
      return AgentSelfOverview(profile: self.agent, assignments: self.listings);
    } catch (_) {
      return null;
    }
  }

  Future<void> _signOut() async {
    await ref.read(authNotifierProvider.notifier).signOut();

    if (!mounted) return;

    Navigator.of(
      context,
      rootNavigator: true,
    ).pushNamedAndRemoveUntil('/auth', (route) => false);
  }

  /// Opens a drill-in and reloads on return: the verification screen can
  /// change the status this page summarises, and the authenticator screen
  /// changes the assurance level.
  Future<void> _open(String route) async {
    final scope = ProviderTabScope.maybeOf(context);
    if (scope != null && scope.handlesRoute(route)) {
      // "My listings" is now a tab command: no second shell, no profile reload.
      scope.go(route);
      return;
    }
    await Navigator.of(context).pushNamed(route);
    if (mounted) _load();
  }

  Future<void> _editProfile(Map<String, dynamic>? me) async {
    final updated = await ProviderProfileEditSheet.show(
      context,
      currentName: _displayName(me),
      currentPhone: '${me?['phone_number'] ?? ''}'.trim(),
    );
    if (updated && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('Profile updated.'),
        ),
      );
      _load();
    }
  }

  /// The hero identity prefers the freshly-read `/auth/me` payload and falls
  /// back to the session user while that request is in flight.
  String _displayName(Map<String, dynamic>? me) {
    final fromServer = '${me?['full_name'] ?? ''}'.trim();
    if (fromServer.isNotEmpty) return fromServer;
    return ref.read(authNotifierProvider).user?.name ?? 'Not available';
  }

  void _soon(String what) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text('$what will be available soon.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authNotifierProvider).user;
    final isAgent = user?.role == AppRole.agent;
    return RefreshIndicator(
      color: SitewiseColors.action,
      onRefresh: _load,
      child: providerContent(
        children: isAgent ? _agentBody(user) : _ownerBody(user),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Property Owner layout
  // ---------------------------------------------------------------------------

  List<Widget> _ownerBody(SitewiseUser? user) => [
    M3ScreenHeading(
      eyebrow: 'Account & profile',
      title: 'Your profile.',
      lead: 'Your details, property records and verification.',
    ),
    const SizedBox(height: 18),
    _ProfileHero(
      user: user,
      me: _me,
      roleChipLabel: user?.role.label ?? 'Property Owner',
      statValueBuilder: _ownerStats,
      onEdit: () => _editProfileFuture(),
    ),
    const SizedBox(height: 8),
    _SectionHead(title: 'Account overview', hint: 'Your account'),
    _SummaryCard(
      rows: [
        _SummaryRow('Account type', user?.role.label ?? 'Property Owner'),
        FutureBuilder<Map<String, dynamic>>(
          future: _me,
          builder: (context, snapshot) {
            return _SummaryRow(
              'Email verification',
              null,
              badge: _emailVerifiedBadge(snapshot.data),
            );
          },
        ),
        FutureBuilder<Map<String, dynamic>>(
          future: _me,
          builder: (context, snapshot) {
            final status = snapshot.data?['account_status']?.toString();
            return _SummaryRow(
              'Account status',
              (status == null || status.isEmpty) ? 'Unavailable' : status,
            );
          },
        ),
      ],
    ),
    const _IdentityVerificationCard(),
    const SizedBox(height: 8),
    FutureBuilder<ProviderVerification>(
      future: _verification,
      builder: (context, snapshot) {
        return _AccountVerificationCard(
          verification: snapshot.data,
          loading: snapshot.connectionState == ConnectionState.waiting,
          error: snapshot.error,
          onOpen: () => _open('/provider/verification'),
        );
      },
    ),
    const SizedBox(height: 8),
    _SectionHead(title: 'My properties', hint: 'Listings & approvals'),
    _ActionList(
      rows: [
        _ActionRow(
          icon: Icons.storefront_outlined,
          title: 'My listings',
          subtitle: 'View and manage properties you have added',
          onTap: () => _open('/provider/listings'),
        ),
        _ActionRow(
          icon: Icons.description_outlined,
          title: 'Ownership documents',
          subtitle: 'Proof of ownership, reviewed for each listing',
          onTap: () => _open('/provider/listings'),
        ),
        _ActionRow(
          icon: Icons.fact_check_outlined,
          title: 'Review progress',
          subtitle: 'See which listings need action or approval',
          onTap: () => _open('/provider/listings'),
        ),
      ],
    ),
    const SizedBox(height: 8),
    _SectionHead(title: 'Account & settings', hint: 'Preferences'),
    _ActionList(
      rows: [
        _ActionRow(
          icon: Icons.lock_outline_rounded,
          title: 'Security & sign-in',
          subtitle: 'How you access your account',
          greyIcon: true,
          onTap: _openSecuritySheet,
        ),
        _ActionRow(
          icon: Icons.shield_outlined,
          title: 'Privacy & terms',
          subtitle: 'Your information and how it is used',
          greyIcon: true,
          onTap: () => _soon('Privacy & terms'),
        ),
      ],
    ),
    const SizedBox(height: 12),
    const _ProfileNote(
      'Identity, listing and verification statuses come from your SiteWise '
      'records. SiteWise does not verify identity documents yet.',
    ),
    _SignOutButton(onSignOut: _signOut),
  ];

  // ---------------------------------------------------------------------------
  // Agent layout
  // ---------------------------------------------------------------------------

  List<Widget> _agentBody(SitewiseUser? user) => [
    M3ScreenHeading(
      eyebrow: 'Your account',
      title: 'My profile.',
      lead: 'Your details, agency and authorizations.',
    ),
    const SizedBox(height: 18),
    _ProfileHero(
      user: user,
      me: _me,
      roleChipLabel: user?.role.label ?? 'Property Agent',
      statValueBuilder: _agentStats,
      onEdit: () => _editProfileFuture(),
    ),
    const SizedBox(height: 8),
    _SectionHead(title: 'Agent details', hint: 'Your credentials'),
    _AgentDetailsCard(verification: _verification, agent: _agent, me: _me),
    const SizedBox(height: 8),
    _SectionHead(title: 'Listing access', hint: 'Assignments'),
    _ActionList(
      rows: [
        FutureBuilder<AgentSelfOverview?>(
          future: _agent,
          builder: (context, snapshot) {
            final overview = snapshot.data;
            return _ActionRow(
              icon: Icons.assignment_outlined,
              title: 'Listing authorizations',
              subtitle: 'Owner permission for each listing',
              trailing: overview == null
                  ? null
                  : _StatusBadge(
                      '${overview.assignments.length} assigned',
                      tone: StatusTone.neutral,
                    ),
              onTap: _openAuthorizationsSheet,
            );
          },
        ),
      ],
    ),
    const _ProfileNote(
      'Authorization details come from your account records. Owner '
      'authorization is granted per listing, never for the account as a '
      'whole.',
    ),
    const SizedBox(height: 8),
    _SectionHead(title: 'Account & preferences', hint: 'Settings'),
    _ActionList(
      rows: [
        _ActionRow(
          icon: Icons.notifications_none_rounded,
          title: 'Notifications',
          subtitle: 'Review updates and messages',
          greyIcon: true,
          onTap: () => _soon('Notification settings'),
        ),
        _ActionRow(
          icon: Icons.shield_outlined,
          title: 'Privacy & terms',
          subtitle: 'How your account information is used',
          greyIcon: true,
          onTap: () => _soon('Privacy & terms'),
        ),
      ],
    ),
    const SizedBox(height: 12),
    _SignOutButton(onSignOut: _signOut),
  ];

  Future<void> _editProfileFuture() async {
    final me = await _me?.catchError((_) => <String, dynamic>{});
    if (!mounted) return;
    _editProfile(me);
  }

  // ---------------------------------------------------------------------------
  // Derived stats
  // ---------------------------------------------------------------------------

  /// The two hero stats for the OWNER layout: total listings and the count
  /// awaiting review. Both are arithmetic over the authorized listing rows —
  /// `—` while loading or when the read fails, never a fabricated zero.
  Widget _ownerStats(BuildContext context) {
    return FutureBuilder<ProviderWorkspace>(
      future: _workspace,
      builder: (context, snapshot) {
        final workspace = snapshot.data;
        return Row(
          children: [
            _Stat(
              value: workspace == null ? '—' : '${workspace.listings.length}',
              label: 'My properties',
            ),
            const _StatDivider(),
            _Stat(
              value: workspace == null
                  ? '—'
                  : '${workspace.count(ProviderStage.pending)}',
              label: 'Awaiting review',
            ),
          ],
        );
      },
    );
  }

  /// The two hero stats for the AGENT layout: the assigned listing count from
  /// the authorized staff endpoint, and the account verification state (the
  /// SAME verified record and wording the Agent details card shows).
  Widget _agentStats(BuildContext context) {
    return FutureBuilder<ProviderWorkspace>(
      future: _workspace,
      builder: (context, workspaceSnapshot) {
        final workspace = workspaceSnapshot.data;
        return FutureBuilder<ProviderVerification>(
          future: _verification,
          builder: (context, verificationSnapshot) {
            final verification = verificationSnapshot.data;
            final verificationLabel = verification == null
                ? '—'
                : _verificationPresentation(verification.status).$1;
            return Row(
              children: [
                _Stat(
                  value: workspace == null
                      ? '—'
                      : '${workspace.listings.length}',
                  label: 'Assigned listings',
                ),
                const _StatDivider(),
                _Stat(value: verificationLabel, label: 'Account verification'),
              ],
            );
          },
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Sheets
  // ---------------------------------------------------------------------------

  void _openSecuritySheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: SitewiseM3.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _SecuritySheet(
        me: _me,
        isAgent: ref.read(authNotifierProvider).user?.role == AppRole.agent,
        onOpenMfa: () {
          Navigator.of(context).pop();
          _open('/provider/mfa');
        },
      ),
    );
  }

  void _openAuthorizationsSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: SitewiseM3.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _AuthorizationsSheet(
        agent: _agent,
        onOpenListings: () {
          Navigator.of(context).pop();
          _open('/provider/listings');
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Badges
  // ---------------------------------------------------------------------------

  Widget? _emailVerifiedBadge(Map<String, dynamic>? me) {
    final verified = me?['email_verified'];
    if (me == null || verified == null) {
      return const _StatusBadge('Not loaded', tone: StatusTone.grey);
    }
    return verified == true
        ? const _StatusBadge('Verified', tone: StatusTone.green)
        : const _StatusBadge('Not verified', tone: StatusTone.amber);
  }
}

// ---------------------------------------------------------------------------
// Agent self overview (read model of GET /api/v1/staff/me/listings)
// ---------------------------------------------------------------------------

/// The authenticated agent's own profile row plus the listings the backend
/// authorizes them to manage. Both come from the one authorized call, mapped
/// by `ApiAgentListingRepository.selfOverview()`; nothing here is inferred from
/// the signup selection.
class AgentSelfOverview {
  const AgentSelfOverview({required this.profile, required this.assignments});

  /// The raw `agent` profile row: agent_id, agent_name, company_id — plus any
  /// other column the server returns. Fields the server does not send are
  /// reported as unavailable, never invented.
  final Map<String, dynamic>? profile;

  /// One row per assigned listing, already joined with the server-derived
  /// `management` block (who is authorized to manage it and why).
  final List<Map<String, dynamic>> assignments;

  String? get agentName {
    final name = '${profile?['agent_name'] ?? ''}'.trim();
    return name.isEmpty ? null : name;
  }

  String? get companyName {
    // `/staff/me/listings` returns the raw agent row; a company_name column
    // is only present when the server includes it. No client-side guess.
    final name = '${profile?['company_name'] ?? ''}'.trim();
    return name.isEmpty ? null : name;
  }
}

// ---------------------------------------------------------------------------
// Agent details (simplified read-only professional summary)
// ---------------------------------------------------------------------------

/// The verification wording shared by the Agent details card and the hero's
/// account-verification stat, so the two can never disagree.
(String, StatusTone) _verificationPresentation(String? status) =>
    switch (status) {
      'approved' => ('Verified', StatusTone.green),
      'pending' => ('Pending review', StatusTone.amber),
      'rejected' => ('Rejected', StatusTone.red),
      'unsubmitted' => ('Not submitted', StatusTone.neutral),
      _ => ('Status unavailable', StatusTone.grey),
    };

/// ISO timestamp -> `DD MMM YYYY` (e.g. `15 Nov 2026`); null when absent or
/// unparseable — never a fabricated date.
String? _formatJoinedDate(String? iso) {
  final trimmed = (iso ?? '').trim();
  if (trimmed.isEmpty) return null;
  final parsed = DateTime.tryParse(trimmed);
  if (parsed == null) return null;
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${parsed.day.toString().padLeft(2, '0')} '
      '${months[parsed.month - 1]} ${parsed.year}';
}

/// The read-only "Agent details" card: verification status, company/agency
/// and joined date, one row per verified record. Verification comes from the
/// account verification service, the agency from the authorized staff row and
/// the joined date from `/auth/me`'s account `created_at`. A value the
/// backend does not have renders "Not provided", never placeholder data —
/// and email verification is deliberately NOT echoed here: it is a separate,
/// unrelated signal shown once in the profile card.
class _AgentDetailsCard extends StatelessWidget {
  const _AgentDetailsCard({this.verification, this.agent, this.me});

  final Future<ProviderVerification>? verification;
  final Future<AgentSelfOverview?>? agent;
  final Future<Map<String, dynamic>>? me;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: SitewiseM3.surface,
        borderRadius: BorderRadius.circular(19),
        border: Border.all(color: SitewiseM3.line),
      ),
      child: Column(
        children: [
          FutureBuilder<ProviderVerification>(
            future: verification,
            builder: (context, snapshot) {
              final (
                String label,
                StatusTone tone,
              ) = snapshot.connectionState == ConnectionState.waiting
                  ? ('Loading', StatusTone.grey)
                  : switch (snapshot.data) {
                      null => (
                        isMfaRequired(snapshot.error ?? '')
                            ? 'Second factor required'
                            : 'Could not be read',
                        StatusTone.grey,
                      ),
                      final record => _verificationPresentation(record.status),
                    };
              return _SummaryRow(
                'Verification status',
                null,
                badge: _StatusBadge(label, tone: tone),
              );
            },
          ),
          const Divider(height: 1, color: Color(0xFFEDF1F6)),
          FutureBuilder<AgentSelfOverview?>(
            future: agent,
            builder: (context, snapshot) {
              final waiting =
                  snapshot.connectionState == ConnectionState.waiting;
              final company = snapshot.data?.companyName;
              final shown = company == null || company.isEmpty
                  ? 'Not provided'
                  : company;
              return _SummaryRow('Company / Agency', waiting ? '—' : shown);
            },
          ),
          const Divider(height: 1, color: Color(0xFFEDF1F6)),
          FutureBuilder<Map<String, dynamic>>(
            future: me,
            builder: (context, snapshot) {
              final waiting =
                  snapshot.connectionState == ConnectionState.waiting;
              final joined = _formatJoinedDate(
                snapshot.data?['created_at']?.toString(),
              );
              return _SummaryRow(
                'Joined date',
                waiting ? '—' : (joined ?? 'Not provided'),
              );
            },
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Hero
// ---------------------------------------------------------------------------

class _ProfileHero extends StatelessWidget {
  const _ProfileHero({
    required this.user,
    required this.me,
    required this.roleChipLabel,
    required this.statValueBuilder,
    required this.onEdit,
  });

  final SitewiseUser? user;

  /// The freshly-read `/auth/me` payload. The hero prefers the server values
  /// (so a successful edit is reflected immediately) and falls back to the
  /// session user while the request is in flight.
  final Future<Map<String, dynamic>>? me;
  final String roleChipLabel;
  final Widget Function(BuildContext) statValueBuilder;
  final VoidCallback onEdit;

  static String _initialsFrom(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'S';
    final parts = trimmed
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.length >= 2) {
      return (parts[0][0] + parts[1][0]).toUpperCase();
    }
    return trimmed[0].toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        color: SitewiseM3.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: SitewiseM3.line),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F153570),
            blurRadius: 26,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FutureBuilder<Map<String, dynamic>>(
                future: me,
                builder: (context, snapshot) {
                  final url = '${snapshot.data?['profile_picture_url'] ?? ''}'
                      .trim();
                  final serverName = '${snapshot.data?['full_name'] ?? ''}'
                      .trim();
                  final displayName = serverName.isNotEmpty
                      ? serverName
                      : (user?.name ?? '');
                  return _Avatar(
                    initials: _initialsFrom(displayName),
                    imageUrl: url,
                  );
                },
              ),
              const SizedBox(width: 13),
              Expanded(
                child: FutureBuilder<Map<String, dynamic>>(
                  future: me,
                  builder: (context, snapshot) {
                    final serverName = '${snapshot.data?['full_name'] ?? ''}'
                        .trim();
                    final serverEmail = '${snapshot.data?['email'] ?? ''}'
                        .trim();
                    final displayName = serverName.isNotEmpty
                        ? serverName
                        : (user?.name ?? 'Not available');
                    final email = serverEmail.isNotEmpty
                        ? serverEmail
                        : (user?.email ?? 'Not signed in');
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: kFontFamily,
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.4,
                            color: SitewiseM3.ink,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          email,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: kFontFamily,
                            fontSize: 12,
                            height: 1.35,
                            color: SitewiseM3.muted,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined, size: 15),
            label: const Text('Edit profile'),
            style: OutlinedButton.styleFrom(
              foregroundColor: SitewiseColors.action,
              minimumSize: const Size(0, 40),
              side: const BorderSide(color: Color(0xFFCFDCF8)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              textStyle: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 13),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              _RoleChip(roleChipLabel),
              FutureBuilder<Map<String, dynamic>>(
                future: me,
                builder: (context, snapshot) {
                  return _EmailChip(me: snapshot.data);
                },
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(height: 1, color: SitewiseM3.line),
          const SizedBox(height: 13),
          statValueBuilder(context),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.initials, required this.imageUrl});

  final String initials;
  final String imageUrl;

  @override
  Widget build(BuildContext context) {
    final hasImage = imageUrl.isNotEmpty;
    return Container(
      width: 62,
      height: 62,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFFE0EAFF),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFC8DAFD)),
      ),
      child: hasImage
          ? Image.network(
              imageUrl,
              width: 62,
              height: 62,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _InitialsText(initials: initials),
            )
          : _InitialsText(initials: initials),
    );
  }
}

class _InitialsText extends StatelessWidget {
  const _InitialsText({required this.initials});

  final String initials;

  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      initials,
      style: const TextStyle(
        fontFamily: kFontFamily,
        fontSize: 20,
        fontWeight: FontWeight.w800,
        color: SitewiseColors.action,
      ),
    ),
  );
}

class _RoleChip extends StatelessWidget {
  const _RoleChip(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: const Color(0xFFE5EEFF),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      label,
      style: const TextStyle(
        fontFamily: kFontFamily,
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
        color: Color(0xFF1B409C),
      ),
    ),
  );
}

/// The email chip is tri-state: verified / not verified / not loaded yet.
/// It never shows "Verified" unless `/auth/me` returned `email_verified`.
class _EmailChip extends StatelessWidget {
  const _EmailChip({required this.me});

  final Map<String, dynamic>? me;

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg, String label) = switch (me?['email_verified']) {
      true => (SitewiseM3.greenWash, SitewiseM3.green, 'Email verified'),
      false => (SitewiseM3.amberWash, SitewiseM3.amber, 'Email not verified'),
      _ => (
        const Color(0xFFF0F3F7),
        const Color(0xFF52617B),
        me == null ? 'Email status not loaded' : 'Email status unavailable',
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Stats
// ---------------------------------------------------------------------------

class _StatDivider extends StatelessWidget {
  const _StatDivider();

  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: 34,
    margin: const EdgeInsets.symmetric(horizontal: 12),
    color: SitewiseM3.line,
  );
}

/// One hero metric. [value] is a real count from the authorized endpoint, or
/// `—` when it is not (yet) known — never a fabricated zero.
class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: value.length <= 3 ? 22 : 14,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
            height: 1.1,
            color: SitewiseM3.ink,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            height: 1.3,
            color: SitewiseM3.muted,
          ),
        ),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Sections
// ---------------------------------------------------------------------------

class _SectionHead extends StatelessWidget {
  const _SectionHead({required this.title, required this.hint});

  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(2, 20, 2, 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: SitewiseM3.ink,
            ),
          ),
        ),
        Text(
          hint,
          style: const TextStyle(
            fontFamily: kFontFamily,
            fontSize: 11,
            color: SitewiseM3.muted,
          ),
        ),
      ],
    ),
  );
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.rows});

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    decoration: BoxDecoration(
      color: SitewiseM3.surface,
      borderRadius: BorderRadius.circular(19),
      border: Border.all(color: SitewiseM3.line),
    ),
    child: Column(children: rows),
  );
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow(this.label, this.value, {this.badge});

  final String label;
  final String? value;
  final Widget? badge;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12,
              color: SitewiseM3.muted,
            ),
          ),
        ),
        ?badge,
        if (value != null) ...[
          if (badge != null) const SizedBox(width: 8),
          Flexible(
            child: Text(
              value!,
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 12.2,
                fontWeight: FontWeight.w700,
                color: SitewiseM3.ink,
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

enum StatusTone { green, amber, red, neutral, grey }

class _StatusBadge extends StatelessWidget {
  const _StatusBadge(this.label, {required this.tone});

  final String label;
  final StatusTone tone;

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg) = switch (tone) {
      StatusTone.green => (SitewiseM3.greenWash, SitewiseM3.green),
      StatusTone.amber => (SitewiseM3.amberWash, SitewiseM3.amber),
      StatusTone.red => (SitewiseColors.dangerWash, SitewiseColors.danger),
      StatusTone.neutral => (const Color(0xFFE5EEFF), const Color(0xFF1B409C)),
      StatusTone.grey => (const Color(0xFFF1F4F9), const Color(0xFF576982)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: fg,
        ),
      ),
    );
  }
}

class _ActionList extends StatelessWidget {
  const _ActionList({required this.rows});

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) => Material(
    color: SitewiseM3.surface,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(19),
      side: const BorderSide(color: SitewiseM3.line),
    ),
    child: Column(
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const Divider(height: 1, color: Color(0xFFEDF1F6)),
          rows[i],
        ],
      ],
    ),
  );
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
    this.greyIcon = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? trailing;
  final bool greyIcon;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Container(
      constraints: const BoxConstraints(minHeight: 76),
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 43,
            height: 43,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: greyIcon
                  ? const Color(0xFFF1F4F8)
                  : const Color(0xFFEDF3FF),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(
              icon,
              size: 20,
              color: greyIcon ? const Color(0xFF45617D) : SitewiseColors.action,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 12.6,
                    fontWeight: FontWeight.w800,
                    color: SitewiseM3.ink,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 10.9,
                    height: 1.35,
                    color: SitewiseM3.muted,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
          const SizedBox(width: 6),
          const Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: Color(0xFF8D9BB0),
          ),
        ],
      ),
    ),
  );
}

class _ProfileNote extends StatelessWidget {
  const _ProfileNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
    child: Text(
      text,
      style: const TextStyle(
        fontFamily: kFontFamily,
        fontSize: 11,
        height: 1.55,
        color: SitewiseM3.muted,
      ),
    ),
  );
}

class _SignOutButton extends StatelessWidget {
  const _SignOutButton({required this.onSignOut});

  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: OutlinedButton.icon(
      onPressed: onSignOut,
      icon: const Icon(Icons.logout_rounded, size: 18),
      label: const Text('Sign out'),
      style: OutlinedButton.styleFrom(
        foregroundColor: SitewiseColors.danger,
        minimumSize: const Size.fromHeight(50),
        side: const BorderSide(color: Color(0xFFF0D7DE)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        textStyle: const TextStyle(
          fontFamily: kFontFamily,
          fontWeight: FontWeight.w800,
          fontSize: 13,
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Identity verification (owner) — honest about what the backend supports
// ---------------------------------------------------------------------------

class _IdentityVerificationCard extends StatefulWidget {
  const _IdentityVerificationCard();

  @override
  State<_IdentityVerificationCard> createState() =>
      _IdentityVerificationCardState();
}

class _IdentityVerificationCardState extends State<_IdentityVerificationCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(17),
        decoration: BoxDecoration(
          color: SitewiseM3.surface,
          borderRadius: BorderRadius.circular(21),
          border: Border.all(color: SitewiseM3.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 47,
                  height: 47,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFFEBF2FF),
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: const Icon(
                    Icons.badge_outlined,
                    size: 22,
                    color: SitewiseColors.action,
                  ),
                ),
                const SizedBox(width: 13),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Your identity check',
                        style: TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: SitewiseM3.ink,
                        ),
                      ),
                      SizedBox(height: 3),
                      Text(
                        'MyKad or passport, where supported',
                        style: TextStyle(
                          fontFamily: kFontFamily,
                          fontSize: 11,
                          color: SitewiseM3.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 30, color: Color(0xFFEEF1F6)),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Verification status',
                    style: TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 11.8,
                      color: SitewiseM3.muted,
                    ),
                  ),
                ),
                const _StatusBadge('Not confirmed', tone: StatusTone.amber),
              ],
            ),
            const SizedBox(height: 10),
            const Text(
              'Identity verification confirms who you are. Proof that you can '
              'list a property is reviewed separately for each listing.',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 11.5,
                height: 1.5,
                color: Color(0xFF60728A),
              ),
            ),
            TextButton(
              onPressed: () => setState(() => _expanded = !_expanded),
              style: TextButton.styleFrom(
                foregroundColor: SitewiseColors.action,
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 0),
                textStyle: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('What does this check cover?'),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 16,
                    ),
                  ),
                ],
              ),
            ),
            if (_expanded)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.only(top: 12),
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: Color(0xFFEAEFF7))),
                ),
                child: const Text(
                  'SiteWise does not verify identity documents (e-KYC) yet, '
                  'so no identity status can be shown here. Property '
                  'ownership is reviewed per listing through its own '
                  'verification workflow — see Review progress below. The '
                  'account verification below is a separate, '
                  'administrator-reviewed check of your provider account.',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 11.7,
                    height: 1.55,
                    color: Color(0xFF52647E),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Account verification (real backend state, both roles)
// ---------------------------------------------------------------------------

class _AccountVerificationCard extends StatelessWidget {
  const _AccountVerificationCard({
    required this.verification,
    required this.loading,
    required this.error,
    required this.onOpen,
  });

  final ProviderVerification? verification;
  final bool loading;
  final Object? error;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final (String status, StatusTone tone) = loading
        ? ('Loading', StatusTone.grey)
        : verification == null
        ? (
            isMfaRequired(error ?? '')
                ? 'Second factor required'
                : 'Could not be read',
            StatusTone.grey,
          )
        : switch (verification!.status) {
            'approved' => ('Verified', StatusTone.green),
            'pending' => ('Awaiting review', StatusTone.amber),
            'rejected' => ('Needs correction', StatusTone.red),
            _ => ('Not submitted', StatusTone.neutral),
          };
    final verification_ = verification;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        color: SitewiseM3.surface,
        borderRadius: BorderRadius.circular(21),
        border: Border.all(color: SitewiseM3.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 47,
                height: 47,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0xFFEBF2FF),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: const Icon(
                  Icons.verified_user_outlined,
                  size: 22,
                  color: SitewiseColors.action,
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Account verification',
                      style: TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: SitewiseM3.ink,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      verification_ == null
                          ? 'Your provider account with SiteWise'
                          : verification_.businessName.isEmpty
                          ? 'Your provider account with SiteWise'
                          : verification_.businessName,
                      style: const TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 11,
                        color: SitewiseM3.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const Divider(height: 30, color: Color(0xFFEEF1F6)),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Status',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 11.8,
                    color: SitewiseM3.muted,
                  ),
                ),
              ),
              _StatusBadge(status, tone: tone),
            ],
          ),
          if (verification_ != null &&
              verification_.decisionNote?.trim().isNotEmpty == true) ...[
            const SizedBox(height: 10),
            Text(
              verification_.decisionNote!.trim(),
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 11.5,
                height: 1.5,
                color: Color(0xFF60728A),
              ),
            ),
          ],
          const SizedBox(height: 6),
          const Text(
            'This verifies your provider account with SiteWise. It is '
            'separate from your identity and from each listing\'s own '
            'verification.',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 11,
              height: 1.5,
              color: SitewiseM3.muted,
            ),
          ),
          TextButton(
            onPressed: onOpen,
            style: TextButton.styleFrom(
              foregroundColor: SitewiseColors.action,
              minimumSize: const Size(0, 40),
              padding: const EdgeInsets.symmetric(horizontal: 0),
              textStyle: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  verification_?.canSubmit == true
                      ? 'Start verification'
                      : 'View verification',
                ),
                const Icon(Icons.chevron_right_rounded, size: 16),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sheets
// ---------------------------------------------------------------------------

class _SheetScaffold extends StatelessWidget {
  const _SheetScaffold({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: SitewiseM3.ink,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded, size: 20),
                style: IconButton.styleFrom(
                  backgroundColor: SitewiseM3.quiet,
                  foregroundColor: SitewiseM3.ink,
                  minimumSize: const Size(36, 36),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12,
              height: 1.5,
              color: SitewiseM3.muted,
            ),
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    ),
  );
}

class _SheetRow extends StatelessWidget {
  const _SheetRow(this.label, {this.value});

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 9),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 118,
          child: Text(
            label,
            style: const TextStyle(
              fontFamily: kFontFamily,
              fontSize: 12,
              color: SitewiseM3.muted,
            ),
          ),
        ),
        if (value != null)
          Expanded(
            child: Text(
              value!,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 12.3,
                fontWeight: FontWeight.w700,
                color: SitewiseM3.ink,
              ),
            ),
          ),
      ],
    ),
  );
}

/// Real sign-in security state: the server-verified assurance level and what
/// it means for this role. An agent whose session is not elevated gets the
/// authenticator CTA here too.
class _SecuritySheet extends StatelessWidget {
  const _SecuritySheet({
    required this.me,
    required this.isAgent,
    required this.onOpenMfa,
  });

  final Future<Map<String, dynamic>>? me;
  final bool isAgent;
  final VoidCallback onOpenMfa;

  @override
  Widget build(BuildContext context) {
    return _SheetScaffold(
      title: 'Security & sign-in',
      subtitle:
          'How you access your account, as reported by the authentication '
          'service.',
      child: FutureBuilder<Map<String, dynamic>>(
        future: me,
        builder: (context, snapshot) {
          final level = snapshot.data?['assurance_level']?.toString();
          final elevated = level == 'aal2';
          final (String assurance, String mfa) = level == null
              ? ('Unavailable', 'Unavailable')
              : elevated
              ? ('aal2 · second factor verified', 'Satisfied for this session')
              : isAgent
              ? (
                  '$level · second factor outstanding',
                  'Required before property management',
                )
              : ('$level · password only', 'Not required for your account');
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 15,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: SitewiseM3.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: SitewiseM3.line),
                ),
                child: Column(
                  children: [
                    _SheetRow('Assurance level', value: assurance),
                    _SheetRow('Second factor (MFA)', value: mfa),
                    _SheetRow(
                      'Password',
                      value: 'Managed by your sign-in provider',
                    ),
                  ],
                ),
              ),
              if (!elevated && isAgent && level != null) ...[
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: onOpenMfa,
                  icon: const Icon(Icons.shield_outlined, size: 18),
                  label: const Text('Set up or enter authenticator code'),
                  style: FilledButton.styleFrom(
                    backgroundColor: SitewiseColors.action,
                    foregroundColor: SitewiseM3.surface,
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(
                        SitewiseM3.radiusPill,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// The agent's agency details from the authorized staff record. Fields the
/// server does not expose (agency name, REN) are reported as unavailable.
class _AuthorizationsSheet extends StatelessWidget {
  const _AuthorizationsSheet({
    required this.agent,
    required this.onOpenListings,
  });

  final Future<AgentSelfOverview?>? agent;
  final VoidCallback onOpenListings;

  @override
  Widget build(BuildContext context) {
    return _SheetScaffold(
      title: 'Listing authorizations',
      subtitle:
          'Owner permission for each listing you manage, as derived by the '
          'server from the assignment records.',
      child: FutureBuilder<AgentSelfOverview?>(
        future: agent,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 22),
              child: Center(
                child: CircularProgressIndicator(color: SitewiseColors.action),
              ),
            );
          }
          final overview = snapshot.data;
          if (overview == null) {
            return Container(
              width: double.infinity,
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(
                color: SitewiseM3.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: SitewiseM3.line),
              ),
              child: const Text(
                'Your authorizations could not be read. They are readable '
                'only with a completed second factor.',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 12,
                  height: 1.5,
                  color: SitewiseM3.muted,
                ),
              ),
            );
          }
          if (overview.assignments.isEmpty) {
            return Container(
              width: double.infinity,
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(
                color: SitewiseM3.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: SitewiseM3.line),
              ),
              child: const Text(
                'No listings are assigned to you yet. When an administrator '
                'assigns a listing, its authorization appears here.',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 12,
                  height: 1.5,
                  color: SitewiseM3.muted,
                ),
              ),
            );
          }
          final rows = overview.assignments.take(12).toList();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 15,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: SitewiseM3.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: SitewiseM3.line),
                ),
                child: Column(
                  children: [
                    for (var i = 0; i < rows.length; i++) ...[
                      if (i > 0)
                        const Divider(height: 1, color: Color(0xFFEDF1F6)),
                      _AuthorizationTile(row: rows[i]),
                    ],
                  ],
                ),
              ),
              if (overview.assignments.length > rows.length)
                Padding(
                  padding: const EdgeInsets.only(top: 8, left: 4),
                  child: Text(
                    '${overview.assignments.length - rows.length} more in '
                    'your listings',
                    style: const TextStyle(
                      fontFamily: kFontFamily,
                      fontSize: 11,
                      color: SitewiseM3.muted,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: onOpenListings,
                style: OutlinedButton.styleFrom(
                  foregroundColor: SitewiseColors.action,
                  minimumSize: const Size.fromHeight(46),
                  side: const BorderSide(color: SitewiseColors.action),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
                  ),
                ),
                child: const Text('Open my listings'),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _AuthorizationTile extends StatelessWidget {
  const _AuthorizationTile({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final management = row['management'];
    final managementMap = management is Map<String, dynamic>
        ? management
        : null;
    final providerManagement = managementMap == null
        ? null
        : ProviderManagement.fromJson(managementMap);
    final title = '${row['property_title'] ?? row['title'] ?? ''}'.trim();
    final listingId = row['listing_id'];
    final display = title.isNotEmpty
        ? title
        : (listingId == null ? 'Listing' : 'Listing L-$listingId');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  display,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 12.3,
                    fontWeight: FontWeight.w700,
                    color: SitewiseM3.ink,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  providerManagement?.display ?? 'Authorization unavailable',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 10.8,
                    color: SitewiseM3.muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _StatusBadge(
            switch (providerManagement?.type) {
              'agent' => 'Authorized',
              'unresolved' => 'Unresolved',
              'platform' => 'SiteWise-managed',
              _ => 'Unavailable',
            },
            tone: switch (providerManagement?.type) {
              'agent' => StatusTone.green,
              'unresolved' => StatusTone.amber,
              _ => StatusTone.grey,
            },
          ),
        ],
      ),
    );
  }
}
