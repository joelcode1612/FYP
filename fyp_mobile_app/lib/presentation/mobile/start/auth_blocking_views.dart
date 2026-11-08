import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../core/config/mobile_config.dart';
import '../../../core/config/mobile_endpoints.dart';
import '../../../core/theme/sitewise_theme.dart';
import '../../shared/widgets/sitewise_brand.dart';
import '../../shared/widgets/sitewise_cta_button.dart';

/// Screens a verified session can still be stopped at.
///
/// All three share one rule: they explain what happened, offer a way out, and
/// never paint the workspace behind them. The route guard renders them, so
/// they have to be readable on their own.

/// Admin and Agent accounts. Their workspaces exist only on the Staff Web
/// Portal; signing in on mobile must not silently fold them into the
/// Entrepreneur app, and their MFA requirement is not bypassed here.
class StaffWorkspaceRequiredView extends ConsumerWidget {
  const StaffWorkspaceRequiredView({super.key, required this.role});

  final AppRole? role;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final label = role?.label ?? 'This';
    return _BlockingScaffold(
      icon: Icons.desktop_mac_outlined,
      title: '$label workspace is web-only',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Sign in there with the same email address. Staff workspaces also '
            'require multi-factor authentication, which mobile does not offer '
            'yet — your account keeps its real role either way.',
            style: _bodyStyle,
          ),
          const SizedBox(height: 10),
          SelectableText(MobileEndpoints.staffPortalHint, style: _linkStyle),
        ],
      ),
      actionLabel: 'Sign out',
      onAction: () => _leave(context, ref),
      secondaryLabel: 'Try another account',
      onSecondary: () => _leave(context, ref),
    );
  }

  Future<void> _leave(BuildContext context, WidgetRef ref) async {
    await ref.read(authNotifierProvider.notifier).signOut();
    if (!context.mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/auth', (_) => false);
  }
}

/// A profile the server recognises but will not let through — suspended, or
/// provisioned and still awaiting activation.
class AccountStatusView extends StatelessWidget {
  const AccountStatusView({super.key, required this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return _BlockingScaffold(
      icon: Icons.lock_clock,
      title: 'Account not active',
      body: Text(
        message ??
            'This account cannot be used on Sitewise yet. Contact support to '
                'have it activated.',
        style: _bodyStyle,
      ),
      actionLabel: 'Back to sign in',
      onAction: () {
        Navigator.of(
          context,
        ).pushNamedAndRemoveUntil('/auth', (route) => false);
      },
    );
  }
}

/// Authentication could not be verified — offline, server error, or a build
/// with no credentials configured. Access stays withheld until the check
/// succeeds, so Retry is the action that matters.
class AuthUnavailableView extends ConsumerWidget {
  const AuthUnavailableView({super.key, this.onRetry});

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final message = ref.watch(authNotifierProvider).message;
    return _BlockingScaffold(
      icon: Icons.wifi_off_rounded,
      title: 'Cannot verify sign-in',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message ??
                'Sitewise could not reach the sign-in service, so your account '
                    'has not been checked. No data is available until it is.',
            style: _bodyStyle,
          ),
          // A missing compile-time define must be obvious rather than looking
          // like a server outage. Only key-free diagnostics are shown.
          if (!MobileConfig.supabaseReady) ...[
            const SizedBox(height: 16),
            _ConfigStatus(),
          ],
        ],
      ),
      actionLabel: 'Retry',
      onAction: onRetry ?? ref.read(authNotifierProvider.notifier).retry,
      secondaryLabel: 'Sign in again',
      onSecondary: () {
        Navigator.of(
          context,
        ).pushNamedAndRemoveUntil('/auth', (route) => false);
      },
    );
  }
}

/// Shared chrome for the three blocking screens.
class _BlockingScaffold extends StatelessWidget {
  const _BlockingScaffold({
    required this.icon,
    required this.title,
    required this.body,
    required this.actionLabel,
    required this.onAction,
    this.secondaryLabel,
    this.onSecondary,
  });

  final IconData icon;
  final String title;
  final Widget body;
  final String actionLabel;
  final VoidCallback onAction;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SitewiseColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 26, 22, 26),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SitewiseBrand(),
              const SizedBox(height: 42),
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: SitewiseColors.geoWash,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, color: SitewiseColors.action, size: 26),
              ),
              const SizedBox(height: 18),
              Text(
                title,
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: SitewiseColors.ink,
                  letterSpacing: -.6,
                ),
              ),
              const SizedBox(height: 12),
              body,
              const SizedBox(height: 28),
              SitewiseCtaButton(label: actionLabel, onPressed: onAction),
              if (secondaryLabel != null) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: onSecondary,
                    child: Text(
                      secondaryLabel!,
                      style: const TextStyle(
                        color: SitewiseColors.action,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Key-free summary of this build's compile-time configuration, shown only on
/// the "cannot verify sign-in" screen. Never contains key material.
class _ConfigStatus extends StatelessWidget {
  const _ConfigStatus();

  @override
  Widget build(BuildContext context) {
    final problems = MobileConfig.problems;
    return Semantics(
      container: true,
      label: 'Build configuration status',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: SitewiseColors.warningWash,
          borderRadius: BorderRadius.circular(SitewiseSpacing.radiusLg),
          border: Border.all(color: SitewiseColors.borderStrong),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Build configuration status',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: SitewiseColors.ink,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Supabase credentials: '
              '${MobileConfig.hasSupabaseCredentials ? 'present' : 'missing'}\n'
              'Supabase initialised: '
              '${MobileConfig.supabaseInitialized ? 'yes' : 'no'}\n'
              'API host: ${MobileConfig.apiHost}\n'
              'Supabase host: ${MobileConfig.supabaseHost}',
              style: const TextStyle(
                fontSize: 12,
                height: 1.55,
                color: SitewiseColors.text,
              ),
            ),
            if (problems.isNotEmpty) ...[
              const SizedBox(height: 9),
              for (final problem in problems)
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Text(
                    '• $problem',
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.45,
                      color: SitewiseColors.ink,
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 9),
            const Text(
              'Run with --dart-define-from-file=fyp_mobile_app/config/'
              'sitewise_dev.env (see sitewise_dev.env.example).',
              style: TextStyle(
                fontSize: 11.5,
                height: 1.45,
                color: SitewiseColors.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

const TextStyle _bodyStyle = TextStyle(
  fontSize: 14,
  height: 1.55,
  color: SitewiseColors.muted,
);

const TextStyle _linkStyle = TextStyle(
  fontSize: 13,
  fontWeight: FontWeight.w700,
  color: SitewiseColors.action,
);
