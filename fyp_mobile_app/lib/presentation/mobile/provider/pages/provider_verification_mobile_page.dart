import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../../../core/theme/sitewise_m3.dart';
import '../../../../core/theme/sitewise_theme.dart';
import '../../auth/widgets/auth_field.dart';
import '../../widgets/m3_kit.dart';
import 'provider_models.dart';
import 'provider_ui.dart';
import 'provider_workspace_service.dart';

/// Provider account verification — the real screen behind `/provider/verification`.
///
/// This is **not** property listing verification. Two different questions are
/// asked in SiteWise and they stay separate:
///
/// * here — is this ACCOUNT a real property owner / agency the platform will
///   list for? One record per account, reviewed once.
/// * `PropertyVerificationPage` (per listing) — is this ONE listing accurate
///   and does the submitter own it? Reviewed per submission, and it is what
///   publishes a listing.
///
/// The state shown is always the server's. Nothing on this screen can approve
/// an account: a submission enters `pending` and only an administrator with a
/// completed second factor can decide it.
class ProviderVerificationMobilePage extends ConsumerStatefulWidget {
  const ProviderVerificationMobilePage({super.key});

  @override
  ConsumerState<ProviderVerificationMobilePage> createState() =>
      _ProviderVerificationMobilePageState();
}

class _ProviderVerificationMobilePageState
    extends ConsumerState<ProviderVerificationMobilePage> {
  Future<ProviderVerification>? _future;

  final TextEditingController _businessName = TextEditingController();
  final TextEditingController _contactPhone = TextEditingController();
  final TextEditingController _registrationNo = TextEditingController();
  final TextEditingController _note = TextEditingController();

  bool _submitting = false;
  bool _editing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _businessName.dispose();
    _contactPhone.dispose();
    _registrationNo.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final request = ProviderWorkspaceService.verification();
    if (!mounted) return;
    setState(() {
      _error = null;
      _editing = false;
      _future = request;
    });
    await settleRefresh(request);
  }

  void _startEditing(ProviderVerification verification) {
    _businessName.text = verification.businessName;
    _contactPhone.text = verification.contactPhone;
    _registrationNo.text = verification.registrationNo;
    _note.text = verification.submissionNote;
    setState(() {
      _editing = true;
      _error = null;
    });
  }

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ProviderWorkspaceService.submitVerification(
        businessName: _businessName.text,
        contactPhone: _contactPhone.text,
        registrationNo: _registrationNo.text,
        submissionNote: _note.text,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Submitted for review. An administrator decides it — this screen '
            'never approves an account.',
          ),
        ),
      );
      _load();
    } on AppFailure catch (failure) {
      // The backend's own validation message is what the provider needs, so it
      // is shown verbatim rather than replaced with a generic sentence.
      if (!mounted) return;
      setState(() => _error = failure.userMessage);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: providerCanvas,
      appBar: const ProviderPageAppBar(
        title: 'Verification',
        eyebrow: 'ACCOUNT STANDING',
      ),
      body: RefreshIndicator(
        color: SitewiseColors.action,
        onRefresh: _load,
        child: FutureBuilder<ProviderVerification>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return providerLoadingView();
            }
            if (snapshot.hasError) {
              final error = snapshot.error!;
              return providerContent(
                children: [
                  if (isMfaRequired(error))
                    ProviderMfaGate(onReload: _load)
                  else
                    ProviderMessage(
                      title: 'Your verification status could not be loaded',
                      body: error is AppFailure
                          ? error.userMessage
                          : 'The backend did not answer. Please retry.',
                      onRetry: _load,
                    ),
                ],
              );
            }
            final verification = snapshot.data!;
            return providerContent(
              children: [
                const M3ScreenHeading(
                  eyebrow: 'Provider account',
                  title: 'Verification.',
                  lead:
                      'SiteWise reviews the account behind the listings. '
                      'Each listing is verified separately.',
                ),
                const SizedBox(height: 18),
                _StatusCard(verification: verification),
                const SizedBox(height: 14),
                if (verification.isRejected &&
                    (verification.decisionNote ?? '').isNotEmpty) ...[
                  _Decision(
                    title: 'What to correct',
                    body: verification.decisionNote!,
                    tone: const Color(0xFF9B1C1C),
                    background: const Color(0xFFFDECEC),
                  ),
                  const SizedBox(height: 14),
                ],
                if (verification.isApproved &&
                    (verification.decisionNote ?? '').isNotEmpty) ...[
                  _Decision(
                    title: 'Reviewer note',
                    body: verification.decisionNote!,
                    tone: const Color(0xFF0B6B45),
                    background: const Color(0xFFE6F6EE),
                  ),
                  const SizedBox(height: 14),
                ],
                if (verification.canSubmit)
                  _editing ? _form(verification) : _startCard(verification),
                if (!verification.canSubmit && !verification.isUnsubmitted)
                  _submittedCard(verification),
                const SizedBox(height: 14),
                _listingVerificationNote(),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _startCard(ProviderVerification verification) => ProviderCard(
    title: 'What is required',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final requirement in verification.requirements)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  requirement.required
                      ? Icons.check_circle_outline_rounded
                      : Icons.add_circle_outline_rounded,
                  size: 17,
                  color: requirement.required ? providerBrand : providerMuted,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        requirement.required
                            ? '${requirement.label} · required'
                            : '${requirement.label} · optional',
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: providerInk,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        requirement.help,
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
          ),
        const SizedBox(height: 6),
        FilledButton(
          onPressed: () => _startEditing(verification),
          style: FilledButton.styleFrom(
            backgroundColor: SitewiseColors.action,
            foregroundColor: SitewiseM3.surface,
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
            ),
          ),
          child: Text(
            verification.isRejected
                ? 'Correct and resubmit'
                : 'Start verification',
          ),
        ),
      ],
    ),
  );

  Widget _form(ProviderVerification verification) => ProviderCard(
    title: verification.isRejected ? 'Resubmit' : 'Your details',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AuthField(
          label: 'Name you list under',
          hint: 'Your name or the agency you represent',
          icon: Icons.badge_outlined,
          controller: _businessName,
          required: true,
        ),
        const SizedBox(height: 14),
        AuthField(
          label: 'Contact phone',
          hint: '+60 12 345 6789',
          icon: Icons.phone_outlined,
          controller: _contactPhone,
          keyboardType: TextInputType.phone,
          required: true,
        ),
        const SizedBox(height: 14),
        AuthField(
          label: 'Business registration number',
          hint: 'Optional',
          icon: Icons.assignment_outlined,
          controller: _registrationNo,
        ),
        const SizedBox(height: 14),
        AuthField(
          label: 'What you manage',
          hint: 'Which properties, and in which areas',
          icon: Icons.notes_outlined,
          controller: _note,
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: SitewiseColors.dangerWash,
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: SitewiseColors.dangerWash),
            ),
            child: Text(
              _error!,
              style: const TextStyle(
                fontFamily: kFontFamily,
                fontSize: 12,
                height: 1.45,
                color: SitewiseColors.danger,
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          style: FilledButton.styleFrom(
            backgroundColor: SitewiseColors.action,
            foregroundColor: SitewiseM3.surface,
            minimumSize: const Size.fromHeight(50),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(SitewiseM3.radiusPill),
            ),
          ),
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Submit for review'),
        ),
        const SizedBox(height: 6),
        TextButton(
          onPressed: _submitting ? null : _load,
          child: const Text('Cancel'),
        ),
        const Text(
          'Submitting puts this account in the review queue. It does not '
          'verify anything by itself.',
          style: TextStyle(fontSize: 11.5, height: 1.4, color: providerMuted),
        ),
      ],
    ),
  );

  Widget _submittedCard(ProviderVerification verification) => ProviderCard(
    title: 'Submitted details',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Row(label: 'Name', value: verification.businessName),
        _Row(label: 'Contact phone', value: verification.contactPhone),
        _Row(
          label: 'Registration no.',
          value: verification.registrationNo.isEmpty
              ? 'Not provided'
              : verification.registrationNo,
        ),
        _Row(
          label: 'What you manage',
          value: verification.submissionNote.isEmpty
              ? 'Not provided'
              : verification.submissionNote,
        ),
        _Row(label: 'Submitted', value: _stamp(verification.submittedAt)),
        if (verification.reviewedAt != null)
          _Row(label: 'Reviewed', value: _stamp(verification.reviewedAt)),
      ],
    ),
  );

  static String _stamp(String? iso) {
    if (iso == null || iso.isEmpty) return 'Not reported';
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return iso;
    final local = parsed.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  /// The two checks are easy to confuse, so the screen states the difference
  /// instead of letting the label "Verification" imply one covers the other.
  Widget _listingVerificationNote() => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: providerSoft,
      borderRadius: BorderRadius.circular(SitewiseM3.radiusCard),
      border: Border.all(color: SitewiseM3.line),
    ),
    child: const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.info_outline_rounded,
          size: 18,
          color: SitewiseColors.action,
        ),
        SizedBox(width: 10),
        Expanded(
          child: Text(
            'This page verifies the ACCOUNT. Each listing is verified '
            'separately: open a listing in My listings and submit it for '
            'review when its details and ownership evidence are ready.',
            style: TextStyle(
              fontFamily: kFontFamily,
              fontSize: 11,
              height: 1.5,
              color: SitewiseM3.muted,
            ),
          ),
        ),
      ],
    ),
  );
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.verification});

  final ProviderVerification verification;

  @override
  Widget build(BuildContext context) {
    final (
      String body,
      IconData icon,
      Color tint,
      Color background,
    ) = switch (verification.status) {
      'unsubmitted' => (
        'This account has not been verified yet. Verification confirms '
            'who is behind the account; it is what lets a reviewer trust '
            'the listings you submit.',
        Icons.verified_outlined,
        const Color(0xFF8A5A00),
        const Color(0xFFFFF4E0),
      ),
      'pending' => (
        'Your submission is with an administrator. Nothing changes on this '
            'screen until a decision is recorded.',
        Icons.hourglass_top_rounded,
        const Color(0xFF8A5A00),
        const Color(0xFFFFF4E0),
      ),
      'approved' => (
        'This account is verified. Owned and assigned listings are '
            'reviewed on their own merits — verification of the account '
            'does not publish a listing.',
        Icons.verified_rounded,
        const Color(0xFF0B6B45),
        const Color(0xFFE6F6EE),
      ),
      'rejected' => (
        'The submission was not accepted. The reviewer\'s reason is below; '
            'correct it and resubmit.',
        Icons.report_gmailerrorred_rounded,
        const Color(0xFF9B1C1C),
        const Color(0xFFFDECEC),
      ),
      _ => (
        'This account carries a verification status this build does not '
            'recognise, so no action is offered.',
        Icons.help_outline_rounded,
        providerMuted,
        const Color(0xFFF1F3F6),
      ),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(SitewiseM3.radiusCard),
        border: Border.all(color: SitewiseM3.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: tint, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  verification.statusLabel,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: tint,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.45,
              color: providerInk,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            verification.providerRole == 'agent'
                ? 'Account type: Agent'
                : 'Account type: Property Owner',
            style: const TextStyle(fontSize: 11.5, color: providerMuted),
          ),
        ],
      ),
    );
  }
}

class _Decision extends StatelessWidget {
  const _Decision({
    required this.title,
    required this.body,
    required this.tone,
    required this.background,
  });

  final String title;
  final String body;
  final Color tone;
  final Color background;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: tone,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          body,
          style: const TextStyle(
            fontSize: 12.5,
            height: 1.45,
            color: providerInk,
          ),
        ),
      ],
    ),
  );
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 120,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12.5, color: providerMuted),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: providerInk,
            ),
          ),
        ),
      ],
    ),
  );
}
