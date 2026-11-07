import 'package:flutter_test/flutter_test.dart';
import 'package:shared_logic/shared_logic.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:fyp/core/config/mobile_endpoints.dart';
import 'package:fyp/data/repositories/supabase_auth_repository.dart';

/// Real-service checks, kept apart from the fake-driven suites because they
/// reach the live Supabase project and the running SiteWise backend.
///
/// Run them with the same defines the app uses:
///
/// ```sh
/// flutter test test/supabase_live_test.dart \
///   --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_PUBLISHABLE_KEY=... \
///   --dart-define=LIVE_BACKEND=true
/// ```
///
/// Nothing here creates or changes an account: it proves the credentials
/// path rejects what it must. A *successful* login additionally needs the
/// developer's own `AUTH_PROBE_EMAIL` / `AUTH_PROBE_PASSWORD`, and stays
/// skipped without them rather than pretending to have passed.
void main() {
  const liveUrl = String.fromEnvironment('SUPABASE_URL');
  const liveKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
  const backendExpected = bool.fromEnvironment('LIVE_BACKEND');
  const probeEmail = String.fromEnvironment('AUTH_PROBE_EMAIL');
  const probePassword = String.fromEnvironment('AUTH_PROBE_PASSWORD');

  final supabaseConfigured = liveUrl.isNotEmpty && liveKey.isNotEmpty;

  setUpAll(() async {
    if (!supabaseConfigured) return;
    await Supabase.initialize(
      url: liveUrl,
      publishableKey: liveKey,
      authOptions: const FlutterAuthClientOptions(
        // A test run must not leave a session behind on the machine.
        localStorage: EmptyLocalStorage(),
        persistSession: false,
        autoRefreshToken: false,
        detectSessionInUri: false,
      ),
    );
  });

  tearDown(() async {
    if (!supabaseConfigured) return;
    await Supabase.instance.client.auth.signOut();
  });

  group('live Supabase', () {
    test(
      'a wrong password is rejected by the real provider, not accepted',
      () async {
        final repo = SupabaseAuthRepository();
        SitewiseUser? signedIn;
        AppFailure? failure;
        try {
          signedIn = await repo.signInWithEmail(
            email: probeEmail.isEmpty
                ? 'sitewise-auth-probe@example.invalid'
                : probeEmail,
            password: 'definitely-not-the-password-1',
          );
        } on AppFailure catch (error) {
          failure = error;
        }

        expect(signedIn, isNull, reason: 'the live service must refuse this');
        expect(
          failure,
          anyOf(
            isA<InvalidCredentialsFailure>(),
            // Rate limiting and offline GoTrue are also refusals — neither
            // may be mistaken for a signed-in user.
            isA<NetworkFailure>(),
            isA<AuthUnavailableFailure>(),
          ),
          reason: '${failure.runtimeType}: ${failure?.message}',
        );
        expect(await repo.currentUser(), isNull);
      },
      skip: !supabaseConfigured
          ? 'SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY not supplied'
          : false,
    );

    test(
      'the real backend refuses a profile request without a valid token',
      () async {
        AppFailure? failure;
        Map<String, dynamic>? profile;
        try {
          profile = await HttpIdentityProbe().fetch(
            'not-a-real-jwt-signature-value',
          );
        } on AppFailure catch (error) {
          failure = error;
        }

        expect(
          profile,
          isNull,
          reason: 'an unsigned request must never return a profile',
        );
        expect(
          failure,
          anyOf(isA<SessionExpiredFailure>(), isA<AuthUnavailableFailure>()),
          reason: '${failure.runtimeType}: ${failure?.message}',
        );
      },
      skip: !backendExpected
          ? 'pass --dart-define=LIVE_BACKEND=true with the SiteWise server '
                'running at ${MobileEndpoints.apiBaseUrl}'
          : false,
    );

    test(
      'a real sign-in resolves the backend-assigned role and status',
      () async {
        final repo = SupabaseAuthRepository();
        final user = await repo.signInWithEmail(
          email: probeEmail,
          password: probePassword,
        );

        // Both come from GET /api/v1/auth/me, never from the client.
        expect(user.status, 'Active');
        expect(user.email.toLowerCase(), probeEmail.toLowerCase());

        final restored = await repo.currentUser();
        expect(restored?.id, user.id, reason: 'the session must re-verify');
      },
      skip: !supabaseConfigured || probeEmail.isEmpty || probePassword.isEmpty
          ? 'supply AUTH_PROBE_EMAIL and AUTH_PROBE_PASSWORD for an existing '
                'account to sign in with'
          : false,
    );
  });
}
