import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/sitewise_theme.dart';
import '../../../shared/widgets/sitewise_inline_notice.dart';
import '../../shell/mobile_app_shell.dart';

/// Mobile entrepreneur profile: identity, business preferences and account
/// actions. Intentionally not an analytics surface.

class EntrepreneurProfileMobilePage extends ConsumerStatefulWidget {
  const EntrepreneurProfileMobilePage({super.key});

  @override
  ConsumerState<EntrepreneurProfileMobilePage> createState() =>
      _EntrepreneurProfileMobilePageState();
}

class _EntrepreneurProfileMobilePageState
    extends ConsumerState<EntrepreneurProfileMobilePage> {
  @override
  void initState() {
    super.initState();
    // The saved/comparison counts on this page are server-backed. Nothing used
    // to read the shortlist on mobile, so both counters were always 0 after a
    // restart even though the account had saved properties.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(appNotifierProvider.notifier).loadSaved();
    });
  }

  /// Signs out through the shared auth state so the session, the persisted
  /// tokens and every route guard see the same transition; the workspace is
  /// then torn down in one navigation rather than left underneath the auth
  /// screen.
  Future<void> _logOut(BuildContext context) async {
    await ref.read(authNotifierProvider.notifier).signOut();
    if (!context.mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/auth', (_) => false);
  }

  void _soon(BuildContext context, String what) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$what will be available soon.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Watched, not read from the locator: editing preferences now invalidates
    // the provider, so this tile repaints with the new business type/budget
    // instead of showing the values captured before the edit.
    final prefs = ref.watch(businessPreferencesProvider);
    final appState = ref.watch(appNotifierProvider);
    return MobileAppShell(
      title: 'Profile',
      currentRoute: '/entrepreneur/profile',
      body: RefreshIndicator(
        color: SitewiseColors.action,
        onRefresh: () =>
            ref.read(appNotifierProvider.notifier).loadSaved(),
        child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          // Only the verified profile is observed here; the identity card
          // must not repaint for auth messages it never renders.
          _IdentityCard(
            user: ref.watch(authNotifierProvider.select((s) => s.user)),
            saved: appState.saved.length,
            compared: appState.compared.length,
            countsKnown: appState.savedError == null,
          ),
          if (appState.savedError != null)
            SitewiseInlineNotice(
              message: appState.savedError!,
              busy: appState.savedLoading,
              onRetry: () => ref.read(appNotifierProvider.notifier).loadSaved(),
            ),
          const SizedBox(height: 20),
          _SectionLabel('Business'),
          const SizedBox(height: 8),
          _TileGroup(
            children: [
              _Tile(
                icon: Icons.tune,
                title: 'Business preferences',
                subtitle:
                    '${prefs.businessType} · up to RM${prefs.maxBudgetRm.toStringAsFixed(0)}',
                onTap: () => Navigator.of(
                  context,
                ).pushNamed('/entrepreneur/preferences'),
              ),
              _Tile(
                icon: Icons.bookmark_border_rounded,
                title: 'Saved properties',
                subtitle: appState.savedError == null
                    ? '${appState.saved.length} saved'
                    : 'Could not be loaded',
                onTap: () =>
                    Navigator.of(context).pushNamed('/entrepreneur/saved'),
              ),
              _Tile(
                icon: Icons.compare_arrows,
                title: 'Comparison shortlist',
                subtitle: '${appState.compared.length} of 3 selected',
                onTap: () =>
                    Navigator.of(context).pushNamed('/entrepreneur/compare'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _SectionLabel('Account'),
          const SizedBox(height: 8),
          _TileGroup(
            children: [
              _Tile(
                icon: Icons.notifications_none_rounded,
                title: 'Notification settings',
                onTap: () => _soon(context, 'Notification settings'),
              ),
              _Tile(
                icon: Icons.privacy_tip_outlined,
                title: 'Terms & Privacy',
                onTap: () => _soon(context, 'Terms & Privacy'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: () => _logOut(context),
            icon: const Icon(Icons.logout_rounded, size: 18),
            label: const Text('Log out'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 50),
              foregroundColor: SitewiseColors.danger,
              side: const BorderSide(color: SitewiseColors.border),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              textStyle: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13.5,
              ),
            ),
          ),
        ],
        ),
      ),
    );
  }
}

class _IdentityCard extends StatelessWidget {
  /// The backend-verified profile, or null while the session is still being
  /// resolved. Never a placeholder identity.
  final SitewiseUser? user;
  final int saved;
  final int compared;

  /// False when the shortlist read failed — the pills then show "—" instead of
  /// a zero that reads as "you have saved nothing".
  final bool countsKnown;

  const _IdentityCard({
    required this.user,
    required this.saved,
    required this.compared,
    this.countsKnown = true,
  });

  @override
  Widget build(BuildContext context) {
    final name = user?.name ?? 'Sitewise account';
    final initial = name.trim().isEmpty ? 'S' : name.trim()[0].toUpperCase();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: SitewiseColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: SitewiseColors.border),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 26,
            backgroundColor: SitewiseColors.geoWash,
            child: Text(
              initial,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: SitewiseColors.action,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: SitewiseColors.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  user?.email ?? 'Not signed in',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: SitewiseColors.muted,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  children: [
                    _Pill(user?.role.label ?? 'F&B Entrepreneur'),
                    _Pill(countsKnown ? '$saved saved' : '— saved'),
                    _Pill(countsKnown ? '$compared compared' : '— compared'),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  const _Pill(this.label);

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: SitewiseColors.geoWash,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      label,
      style: const TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
        color: SitewiseColors.accent,
      ),
    ),
  );
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: const TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w800,
      letterSpacing: 0.9,
      color: SitewiseColors.overline,
    ),
  );
}

class _TileGroup extends StatelessWidget {
  final List<Widget> children;
  const _TileGroup({required this.children});

  @override
  Widget build(BuildContext context) => Material(
    // Material, not a coloured Container: the tiles draw their own ink
    // splashes on the nearest Material ancestor, and a DecoratedBox here
    // would hide them entirely.
    color: SitewiseColors.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: const BorderSide(color: SitewiseColors.border),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(children: children),
  );
}

class _Tile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  const _Tile({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => ListTile(
    onTap: onTap,
    leading: Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: SitewiseColors.geoWash,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Icon(icon, size: 19, color: SitewiseColors.action),
    ),
    title: Text(
      title,
      style: const TextStyle(
        fontSize: 13.5,
        fontWeight: FontWeight.w700,
        color: SitewiseColors.ink,
      ),
    ),
    subtitle: subtitle == null
        ? null
        : Text(
            subtitle!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5),
          ),
    trailing: const Icon(
      Icons.chevron_right_rounded,
      size: 20,
      color: SitewiseColors.overline,
    ),
  );
}
