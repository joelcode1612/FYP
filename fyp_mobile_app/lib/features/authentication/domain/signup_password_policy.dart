/// The password rules the registration form shows and enforces.
///
/// This is business logic, not presentation: both the Step 2 indicators and
/// `SupabaseAuthRepository.signUpWithEmail` read these rules, so a green
/// indicator can never advertise a password the registration layer rejects.
///
/// Relationship to the existing authentication system: sign-in still applies
/// the repository's historical 6-character floor (`_requirePassword`), because
/// existing accounts must keep working. Registration applies this stricter
/// SiteWise policy (8 characters + a letter + a number). Supabase additionally
/// applies its own server-side weak-password rule, which is reported through
/// the existing `ValidationFailure` path — the client never claims to know
/// that server configuration.
typedef PasswordRuleStatus = ({String label, bool met});

abstract final class SignupPasswordPolicy {
  static const int minLength = 8;

  static final RegExp _letter = RegExp(r'[A-Za-z]');
  static final RegExp _digit = RegExp(r'[0-9]');

  /// One entry per visible requirement, in the order shown in the design.
  static List<PasswordRuleStatus> evaluate(String password) => [
    (
      label: 'At least $minLength characters',
      met: password.length >= minLength,
    ),
    (label: 'Includes a letter (A–Z)', met: _letter.hasMatch(password)),
    (label: 'Includes a number (0–9)', met: _digit.hasMatch(password)),
  ];

  static bool isValid(String password) =>
      evaluate(password).every((rule) => rule.met);

  /// Safe, user-facing summary shown when a submission fails validation.
  static const String requirementMessage =
      'Your password must be at least 8 characters and include a letter '
      'and a number.';
}
