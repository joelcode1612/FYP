import 'dart:async';
import 'dart:io';

import 'package:shared_logic/shared_logic.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Real second-factor transport for the mobile app, over the Supabase SDK's
/// own MFA endpoints.
///
/// The provider owns the factor lifecycle — enrolling a TOTP secret, issuing a
/// challenge, verifying a code and promoting the session to `aal2`. This class
/// only drives it, so there is no second source of truth about who has a
/// second factor, and no code path here can mark an account verified locally.
///
/// Failure mapping is explicit because the recovery action differs per case:
/// a wrong code is retried on the same screen, an expired challenge needs a new
/// challenge, and an enrolment conflict means the account already has factors.
/// Raw provider text never reaches a screen.
class SupabaseStaffMfaRepository implements StaffMfaRepository {
  SupabaseStaffMfaRepository({GoTrueClient Function()? auth})
    : _auth = auth ?? _defaultAuth;

  static GoTrueClient _defaultAuth() => Supabase.instance.client.auth;

  /// The identity of the authenticator entry shown in the user's app. A stable
  /// issuer is what lets an agent tell SiteWise apart from their other codes.
  static const String _issuer = 'SiteWise';

  /// Same ceiling the sign-in path uses: an unreachable auth host must produce
  /// a timeout the user can act on, not a spinner that never stops.
  static const Duration _timeout = Duration(seconds: 15);

  final GoTrueClient Function() _auth;

  Future<T> _guard<T>(Future<T> future, String timeoutMessage) => future.timeout(
    _timeout,
    onTimeout: () async => throw AuthTimeoutFailure(timeoutMessage),
  );

  /// Fails closed when the build has no Supabase configuration, exactly like
  /// the sign-in repository: an unconfigured app reports an unavailable
  /// service rather than behaving as though MFA were optional.
  GoTrueClient get _client {
    try {
      return _auth();
    } on Object {
      throw const AuthConfigurationFailure();
    }
  }

  @override
  Future<MfaState> state() async {
    final client = _client;
    AuthMFAListFactorsResponse listed;
    try {
      // listFactors() refreshes the session first, which is what populates the
      // user's `factors` — the stored token's payload does not carry them.
      // Without this call an enrolled agent would be told to enrol again.
      listed = await _guard(
        client.mfa.listFactors(),
        'Checking your authenticator took too long. Please try again.',
      );
    } on AuthException catch (error) {
      throw _mapAuthException(error);
    } on SocketException {
      throw const NetworkFailure();
    }
    final assurance = client.mfa.getAuthenticatorAssuranceLevel();
    return MfaState(
      factors: [
        for (final factor in listed.all)
          MfaFactor(
            id: factor.id,
            verified: factor.status == FactorStatus.verified,
            friendlyName: factor.friendlyName,
            createdAt: factor.createdAt,
          ),
      ],
      currentLevel: assurance.currentLevel?.name,
      nextLevel: assurance.nextLevel?.name,
    );
  }

  @override
  Future<MfaEnrollment> enroll({String? friendlyName}) async {
    final client = _client;
    try {
      final response = await _guard(
        client.mfa.enroll(
          factorType: FactorType.totp,
          issuer: _issuer,
          friendlyName: friendlyName,
        ),
        'Starting the authenticator setup took too long. Please try again.',
      );
      final totp = response.totp;
      if (totp == null) {
        // TOTP is the only factor this app offers; anything else means the
        // project answered a different request than the one we made.
        throw const AuthUnavailableFailure(
          'The authenticator service did not return a TOTP enrolment.',
        );
      }
      return MfaEnrollment(
        factorId: response.id,
        secret: totp.secret,
        uri: totp.uri,
      );
    } on AuthException catch (error) {
      throw _mapAuthException(error);
    } on SocketException {
      throw const NetworkFailure();
    }
  }

  @override
  Future<void> verifyEnrollment({
    required String factorId,
    required String code,
  }) => _exchange(factorId: factorId, code: code);

  @override
  Future<void> challengeAndVerify({
    required String factorId,
    required String code,
  }) => _exchange(factorId: factorId, code: code);

  /// Both enrolment confirmation and an ordinary step-up are the same exchange:
  /// challenge then verify. On success the SDK replaces the stored session with
  /// the `aal2` one, so every later API call carries the elevated claim.
  Future<void> _exchange({
    required String factorId,
    required String code,
  }) async {
    final client = _client;
    final trimmed = code.trim();
    if (trimmed.isEmpty) {
      throw const MfaCodeRejectedFailure('Enter the six-digit code.');
    }
    try {
      await _guard(
        client.mfa.challengeAndVerify(factorId: factorId, code: trimmed),
        'Verifying the code took too long. Please try again.',
      );
    } on AuthException catch (error) {
      throw _mapAuthException(error);
    } on SocketException {
      throw const NetworkFailure();
    }
  }

  @override
  Future<void> discardEnrollment(String factorId) async {
    try {
      await _guard(
        _client.mfa.unenroll(factorId),
        'Discarding the unfinished enrolment timed out.',
      );
    } on Object {
      // Best effort. The user is leaving the setup screen either way, and an
      // unverified factor cannot be used to sign in. `state()` keeps reporting
      // it as pending, so nothing is hidden — it is simply not worth blocking
      // the exit on.
    }
  }

  @override
  Future<void> unenroll(String factorId) async {
    try {
      await _guard(
        _client.mfa.unenroll(factorId),
        'Removing the authenticator took too long. Please try again.',
      );
    } on AuthException catch (error) {
      throw _mapAuthException(error);
    } on SocketException {
      throw const NetworkFailure();
    }
  }

  /// Maps Gotrue's codes onto the three recoveries the screen offers. Anything
  /// unrecognised becomes a generic retry, never a raw SDK string.
  AppFailure _mapAuthException(AuthException error) {
    final code = error.code?.toLowerCase() ?? '';
    final message = error.message.toLowerCase();

    if (code == ErrorCode.mfaChallengeExpired.code ||
        message.contains('challenge') && message.contains('expired')) {
      return const MfaChallengeExpiredFailure();
    }
    if (code == ErrorCode.mfaVerificationFailed.code ||
        code == ErrorCode.mfaVerificationRejected.code ||
        message.contains('invalid') ||
        message.contains('totp')) {
      return const MfaCodeRejectedFailure();
    }
    if (code == ErrorCode.mfaFactorNameConflict.code ||
        code == ErrorCode.tooManyEnrolledMfaFactors.code) {
      return const MfaEnrollmentConflictFailure();
    }
    if (code == ErrorCode.mfaFactorNotFound.code ||
        code == ErrorCode.sessionExpired.code ||
        error is AuthSessionMissingException) {
      return const SessionExpiredFailure(
        'Your session ended before the code was verified. Sign in again.',
      );
    }
    if (error is AuthRetryableFetchException) {
      return const NetworkFailure();
    }
    return const AuthFailure(
      'The authenticator step could not be completed. Please try again.',
    );
  }
}
