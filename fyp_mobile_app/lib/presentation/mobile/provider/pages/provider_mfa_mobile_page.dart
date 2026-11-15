import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../application/services/service_locator.dart';
import '../../../../core/routing/auth_route_guard.dart' show MfaEntryRequest;
import '../../auth/widgets/auth_field.dart';
import 'provider_ui.dart';

/// Authenticator (TOTP) step-up for an agent account.
///
/// Agents are staff: every staff route requires the signed token to carry
/// `aal2`, so a password-only session can sign in but cannot manage a single
/// listing. This screen is where that second factor is supplied — either by
/// enrolling an authenticator for the first time, or by answering a challenge
/// with an existing one.
///
/// It returns `true` when the session has been elevated, so the caller (the
/// provider workspace gate) reloads the very request that was refused. Nothing
/// is marked verified locally: the elevated session comes from the provider,
/// and the server still re-checks `aal2` on every call.
class ProviderMfaMobilePage extends ConsumerStatefulWidget {
  const ProviderMfaMobilePage({super.key, this.entry});

  /// Present when this screen is a step of SIGN-IN or session restoration.
  /// Null when a workspace page pushed it as a step-up gate, which still pops
  /// `true` so the refused request reloads.
  final MfaEntryRequest? entry;

  @override
  ConsumerState<ProviderMfaMobilePage> createState() =>
      _ProviderMfaMobilePageState();
}

enum _Phase { checking, challenge, enrolling, unreachable }

class _ProviderMfaMobilePageState extends ConsumerState<ProviderMfaMobilePage> {
  final TextEditingController _code = TextEditingController();

  _Phase _phase = _Phase.checking;
  MfaState? _state;
  MfaEnrollment? _enrollment;
  MfaFactor? _target;
  String? _error;
  bool _busy = false;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _phase = _Phase.checking;
      _error = null;
    });
    try {
      final state = await ServiceLocator.staffMfa.state();
      if (!mounted) return;
      if (state.satisfied) {
        _finish();
        return;
      }
      setState(() => _state = state);
      if (state.canChallenge) {
        setState(() {
          _target = state.verifiedFactors.first;
          _phase = _Phase.challenge;
        });
      } else {
        await _startEnrollment();
      }
    } on AppFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _error = failure.userMessage;
        _phase = _Phase.unreachable;
      });
    }
  }

  Future<void> _startEnrollment() async {
    setState(() {
      _phase = _Phase.enrolling;
      _error = null;
      _code.clear();
    });
    try {
      // An enrolment that was started and never confirmed cannot be used to
      // sign in, but it still occupies one of the account's factor slots.
      // Clearing them first keeps the account's factor list meaningful.
      for (final stale in _state?.pendingFactors ?? const <MfaFactor>[]) {
        await ServiceLocator.staffMfa.discardEnrollment(stale.id);
      }
      final enrollment = await ServiceLocator.staffMfa.enroll(
        friendlyName: _deviceLabel(),
      );
      if (!mounted) return;
      setState(() {
        _enrollment = enrollment;
        _target = null;
      });
    } on AppFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _error = failure.userMessage;
        _phase = _Phase.unreachable;
      });
    }
  }

  /// A per-device label so two agents' phones (or one agent's two devices) are
  /// distinguishable in the account's factor list.
  String _deviceLabel() {
    String os;
    try {
      os = Platform.operatingSystem;
    } on Object {
      os = 'device';
    }
    final now = DateTime.now();
    final two = _twoDigits;
    return 'Mobile $os · ${two(now.day)}/${two(now.month)} '
        '${two(now.hour)}:${two(now.minute)}';
  }

  static String _twoDigits(int value) => value.toString().padLeft(2, '0');

  Future<void> _verify() async {
    final factorId = _enrollment?.factorId ?? _target?.id;
    if (factorId == null) return;
    final code = _code.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'Enter the six-digit code from your app.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_enrollment != null) {
        await ServiceLocator.staffMfa.verifyEnrollment(
          factorId: factorId,
          code: code,
        );
      } else {
        await ServiceLocator.staffMfa.challengeAndVerify(
          factorId: factorId,
          code: code,
        );
      }
      if (!mounted) return;
      _finish();
    } on MfaCodeRejectedFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = failure.userMessage;
        _code.clear();
      });
    } on MfaChallengeExpiredFailure catch (failure) {
      if (!mounted) return;
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
    }
  }

  void _finish() {
    if (_finished) return;
    _finished = true;
    final entry = widget.entry;
    if (entry != null) {
      // Sign-in / cold-start MFA: there is no workspace beneath this route to
      // pop back to. Open the dashboard (or the permitted deep link) and clear
      // the auth stack so Back cannot return to a stale login or half-finished
      // enrollment. No local flag grants access — Supabase has just issued the
      // elevated session and FastAPI re-checks aal2 on every staff call.
      Navigator.of(context).pushNamedAndRemoveUntil(
        entry.destination,
        (_) => false,
      );
      return;
    }
    Navigator.of(context).pop(true);
  }

  /// Leaving without confirming the enrolment would strand an unusable factor
  /// on the account, so it is discarded first.
  ///
  /// An ENTRY step (sign-in / cold start) cannot be backed out of into a
  /// half-authenticated workspace: staff routes require `aal2` server-side.
  /// Cancelling therefore signs the session out through the shared notifier
  /// and returns to Sign In. An in-workspace step-up keeps the old
  /// `pop(false)` behaviour so the calling page can show its own gate again.
  Future<void> _abandon() async {
    final pending = _enrollment;
    if (pending != null) {
      await ServiceLocator.staffMfa.discardEnrollment(pending.factorId);
    }
    if (!mounted) return;
    if (widget.entry == null) {
      Navigator.of(context).pop(false);
      return;
    }
    await ref.read(authNotifierProvider.notifier).signOut();
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil(
      '/auth',
      (_) => false,
      arguments: 'login',
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _finished,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _abandon();
      },
      child: Scaffold(
        backgroundColor: providerCanvas,
        appBar: ProviderPageAppBar(
          title: 'Two-factor authentication',
          eyebrow: 'ACCOUNT SECURITY',
          leading: IconButton(
            tooltip: widget.entry == null ? 'Cancel' : 'Sign out',
            icon: const Icon(Icons.close_rounded),
            onPressed: _abandon,
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
          children: switch (_phase) {
            _Phase.checking => const [
              Padding(
                padding: EdgeInsets.only(top: 60),
                child: Center(child: CircularProgressIndicator()),
              ),
            ],
            _Phase.unreachable => [
              ProviderMessage(
                icon: Icons.shield_outlined,
                title: 'The authenticator step could not continue',
                body:
                    _error ??
                    'SiteWise could not reach the authenticator service.',
                onRetry: _load,
              ),
            ],
            _Phase.challenge => _challengeChildren(),
            _Phase.enrolling => _enrollingChildren(),
          },
        ),
      ),
    );
  }

  // -------------------------------------------------------------- challenge

  List<Widget> _challengeChildren() {
    final factor = _target;
    return [
      ProviderMessage(
        icon: Icons.lock_outline_rounded,
        title: 'Confirm it is you',
        body:
            'Agent accounts require a second factor before anything in the '
            'property workspace is shown. Enter the current code from your '
            'authenticator app for ${factor?.displayName ?? 'your authenticator'}.',
      ),
      const SizedBox(height: 18),
      _codeField(),
      if (_error != null) _errorBanner(_error!),
      const SizedBox(height: 16),
      _primaryButton(label: 'Verify and continue', onPressed: _verify),
    ];
  }

  // -------------------------------------------------------------- enrolment

  List<Widget> _enrollingChildren() {
    final enrollment = _enrollment;
    if (enrollment == null) {
      return [
        ProviderMessage(
          icon: Icons.qr_code_2_rounded,
          title: 'Preparing your authenticator',
          body: 'Starting a new enrolment with SiteWise.',
          onRetry: _startEnrollment,
        ),
      ];
    }
    return [
      ProviderMessage(
        icon: Icons.qr_code_2_rounded,
        title: 'Set up your authenticator',
        body:
            'Scan the code with an authenticator app (Google Authenticator, '
            'Microsoft Authenticator, 1Password, …). It is issued by the '
            'authentication provider, not by SiteWise, and nothing here is '
            'stored on this device.',
      ),
      const SizedBox(height: 18),
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: providerBorder),
        ),
        child: Column(
          children: [
            // Rendered from the provider's own otpauth:// URI, so the code on
            // screen and the secret below are the same enrolment.
            Center(
              child: QrImageView(
                data: enrollment.uri,
                version: QrVersions.auto,
                size: 190,
                padding: EdgeInsets.zero,
                backgroundColor: Colors.white,
                errorCorrectionLevel: QrErrorCorrectLevel.M,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Cannot scan it? Enter this key by hand.',
              style: TextStyle(fontSize: 12.5, color: providerMuted),
            ),
            const SizedBox(height: 8),
            SelectableText(
              enrollment.groupedSecret,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.4,
                color: providerInk,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      const Text(
        'Then enter the six-digit code your app shows.',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: providerInk,
        ),
      ),
      const SizedBox(height: 10),
      _codeField(),
      if (_error != null) _errorBanner(_error!),
      const SizedBox(height: 16),
      _primaryButton(label: 'Confirm and continue', onPressed: _verify),
      const SizedBox(height: 8),
      TextButton(
        onPressed: _busy ? null : _abandon,
        child: Text(
          widget.entry == null ? 'Cancel setup' : 'Sign out instead',
        ),
      ),
    ];
  }

  // ----------------------------------------------------------------- pieces

  Widget _codeField() => AuthField(
    label: 'Authenticator code',
    hint: '123 456',
    icon: Icons.password_rounded,
    controller: _code,
    keyboardType: TextInputType.number,
    textInputAction: TextInputAction.done,
    onSubmitted: (_) => _verify(),
    required: true,
  );

  Widget _errorBanner(String message) => Container(
    margin: const EdgeInsets.only(top: 12),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFFFDECEC),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFFF3C2C2)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(
          Icons.error_outline_rounded,
          size: 18,
          color: Color(0xFF9B1C1C),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            message,
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.4,
              color: Color(0xFF9B1C1C),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _primaryButton({required String label, required VoidCallback onPressed}) =>
      FilledButton(
        onPressed: _busy ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: providerBrand,
          minimumSize: const Size.fromHeight(50),
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
            : Text(label),
      );
}
