/// Second-factor (authenticator) contract for staff accounts.
///
/// SiteWise gives agents and administrators mandatory TOTP multi-factor
/// authentication: the backend refuses every staff route unless the signed
/// token carries `aal2`, so a password-only session can sign in but cannot
/// manage anything. This contract is the step-up half of that flow — listing
/// the account's factors, enrolling a new authenticator, and exchanging a code
/// for an elevated session.
///
/// It is deliberately NOT part of [AuthRepository]. Sign-in and step-up fail
/// differently and recover differently, and an entrepreneur never sees this
/// flow at all. Keeping it separate is what makes "do not introduce MFA into
/// the entrepreneur login flow" a structural property rather than a promise.
///
/// Implementation note: the only secrets that ever live in memory are the
/// enrolment secret and the otpauth URI Supabase returns, and only for the
/// duration of the enrolment screen. Nothing here logs them.
library;

import '../../core/errors/app_failure.dart';

/// One authentication factor attached to the signed-in account.
class MfaFactor {
  const MfaFactor({
    required this.id,
    required this.verified,
    this.friendlyName,
    this.createdAt,
  });

  final String id;

  /// `true` once a code from this authenticator has been accepted at least
  /// once. An unverified factor is an abandoned enrolment, not a usable one.
  final bool verified;
  final String? friendlyName;
  final DateTime? createdAt;

  String get displayName {
    final name = friendlyName?.trim();
    return (name == null || name.isEmpty) ? 'Authenticator app' : name;
  }
}

/// A freshly started TOTP enrolment that has NOT been verified yet.
///
/// [uri] is the `otpauth://` URI encoded in the provider's QR code; [secret] is
/// the same key in manual-entry form, for a device whose camera cannot read
/// the code. Neither is persisted by this app.
class MfaEnrollment {
  const MfaEnrollment({
    required this.factorId,
    required this.secret,
    required this.uri,
  });

  final String factorId;
  final String secret;
  final String uri;

  /// The secret in the four-character groups authenticator apps ask for, so a
  /// user copying it by hand can match what they see.
  String get groupedSecret {
    final buffer = StringBuffer();
    for (var i = 0; i < secret.length; i++) {
      if (i > 0 && i % 4 == 0) buffer.write(' ');
      buffer.write(secret[i]);
    }
    return buffer.toString();
  }
}

/// What the server says about this session's second factor.
class MfaState {
  const MfaState({
    required this.factors,
    this.currentLevel,
    this.nextLevel,
  });

  /// Every factor on the account, verified or not.
  final List<MfaFactor> factors;

  /// `aal1` (password only) or `aal2` (password + verified factor).
  final String? currentLevel;

  /// The level this session could reach. `aal2` when a verified factor exists,
  /// otherwise the current level — there is nothing to step up to until one is
  /// enrolled.
  final String? nextLevel;

  List<MfaFactor> get verifiedFactors =>
      [for (final factor in factors) if (factor.verified) factor];

  /// Abandoned enrolments: started, never confirmed. They are not usable, and
  /// the authenticator screen reports them rather than silently ignoring them.
  List<MfaFactor> get pendingFactors =>
      [for (final factor in factors) if (!factor.verified) factor];

  /// The session already carries the required assurance.
  bool get satisfied => currentLevel == 'aal2';

  /// A verified authenticator exists and only a code is missing.
  bool get canChallenge => !satisfied && verifiedFactors.isNotEmpty;

  /// No usable authenticator exists yet: enrolment is the only way forward.
  bool get needsEnrollment => !satisfied && verifiedFactors.isEmpty;

  /// True when the account needs any second-factor work before staff routes
  /// will answer.
  bool get requiresAction => !satisfied && nextLevel == 'aal2';
}

/// Step-up contract. Every method throws an [AppFailure] subtype:
/// [MfaCodeRejectedFailure] for a wrong code, [MfaChallengeExpiredFailure] for
/// an expired challenge, [MfaEnrollmentConflictFailure] when enrolment cannot
/// be started, [SessionExpiredFailure] when there is no session to elevate, and
/// [AuthUnavailableFailure] / [NetworkFailure] when the service is unreachable.
abstract class StaffMfaRepository {
  /// The account's current factors and assurance level.
  Future<MfaState> state();

  /// Begin a TOTP enrolment. The returned factor is UNVERIFIED until
  /// [verifyEnrollment] succeeds; it must be discarded if the user backs out.
  Future<MfaEnrollment> enroll({String? friendlyName});

  /// Confirm a new factor with a code from the authenticator app. On success
  /// the session is promoted to `aal2`.
  Future<void> verifyEnrollment({
    required String factorId,
    required String code,
  });

  /// Step an already-verified factor up for this session: request a challenge
  /// and exchange the code for an `aal2` session.
  Future<void> challengeAndVerify({
    required String factorId,
    required String code,
  });

  /// Abandon an enrolment that was never confirmed. Best effort: a failure must
  /// not trap the user on the setup screen, but the factor is reported as
  /// pending by [state] until it is gone.
  Future<void> discardEnrollment(String factorId);

  /// Remove a verified factor. Only meaningful with an `aal2` session, which is
  /// the provider's own rule and is never bypassed here.
  Future<void> unenroll(String factorId);
}
