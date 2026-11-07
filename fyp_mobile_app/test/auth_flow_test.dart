import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:fyp/core/config/mobile_endpoints.dart';
import 'package:fyp/data/repositories/supabase_auth_repository.dart';

import 'support/fake_auth_repository.dart';

/// Unit coverage for the authentication state machine and the two testable
/// seams of the Supabase repository: how a backend profile response is read,
/// and how a provider error is translated. The screen-level consequences are
/// in `widget_test.dart`; the real-service check is `supabase_live_test.dart`.
void main() {
  late FakeAuthRepository repo;
  late AuthCubit cubit;

  setUp(() {
    repo = FakeAuthRepository();
    cubit = AuthCubit(auth: AuthService(repo));
  });

  tearDown(() async {
    await cubit.close();
  });

  group('startup restore', () {
    test('begins initializing and exposes no user before the check', () {
      expect(cubit.state.status, AuthStatus.initializing);
      expect(cubit.state.user, isNull);
      expect(cubit.state.isAuthenticated, isFalse);
    });

    test('no stored session resolves to unauthenticated', () async {
      await cubit.start();
      expect(cubit.state.status, AuthStatus.unauthenticated);
      expect(repo.restoreCalls, 1);
    });

    test('a valid stored session resolves to the backend-assigned role',
        () async {
      repo.user = testUser();
      await cubit.start();
      expect(cubit.state.status, AuthStatus.authenticated);
      expect(cubit.state.role, AppRole.entrepreneur);
      expect(cubit.state.status.isActiveSession, isTrue);
    });

    test('start is re-entrant: two widgets mounting cannot race two restores',
        () async {
      await Future.wait([cubit.start(), cubit.start()]);
      expect(repo.restoreCalls, 1);
    });

    test('a second start after the first finished changes nothing', () async {
      await cubit.start();
      await cubit.start();
      expect(repo.restoreCalls, 1);
    });

    test('an unreachable service is an error with no user', () async {
      repo.restoreFailure = const AuthUnavailableFailure();
      await cubit.start();
      expect(cubit.state.status, AuthStatus.error);
      expect(cubit.state.user, isNull);
      expect(cubit.state.isAuthenticated, isFalse);
    });

    test('an expired session is dropped so a restart cannot re-offer it',
        () async {
      repo.user = testUser();
      repo.restoreFailure = const SessionExpiredFailure();
      await cubit.start();
      expect(cubit.state.status, AuthStatus.sessionExpired);
      expect(repo.signOutCalls, 1);
      expect(repo.user, isNull);
    });

    test('a suspended profile at restore reports account inactive', () async {
      repo.restoreFailure = const AccountInactiveFailure(status: 'suspended');
      await cubit.start();
      expect(cubit.state.status, AuthStatus.accountInactive);
      expect(cubit.state.user, isNull);
      expect(repo.signOutCalls, 1);
    });

    test('retry re-checks after the user acted on a failure', () async {
      repo.restoreFailure = const AuthUnavailableFailure();
      await cubit.start();
      expect(cubit.state.status, AuthStatus.error);

      repo.restoreFailure = null;
      repo.user = testUser();
      await cubit.retry();
      expect(cubit.state.status, AuthStatus.authenticated);
      expect(repo.restoreCalls, 2);
    });

    test('an unexpected repository crash still fails closed', () async {
      final broken = AuthCubit(
        auth: AuthService(_ThrowingRepository(StateError('boom'))),
      );
      addTearDown(broken.close);
      await broken.start();
      expect(broken.state.status, AuthStatus.error);
      expect(broken.state.user, isNull);
    });
  });

  group('sign in', () {
    test('success authenticates with the profile the backend returned',
        () async {
      final ok = await cubit.signIn(
        email: 'sarah@artisanbrew.my',
        password: 'secret123',
      );
      expect(ok, isTrue);
      expect(cubit.state.status, AuthStatus.authenticated);
      expect(cubit.state.user?.role, AppRole.entrepreneur);
      expect(repo.lastSignInEmail, 'sarah@artisanbrew.my');
    });

    test('wrong credentials stay unauthenticated and carry the reason',
        () async {
      repo.signInFailure = const InvalidCredentialsFailure();
      final ok = await cubit.signIn(
        email: 'sarah@artisanbrew.my',
        password: 'nope',
      );
      expect(ok, isFalse);
      expect(cubit.state.status, AuthStatus.unauthenticated);
      expect(cubit.state.user, isNull);
      expect(cubit.state.message, 'Incorrect email or password.');
    });

    test('a pending account is inactive, never signed in', () async {
      repo.signInFailure = const AccountInactiveFailure(status: 'pending');
      final ok = await cubit.signIn(
        email: 'sarah@artisanbrew.my',
        password: 'secret123',
      );
      expect(ok, isFalse);
      expect(cubit.state.status, AuthStatus.accountInactive);
      expect(cubit.state.user, isNull);
      expect(cubit.state.email, 'sarah@artisanbrew.my');
    });

    test('a network failure withholds access as an error', () async {
      repo.signInFailure = const NetworkFailure();
      final ok = await cubit.signIn(
        email: 'sarah@artisanbrew.my',
        password: 'secret123',
      );
      expect(ok, isFalse);
      expect(cubit.state.status, AuthStatus.error);
      expect(cubit.state.user, isNull);
    });

    test('a second tap while a request is in flight sends one request',
        () async {
      final gate = Completer<SitewiseUser>();
      final slow = _SlowRepository(gate);
      final slowCubit = AuthCubit(auth: AuthService(slow));
      addTearDown(slowCubit.close);

      final first = slowCubit.signIn(
        email: 'a@b.my',
        password: 'secret123',
      );
      final second = slowCubit.signIn(
        email: 'c@d.my',
        password: 'secret123',
      );
      expect(await second, isFalse);
      expect(slow.credentialCalls, 1);

      gate.complete(testUser(email: 'a@b.my'));
      expect(await first, isTrue);
      expect(slowCubit.state.user?.email, 'a@b.my');
    });

    test('federated sign in reports failure instead of inventing a session',
        () async {
      repo.providerFailure = const AuthFailure(
        'Sign in with google is not available in the mobile app yet.',
      );
      final ok = await cubit.signInWithProvider(AuthProvider.google);
      expect(ok, isFalse);
      expect(cubit.state.status, AuthStatus.unauthenticated);
      expect(cubit.state.user, isNull);
    });
  });

  group('registration', () {
    test('creates an entrepreneur and carries the collected name', () async {
      final ok = await cubit.signUp(
        email: 'joel@artisanbrew.my',
        password: 'secret123',
        fullName: 'Joel Tan',
      );
      expect(ok, isTrue);
      expect(repo.lastSignUpFullName, 'Joel Tan');
      expect(cubit.state.user?.role, AppRole.entrepreneur);
    });

    test('a taken address keeps the user on the form', () async {
      repo.signUpFailure = const DuplicateEmailFailure();
      final ok = await cubit.signUp(
        email: 'sarah@artisanbrew.my',
        password: 'secret123',
        fullName: 'Sarah Tan',
      );
      expect(ok, isFalse);
      expect(cubit.state.status, AuthStatus.unauthenticated);
      expect(cubit.state.user, isNull);
      expect(cubit.state.message, isNotNull);
    });

    test('an unconfirmed address is its own state with the address shown',
        () async {
      repo.signUpFailure = const EmailConfirmationRequiredFailure(
        email: 'joel@artisanbrew.my',
      );
      final ok = await cubit.signUp(
        email: 'joel@artisanbrew.my',
        password: 'secret123',
        fullName: 'Joel Tan',
      );
      expect(ok, isFalse);
      expect(cubit.state.status, AuthStatus.emailConfirmationRequired);
      expect(cubit.state.email, 'joel@artisanbrew.my');
      expect(cubit.state.user, isNull);
    });
  });

  group('sign out and recovery', () {
    test('signing out clears the session and the state', () async {
      await cubit.signIn(email: 'sarah@artisanbrew.my', password: 'secret123');
      await cubit.signOut();
      expect(cubit.state.status, AuthStatus.unauthenticated);
      expect(cubit.state.user, isNull);
      expect(repo.user, isNull);
    });

    test('a failing server-side sign-out still locks the app', () async {
      await cubit.signIn(email: 'sarah@artisanbrew.my', password: 'secret123');
      repo.signOutFailure = const NetworkFailure();
      await cubit.signOut();
      expect(cubit.state.status, AuthStatus.unauthenticated);
      expect(cubit.state.isAuthenticated, isFalse);
    });

    test('recovery sends the email and never signs the user in', () async {
      final message = await cubit.recoverPassword('sarah@artisanbrew.my');
      expect(repo.lastRecoveryEmail, 'sarah@artisanbrew.my');
      expect(message, contains('reset link'));
      expect(cubit.state.status, AuthStatus.initializing);
      expect(cubit.state.user, isNull);
    });

    test('a recovery failure surfaces without touching the session state',
        () async {
      repo.recoveryFailure = const NetworkFailure();
      final message = await cubit.recoverPassword('sarah@artisanbrew.my');
      expect(message, isNotEmpty);
      expect(cubit.state.status, AuthStatus.initializing);
      expect(repo.credentialCalls, 0);
    });
  });

  group('backend profile validation', () {
    HttpIdentityProbe probeWith(int status, Object body) => HttpIdentityProbe(
      endpoint: MobileEndpoints.profileUri,
      client: MockClient(
        (_) async => http.Response(jsonEncode(body), status),
      ),
    );

    test('a 200 profile is returned decoded', () async {
      final profile = await probeWith(
        200,
        {'user_id': 'u1', 'role': 'entrepreneur'},
      ).fetch('token');
      expect(profile['role'], 'entrepreneur');
    });

    test('a 401 means the session authorises nothing', () async {
      final probe = probeWith(401, {'detail': 'Sign in to continue.'});
      await expectLater(
        probe.fetch('t'),
        throwsA(isA<SessionExpiredFailure>()),
      );
    });

    test('a 403 means the account is not permitted', () async {
      final probe = probeWith(403, {'detail': 'forbidden'});
      await expectLater(probe.fetch('t'), throwsA(isA<AccountInactiveFailure>()));
    });

    test('a 503 from the verifier withholds access', () async {
      final probe = probeWith(503, {'detail': 'unreachable'});
      await expectLater(
        probe.fetch('t'),
        throwsA(isA<AuthUnavailableFailure>()),
      );
    });

    test('an unexpected status is never treated as success', () async {
      final probe = probeWith(500, {'detail': 'boom'});
      await expectLater(
        probe.fetch('t'),
        throwsA(isA<AuthUnavailableFailure>()),
      );
    });

    test('a body that is not a profile is not trusted', () async {
      final probe = probeWith(200, 'not a map');
      await expectLater(
        probe.fetch('t'),
        throwsA(isA<AuthUnavailableFailure>()),
      );
    });

    test('a transport failure is offline, not signed out', () async {
      final probe = HttpIdentityProbe(
        endpoint: MobileEndpoints.profileUri,
        client: MockClient((_) async => throw const SocketException('down')),
      );
      await expectLater(probe.fetch('t'), throwsA(isA<NetworkFailure>()));
    });

    test('a verifier that never answers times out closed', () async {
      final probe = HttpIdentityProbe(
        endpoint: MobileEndpoints.profileUri,
        client: MockClient(
          (_) => Future.error(TimeoutException('verifier did not answer')),
        ),
      );
      await expectLater(
        probe.fetch('t'),
        throwsA(isA<AuthUnavailableFailure>()),
      );
    });
  });

  group('provider error translation', () {
    test('an already registered address becomes a duplicate failure', () {
      expect(
        mapSupabaseError(
          AuthException(
            'User already registered',
            code: ErrorCode.userAlreadyExists.code,
          ),
        ),
        isA<DuplicateEmailFailure>(),
      );
    });

    test('an unconfirmed address becomes the confirmation state', () {
      final failure = mapSupabaseError(
        const AuthException(
          'Email not confirmed',
          code: 'email_not_confirmed',
        ),
        email: 'joel@artisanbrew.my',
      );
      expect(failure, isA<EmailConfirmationRequiredFailure>());
      expect(
        (failure as EmailConfirmationRequiredFailure).email,
        'joel@artisanbrew.my',
      );
    });

    test('a banned user becomes account inactive', () {
      expect(
        mapSupabaseError(
          const AuthException('user banned', code: 'user_banned'),
        ),
        isA<AccountInactiveFailure>(),
      );
    });

    test('a weak password is a validation failure, not a session problem', () {
      expect(
        mapSupabaseError(
          const AuthException('Password too weak', code: 'weak_password'),
        ),
        isA<ValidationFailure>(),
      );
    });

    test('invalid credentials are reported as invalid credentials', () {
      expect(
        mapSupabaseError(
          const AuthException(
            'Invalid Login Credentials',
            statusCode: '400',
            code: 'invalid_credentials',
          ),
        ),
        isA<InvalidCredentialsFailure>(),
      );
    });

    test('a missing session is not reported as a bad password', () {
      expect(
        mapSupabaseError(AuthSessionMissingException()),
        isA<SessionExpiredFailure>(),
      );
    });

    test('a retryable fetch error becomes a network failure', () {
      expect(
        mapSupabaseError(AuthRetryableFetchException()),
        isA<NetworkFailure>(),
      );
    });

    test('an unmapped provider error still withholds access', () {
      expect(
        mapSupabaseError(const AuthException('something unexpected')),
        isA<AuthFailure>(),
      );
    });
  });

  group('unconfigured build', () {
    // `Supabase.initialize()` has not run in these tests, so every call must
    // fail closed rather than report an empty "signed out, all fine" session.
    test('the repository refuses to answer about the session', () async {
      final live = SupabaseAuthRepository();
      await expectLater(
        live.currentUser(),
        throwsA(isA<AuthUnavailableFailure>()),
      );
      await expectLater(
        live.signInWithEmail(email: 'a@b.my', password: 'secret123'),
        throwsA(isA<AuthUnavailableFailure>()),
      );
      await expectLater(
        live.signUpWithEmail(email: 'a@b.my', password: 'secret123'),
        throwsA(isA<AuthUnavailableFailure>()),
      );
      await expectLater(
        live.sendPasswordRecoveryEmail('a@b.my'),
        throwsA(isA<AuthUnavailableFailure>()),
      );
    });

    test('the cubit turns that into the error state with no access', () async {
      final live = AuthCubit(auth: AuthService(SupabaseAuthRepository()));
      addTearDown(live.close);
      await live.start();
      expect(live.state.status, AuthStatus.error);
      expect(live.state.isAuthenticated, isFalse);
    });
  });
}

/// Throws whatever the test wants to see survive as a closed door.
class _ThrowingRepository extends FakeAuthRepository {
  _ThrowingRepository(this.error);

  final Object error;

  @override
  Future<SitewiseUser?> currentUser() async => throw error;
}

/// Holds its first credential call open until [gate] completes, to prove a
/// second tap cannot send a second request.
class _SlowRepository extends FakeAuthRepository {
  _SlowRepository(this.gate);

  final Completer<SitewiseUser> gate;

  @override
  Future<SitewiseUser> signInWithEmail({
    required String email,
    required String password,
  }) async {
    credentialCalls++;
    return gate.future;
  }
}
