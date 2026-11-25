import 'package:riverpod/riverpod.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:test/test.dart';

void main() {
  group('restricted invited-provider authentication', () {
    test('a pending Owner is not an authenticated workspace session', () async {
      final repository = _FakeAuthRepository([_user()]);
      final container = _container(repository);
      addTearDown(container.dispose);

      await container.read(authNotifierProvider.notifier).start();

      final state = container.read(authNotifierProvider);
      expect(state.status, AuthStatus.staffOnboarding);
      expect(state.user?.role, AppRole.owner);
      expect(state.isAuthenticated, isFalse);
      expect(state.status.isActiveSession, isFalse);
      expect(await repository.isAuthenticated(), isFalse);
    });

    test(
      'MFA refresh preserves the restricted state while still pending',
      () async {
        final repository = _FakeAuthRepository([
          _user(assurance: 'aal1'),
          _user(assurance: 'aal2'),
        ]);
        final container = _container(repository);
        addTearDown(container.dispose);
        final notifier = container.read(authNotifierProvider.notifier);
        await notifier.start();

        expect(await notifier.refreshVerifiedSessionAfterMfa(), isTrue);
        final state = container.read(authNotifierProvider);
        expect(state.status, AuthStatus.staffOnboarding);
        expect(state.user?.assuranceLevel, 'aal2');
        expect(state.isAuthenticated, isFalse);
      },
    );

    test(
      'onboarding opens the workspace only after an active /auth/me refresh',
      () async {
        final repository = _FakeAuthRepository([
          _user(assurance: 'aal2'),
          _user(assurance: 'aal2'),
          _user(assurance: 'aal2', status: 'Active'),
        ]);
        final container = _container(repository);
        addTearDown(container.dispose);
        final notifier = container.read(authNotifierProvider.notifier);
        await notifier.start();

        expect(
          await notifier.refreshActiveSessionAfterStaffOnboarding(),
          isFalse,
        );
        expect(
          container.read(authNotifierProvider).status,
          AuthStatus.staffOnboarding,
        );

        expect(
          await notifier.refreshActiveSessionAfterStaffOnboarding(),
          isTrue,
        );
        final state = container.read(authNotifierProvider);
        expect(state.status, AuthStatus.authenticated);
        expect(state.isAuthenticated, isTrue);
        expect(state.user?.isActiveProfile, isTrue);
      },
    );

    test(
      'onboarding rejects a changed identity even if the profile is active',
      () async {
        final repository = _FakeAuthRepository([
          _user(assurance: 'aal2'),
          _user(id: 'another-user', assurance: 'aal2', status: 'Active'),
        ]);
        final container = _container(repository);
        addTearDown(container.dispose);
        final notifier = container.read(authNotifierProvider.notifier);
        await notifier.start();

        expect(
          await notifier.refreshActiveSessionAfterStaffOnboarding(),
          isFalse,
        );
        expect(
          container.read(authNotifierProvider).status,
          AuthStatus.staffOnboarding,
        );
      },
    );
  });

  test('staff lifecycle HTTP failures retain their trusted backend code', () {
    final expired = apiOperationFailure(
      status: 410,
      code: 'invitation_expired',
      message: 'This invitation has expired.',
    );
    expect(expired, isA<StaffOnboardingFailure>());
    expect(expired.backendCode, 'invitation_expired');
    expect(expired.statusCode, 410);

    final mfa = apiOperationFailure(
      status: 403,
      code: 'staff_mfa_required',
      message: 'Complete MFA before onboarding.',
    );
    expect(mfa, isA<StaffOnboardingFailure>());
    expect(mfa.backendCode, 'staff_mfa_required');
  });
}

ProviderContainer _container(_FakeAuthRepository repository) =>
    ProviderContainer(
      overrides: [
        authServiceProvider.overrideWithValue(AuthService(repository)),
      ],
    );

SitewiseUser _user({
  String id = 'owner-user',
  String status = 'Pending',
  String assurance = 'aal1',
}) => SitewiseUser(
  id: id,
  name: 'Invited Owner',
  email: 'owner@example.test',
  role: AppRole.owner,
  status: status,
  location: '',
  joinedAt: DateTime(2026, 1, 1),
  assuranceLevel: assurance,
);

class _FakeAuthRepository implements AuthRepository {
  _FakeAuthRepository(this.users);

  final List<SitewiseUser?> users;
  int _reads = 0;

  @override
  Future<SitewiseUser?> currentUser() async {
    final index = _reads < users.length ? _reads : users.length - 1;
    _reads++;
    return users[index];
  }

  @override
  Future<bool> isAuthenticated() async =>
      (await currentUser())?.isActiveProfile ?? false;

  @override
  Future<SitewiseUser> signInWithEmail({
    required String email,
    required String password,
  }) async => throw UnimplementedError();

  @override
  Future<SitewiseUser> signUpWithEmail({
    required String email,
    required String password,
    String? fullName,
    String? accountPurpose,
    bool acceptTerms = false,
  }) async => throw UnimplementedError();

  @override
  Future<SitewiseUser> signInWithProvider(
    AuthProvider provider, {
    String? accountPurpose,
  }) async => throw UnimplementedError();

  @override
  Future<void> resendSignupVerificationEmail(String email) async =>
      throw UnimplementedError();

  @override
  Future<void> sendPasswordRecoveryEmail(
    String email, {
    String? redirectTo,
  }) async => throw UnimplementedError();

  @override
  Future<void> signOut() async => throw UnimplementedError();
}
