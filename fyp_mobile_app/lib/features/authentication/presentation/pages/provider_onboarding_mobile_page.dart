import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:fyp/core/routing/auth_route_guard.dart' show MfaEntryRequest;
import 'package:fyp/core/routing/mobile_role.dart' show providerOnboardingRoute;
import 'package:fyp/core/theme/sitewise_m3.dart';
import 'package:fyp/core/theme/sitewise_theme.dart';
import 'package:fyp/shared/presentation/components/provider_ui.dart';

class ProviderOnboardingMobilePage extends ConsumerStatefulWidget {
  const ProviderOnboardingMobilePage({super.key});

  @override
  ConsumerState<ProviderOnboardingMobilePage> createState() =>
      _ProviderOnboardingMobilePageState();
}

class _ProviderOnboardingMobilePageState
    extends ConsumerState<ProviderOnboardingMobilePage> {
  bool _busy = false;
  bool _leaving = false;
  String? _error;

  Future<void> _complete() async {
    if (_busy || _leaving) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(staffOnboardingServiceProvider).complete();
      if (!mounted) return;
      final active = await ref
          .read(authNotifierProvider.notifier)
          .refreshActiveSessionAfterStaffOnboarding();
      if (!mounted) return;
      if (!active) {
        setState(() {
          _busy = false;
          _error =
              'SiteWise has not confirmed an active workspace profile yet. '
              'Your setup was received; check again in a moment.';
        });
        return;
      }
      final user = ref.read(authNotifierProvider).user;
      if (user == null || !user.isActiveProfile) {
        setState(() {
          _busy = false;
          _error =
              'SiteWise could not verify the activated account. '
              'Please check again.';
        });
        return;
      }
      _leaving = true;
      ref.read(appNotifierProvider.notifier).setRole(user.role);
      Navigator.of(context).pushNamedAndRemoveUntil('/provider', (_) => false);
    } on StaffOnboardingFailure catch (failure) {
      if (!mounted) return;
      if (failure.backendCode == 'staff_mfa_required') {
        setState(() => _busy = false);
        Navigator.of(context).pushNamedAndRemoveUntil(
          '/provider/mfa',
          (_) => false,
          arguments: const MfaEntryRequest(
            destination: providerOnboardingRoute,
          ),
        );
        return;
      }
      setState(() {
        _busy = false;
        _error = failure.userMessage;
      });
    } on AppFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = failure.userMessage;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'SiteWise could not finish onboarding. Please try again.';
      });
    }
  }

  Future<void> _signOut() async {
    if (_busy || _leaving) return;
    setState(() => _leaving = true);
    await ref.read(authNotifierProvider.notifier).signOut();
    if (!mounted) return;
    Navigator.of(
      context,
    ).pushNamedAndRemoveUntil('/auth', (_) => false, arguments: 'login');
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authNotifierProvider);
    final user = auth.user;
    if (user == null || !user.isPendingProvider) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final owner = user.role == AppRole.owner;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _signOut();
      },
      child: Scaffold(
        backgroundColor: providerCanvas,
        appBar: ProviderPageAppBar(
          title: 'Invitation onboarding',
          eyebrow: owner ? 'PROPERTY OWNER' : 'PROPERTY AGENT',
          leading: IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.close_rounded),
            onPressed: _busy ? null : _signOut,
          ),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            children: [
              Text(
                owner ? 'Finish your Owner setup' : 'Finish your Agent setup',
                style: const TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: providerInk,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Your administrator invitation is associated with this account. '
                'SiteWise will verify the confirmed email, invitation ownership '
                'and authenticator before activating the workspace.',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.55,
                  color: providerMuted,
                ),
              ),
              const SizedBox(height: 20),
              _accountCard(user),
              if (_error != null) ...[
                const SizedBox(height: 16),
                _errorCard(_error!),
              ],
              const SizedBox(height: 22),
              FilledButton(
                onPressed: _busy ? null : _complete,
                style: FilledButton.styleFrom(
                  backgroundColor: providerBrand,
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(SitewiseM3.radiusCard),
                  ),
                ),
                child: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(
                        _error == null
                            ? 'Activate my account'
                            : 'Check activation again',
                      ),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: _busy ? null : _signOut,
                child: const Text('Use a different account'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _accountCard(SitewiseUser user) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: providerSoft,
      borderRadius: BorderRadius.circular(SitewiseM3.radiusCard),
      border: Border.all(color: providerBorder),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.mark_email_read_outlined, color: providerBrand),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user.name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: providerInk,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    user.email,
                    style: const TextStyle(fontSize: 12, color: providerMuted),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: SitewiseM3.amberWash,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                'Pending',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  color: SitewiseM3.amber,
                ),
              ),
            ),
          ],
        ),
        const Divider(height: 26, color: providerBorder),
        _requirement(
          icon: Icons.mail_outline_rounded,
          title: 'Confirmed email',
          body: 'Checked from the identity provider when you finish.',
        ),
        _requirement(
          icon: Icons.verified_user_outlined,
          title: 'Authenticator verification',
          body: user.hasStaffAssurance
              ? 'Confirmed by the server for this session.'
              : 'Complete the authenticator step before activation.',
        ),
        _requirement(
          icon: Icons.badge_outlined,
          title: user.role.label,
          body: user.role == AppRole.owner
              ? 'Assigned by your administrator; this setup never changes '
                    'your role or creates an Agent profile.'
              : 'Assigned by your administrator; this setup never changes '
                    'your role.',
        ),
      ],
    ),
  );

  Widget _requirement({
    required IconData icon,
    required String title,
    required String body,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 19, color: providerBrand),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: providerInk,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                body,
                style: const TextStyle(
                  fontSize: 11.5,
                  height: 1.4,
                  color: providerMuted,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _errorCard(String message) => Container(
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: SitewiseColors.dangerWash,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: SitewiseColors.danger.withValues(alpha: .35)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(
          Icons.error_outline_rounded,
          size: 18,
          color: SitewiseColors.danger,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            message,
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.4,
              color: SitewiseColors.danger,
            ),
          ),
        ),
      ],
    ),
  );
}
