import 'package:flutter/material.dart';
import 'package:shared_logic/shared_logic.dart';

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
class StaffWorkspaceRequiredView extends StatelessWidget {
  const StaffWorkspaceRequiredView({
    super.key,
    required this.role,
    required this.auth,
    this.appState,
  });

  final AppRole? role;
  final AuthCubit auth;
  final AppCubit? appState;

  @override
  Widget build(BuildContext context) {
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
          SelectableText(
            MobileEndpoints.staffPortalHint,
            style: _linkStyle,
          ),
        ],
      ),
      actionLabel: 'Sign out',
      onAction: () => _leave(context),
      secondaryLabel: 'Try another account',
      onSecondary: () => _leave(context),
    );
  }

  Future<void> _leave(BuildContext context) async {
    await auth.signOut();
    if (!context.mounted) return;
    Navigator.of(
      context,
    ).pushNamedAndRemoveUntil('/auth', (_) => false);
  }
}

/// A profile the server recognises but will not let through — suspended, or
/// provisioned and still awaiting activation.
class AccountStatusView extends StatelessWidget {
  const AccountStatusView({
    super.key,
    required this.message,
    required this.auth,
  });

  final String? message;
  final AuthCubit auth;

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
class AuthUnavailableView extends StatelessWidget {
  const AuthUnavailableView({super.key, required this.auth, this.onRetry});

  final AuthCubit auth;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return _BlockingScaffold(
      icon: Icons.wifi_off_rounded,
      title: 'Cannot verify sign-in',
      body: Text(
        auth.state.message ??
            'Sitewise could not reach the sign-in service, so your account has '
            'not been checked. No data is available until it is.',
        style: _bodyStyle,
      ),
      actionLabel: 'Retry',
      onAction: onRetry ?? auth.retry,
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
