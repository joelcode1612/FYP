import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../application/services/service_locator.dart';
import '../../../../core/routing/auth_route_guard.dart' show MfaEntryRequest;
import '../../../../core/theme/sitewise_m3.dart';
import '../../../../core/theme/sitewise_theme.dart';
import 'provider_ui.dart';

/// Authenticator (TOTP) step-up for staff accounts (Agent, and a Property
/// Owner routed here by the auth policy).
///
/// Staff routes require the signed token to carry `aal2`, so a password-only
/// session can sign in but cannot manage a single listing. This screen is
/// where that second factor is supplied — either by enrolling an authenticator
/// for the first time (Set up → Verify → Complete), or by answering a
/// challenge with an existing one.
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

enum _Phase {
  checking,
  challenge,
  enrollSetup,
  enrollVerify,
  complete,
  unreachable,
}

class _ProviderMfaMobilePageState extends ConsumerState<ProviderMfaMobilePage> {
  final TextEditingController _code = TextEditingController();

  _Phase _phase = _Phase.checking;
  MfaState? _state;
  MfaEnrollment? _enrollment;
  MfaFactor? _target;
  String? _error;
  bool _busy = false;
  bool _finished = false;
  bool _manualKeyOpen = false;

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
      _phase = _Phase.enrollSetup;
      _error = null;
      _code.clear();
      _manualKeyOpen = false;
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

  /// A per-device label so two phones (or one person's two devices) are
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
    if (code.length < 6) {
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
      setState(() {
        _busy = false;
        _phase = _Phase.complete;
      });
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

  Future<void> _copySetupKey() async {
    final enrollment = _enrollment;
    if (enrollment == null) return;
    await Clipboard.setData(ClipboardData(text: enrollment.secret));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('Setup key copied to the clipboard.'),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // Completion has been confirmed by the provider: Back leaves through
        // the same hand-off as the primary button. Any earlier phase cancels
        // (discarding a pending enrolment / signing out an entry step).
        if (_phase == _Phase.complete) {
          _finish();
        } else {
          _abandon();
        }
      },
      child: Scaffold(
        backgroundColor: providerCanvas,
        appBar: ProviderPageAppBar(
          title: switch (_phase) {
            _Phase.enrollSetup => 'Set up two-factor authentication',
            _Phase.complete => 'Verification complete',
            _ => 'Verify your authenticator code',
          },
          eyebrow: 'ACCOUNT SECURITY',
          leading: IconButton(
            tooltip: widget.entry == null ? 'Cancel' : 'Sign out',
            icon: const Icon(Icons.close_rounded),
            onPressed: _phase == _Phase.complete ? _finish : _abandon,
          ),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
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
              _Phase.challenge => _verifyChildren(
                headline: 'Verify your authenticator code',
                description: 'Enter the six-digit code from your '
                    'authenticator app.',
                stepper: const _MfaStepper(current: 2),
                factorName: _target?.displayName,
              ),
              _Phase.enrollSetup => _enrollSetupChildren(),
              _Phase.enrollVerify => _verifyChildren(
                headline: 'Verify your authenticator code',
                description: 'Enter the six-digit code from your '
                    'authenticator app.',
                stepper: const _MfaStepper(current: 2),
                factorName: null,
                showBack: true,
              ),
              _Phase.complete => _completeChildren(),
            },
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ enrolment UI

  List<Widget> _enrollSetupChildren() {
    final enrollment = _enrollment;
    if (enrollment == null) {
      return [
        const _MfaStepper(current: 1),
        const SizedBox(height: 18),
        _headline(
          'Set up two-factor authentication',
          'Protect your SiteWise account with an additional verification '
              'step.',
        ),
        const SizedBox(height: 18),
        ProviderMessage(
          icon: Icons.qr_code_2_rounded,
          title: 'Preparing your authenticator',
          body: 'Starting a new enrolment with SiteWise.',
          onRetry: _startEnrollment,
        ),
      ];
    }
    return [
      const _MfaStepper(current: 1),
      const SizedBox(height: 18),
      _headline(
        'Set up two-factor authentication',
        'Protect your SiteWise account with an additional verification step.',
      ),
      const SizedBox(height: 18),
      _panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _panelHeading(
              icon: Icons.qr_code_2_rounded,
              title: '1. Scan the QR code',
              body: 'Open an authenticator app (e.g. Google Authenticator or '
                  'Microsoft Authenticator) and scan the code below.',
            ),
            const SizedBox(height: 16),
            Center(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: providerBorder),
                ),
                // Rendered from the provider's own otpauth:// URI, so the code
                // on screen and the manual key below are the same enrolment.
                child: QrImageView(
                  data: enrollment.uri,
                  version: QrVersions.auto,
                  size: 180,
                  padding: EdgeInsets.zero,
                  backgroundColor: Colors.white,
                  errorCorrectionLevel: QrErrorCorrectLevel.M,
                ),
              ),
            ),
            const SizedBox(height: 14),
            const _OrDivider(),
            const SizedBox(height: 14),
            _ManualKeyCard(
              open: _manualKeyOpen,
              secret: enrollment.groupedSecret,
              onToggle: () => setState(() => _manualKeyOpen = !_manualKeyOpen),
              onCopy: _copySetupKey,
            ),
            const SizedBox(height: 12),
            Text(
              'Issued by the authentication provider — the key is never '
              'stored on this device.',
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 11,
                height: 1.4,
                color: providerMuted,
              ),
            ),
          ],
        ),
      ),
      if (_error != null) _errorBanner(_error!),
      const SizedBox(height: 20),
      _primaryButton(
        label: "I've added the account",
        icon: Icons.arrow_forward_rounded,
        onPressed: () => setState(() {
          _phase = _Phase.enrollVerify;
          _error = null;
          _code.clear();
        }),
      ),
    ];
  }

  // -------------------------------------------------------------- verify UI

  List<Widget> _verifyChildren({
    required String headline,
    required String description,
    required Widget stepper,
    required String? factorName,
    bool showBack = false,
  }) {
    return [
      stepper,
      const SizedBox(height: 18),
      _headline(headline, description),
      const SizedBox(height: 18),
      _panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _panelHeading(
              icon: Icons.verified_user_outlined,
              title: 'Enter 6-digit code',
              body: factorName == null
                  ? 'Open your authenticator app and enter the current '
                      '6-digit code.'
                  : 'Open your authenticator app and enter the current '
                      '6-digit code for $factorName.',
            ),
            const SizedBox(height: 16),
            _SixDigitField(
              controller: _code,
              enabled: !_busy,
              onChanged: (_) => setState(() {}),
              onSubmit: (_) => _verify(),
            ),
          ],
        ),
      ),
      if (_error != null) _errorBanner(_error!),
      const SizedBox(height: 14),
      _CodeTipsCard(),
      const SizedBox(height: 20),
      _primaryButton(
        label: 'Verify and complete',
        icon: Icons.shield_outlined,
        onPressed: _verify,
      ),
      if (showBack)
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                    _phase = _Phase.enrollSetup;
                    _error = null;
                  }),
          child: const Text('Back to previous step'),
        ),
    ];
  }

  // ----------------------------------------------------------- completion UI

  List<Widget> _completeChildren() => [
    const _MfaStepper(current: 3),
    const SizedBox(height: 34),
    Center(
      child: Container(
        width: 76,
        height: 76,
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          color: SitewiseM3.greenWash,
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.check_rounded, size: 40, color: SitewiseM3.green),
      ),
    ),
    const SizedBox(height: 20),
    Center(
      child: Text(
        'Verification complete',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: 20,
          fontWeight: FontWeight.w800,
          color: providerInk,
        ),
      ),
    ),
    const SizedBox(height: 10),
    Center(
      child: Text(
        widget.entry == null
            ? 'This session now carries your second factor. You can return '
                'to the workspace.'
            : 'Your authenticator is confirmed and this session is verified. '
                'Continuing opens your workspace.',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: 12.5,
          height: 1.55,
          color: providerMuted,
        ),
      ),
    ),
    const SizedBox(height: 28),
    _primaryButton(
      label: 'Continue to SiteWise',
      icon: Icons.arrow_forward_rounded,
      onPressed: _finish,
    ),
  ];

  // ----------------------------------------------------------------- pieces

  Widget _headline(String title, String description) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: 20,
          height: 1.2,
          fontWeight: FontWeight.w800,
          color: providerInk,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        description,
        style: TextStyle(
          fontFamily: kFontFamily,
          fontSize: 12.5,
          height: 1.5,
          color: providerMuted,
        ),
      ),
    ],
  );

  Widget _panel({required Widget child}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: providerSoft,
      borderRadius: BorderRadius.circular(SitewiseM3.radiusCard),
      border: Border.all(color: providerBorder),
    ),
    child: child,
  );

  Widget _panelHeading({
    required IconData icon,
    required String title,
    required String body,
  }) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: providerWash,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, size: 21, color: providerBrand),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 14.5,
                fontWeight: FontWeight.w800,
                color: providerInk,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              body,
              style: TextStyle(
                fontFamily: kFontFamily,
                fontSize: 11.5,
                height: 1.45,
                color: providerMuted,
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _errorBanner(String message) => Container(
    margin: const EdgeInsets.only(top: 14),
    padding: const EdgeInsets.all(12),
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

  Widget _primaryButton({
    required String label,
    required VoidCallback onPressed,
    IconData? icon,
  }) => FilledButton(
    onPressed: _busy ? null : onPressed,
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
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: Text(label)),
              if (icon != null) ...[
                const SizedBox(width: 8),
                Icon(icon, size: 18),
              ],
            ],
          ),
  );
}

/// Three-stage progress indicator: Set up → Verify → Complete.
///
/// Steps before [current] render as checked, the current one is filled brand
/// blue, later ones are quiet outlines. Exposed to screen readers as
/// "step N of 3" with the step names.
class _MfaStepper extends StatelessWidget {
  const _MfaStepper({required this.current});

  final int current;

  static const _labels = ['Set up', 'Verify', 'Complete'];

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Progress: step $current of 3 — ${_labels[current - 1]}',
      child: Row(
        children: [
          for (var i = 0; i < 3; i++) ...[
            if (i > 0)
              Expanded(
                child: Container(
                  height: 2,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  color: i < current ? providerBrand : providerBorder,
                ),
              ),
            _step(i),
          ],
        ],
      ),
    );
  }

  Widget _step(int index) {
    final step = index + 1;
    final done = step < current;
    final active = step == current;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: done || active ? providerBrand : Colors.white,
            shape: BoxShape.circle,
            border: Border.all(
              color: done || active ? providerBrand : providerBorder,
              width: active ? 2 : 1.4,
            ),
          ),
          child: done
              ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
              : Text(
                  '$step',
                  style: TextStyle(
                    fontFamily: kFontFamily,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: active ? Colors.white : providerMuted,
                  ),
                ),
        ),
        const SizedBox(height: 5),
        Text(
          _labels[index],
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 10.5,
            fontWeight: active ? FontWeight.w800 : FontWeight.w600,
            color: active ? providerBrand : providerMuted,
          ),
        ),
      ],
    );
  }
}

/// The white "or" divider between the QR code and the manual key row.
class _OrDivider extends StatelessWidget {
  const _OrDivider();

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const Expanded(child: Divider(color: providerBorder)),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(
          'or',
          style: TextStyle(
            fontFamily: kFontFamily,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: providerMuted,
          ),
        ),
      ),
      const Expanded(child: Divider(color: providerBorder)),
    ],
  );
}

/// Collapsible manual-entry row. The enrolment secret is only materialised
/// while the section is open, and is never logged or persisted.
class _ManualKeyCard extends StatelessWidget {
  const _ManualKeyCard({
    required this.open,
    required this.secret,
    required this.onToggle,
    required this.onCopy,
  });

  final bool open;
  final String secret;
  final VoidCallback onToggle;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: providerBorder),
    ),
    child: Column(
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onToggle,
          child: Semantics(
            button: true,
            label: open
                ? 'Hide manual setup key'
                : 'Enter setup key manually',
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              child: Row(
                children: [
                  const Icon(Icons.key_rounded, size: 19, color: providerBrand),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Enter setup key manually',
                      style: TextStyle(
                        fontFamily: kFontFamily,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: providerInk,
                      ),
                    ),
                  ),
                  Icon(
                    open
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.chevron_right_rounded,
                    size: 20,
                    color: providerMuted,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (open) ...[
          const Divider(height: 1, color: providerBorder),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  secret,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.4,
                    color: providerInk,
                    fontFamily: 'monospace',
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: onCopy,
                    icon: const Icon(Icons.copy_rounded, size: 16),
                    label: const Text('Copy key'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    ),
  );
}

/// Amber informational card: authenticator codes refresh every 30 seconds.
class _CodeTipsCard extends StatelessWidget {
  const _CodeTipsCard();

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: SitewiseM3.amberWash,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: SitewiseM3.amber.withValues(alpha: .25)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.info_outline_rounded,
          size: 18,
          color: SitewiseM3.amber,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Code tips',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: SitewiseM3.amber,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                'Authenticator codes usually refresh every 30 seconds. Enter '
                'the latest code shown in your app.',
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 11.5,
                  height: 1.45,
                  color: SitewiseM3.amber,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Six separated digit boxes driven by ONE real, invisible text field.
///
/// A single field (rather than six) keeps paste, backspace, the numeric
/// keyboard and the screen-reader story correct: the boxes are a visual
/// projection of the field's text, and the field itself carries the
/// accessibility label. Focus moves implicitly — the next empty box is the
/// highlighted one.
class _SixDigitField extends StatefulWidget {
  const _SixDigitField({
    required this.controller,
    required this.onChanged,
    required this.onSubmit,
    this.enabled = true,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmit;
  final bool enabled;

  @override
  State<_SixDigitField> createState() => _SixDigitFieldState();
}

class _SixDigitFieldState extends State<_SixDigitField> {
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_refocus);
    widget.controller.addListener(_refocus);
  }

  @override
  void didUpdateWidget(_SixDigitField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_refocus);
      widget.controller.addListener(_refocus);
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_refocus);
    widget.controller.removeListener(_refocus);
    _focus.dispose();
    super.dispose();
  }

  void _refocus() {
    if (mounted) setState(() {});
    final text = widget.controller.text;
    final selection = widget.controller.selection;
    // Keep the caret at the end so mid-string edits always act on the last
    // box, which is the mental model six separated boxes create.
    if (selection.end != text.length || selection.start != text.length) {
      widget.controller.selection = TextSelection.collapsed(
        offset: text.length,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final code = widget.controller.text;
    final focused = _focus.hasFocus;
    return Semantics(
      label: 'Six-digit authenticator code',
      child: GestureDetector(
        onTap: widget.enabled ? () => _focus.requestFocus() : null,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Row(
              children: [
                for (var i = 0; i < 6; i++)
                  Expanded(child: _box(i, code, focused)),
              ],
            ),
            Positioned.fill(
              child: Opacity(
                opacity: 0,
                child: TextField(
                  controller: widget.controller,
                  focusNode: _focus,
                  enabled: widget.enabled,
                  autofocus: false,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(6),
                  ],
                  onChanged: widget.onChanged,
                  onSubmitted: widget.onSubmit,
                  // The visible boxes are the label's projection; the field
                  // itself must never paint a caret or text over them.
                  showCursor: false,
                  style: const TextStyle(color: Colors.transparent),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _box(int index, String code, bool fieldFocused) {
    final filled = index < code.length;
    final active = fieldFocused && index == code.length && !filled;
    return Container(
      height: 58,
      margin: EdgeInsets.only(left: index == 0 ? 0 : 5, right: index == 5 ? 0 : 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: active ? providerBrand : providerBorder,
          width: active ? 2 : 1.4,
        ),
        boxShadow: active
            ? [
                BoxShadow(
                  color: providerBrand.withValues(alpha: .12),
                  blurRadius: 6,
                ),
              ]
            : null,
      ),
      child: filled
          ? FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                code[index],
                style: TextStyle(
                  fontFamily: kFontFamily,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: providerInk,
                ),
              ),
            )
          : null,
    );
  }
}
