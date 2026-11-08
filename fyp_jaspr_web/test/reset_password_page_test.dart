import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/pages/auth_callback_page.dart';
import 'package:sitewise_jaspr_web/pages/reset_password_page.dart';

/// Component tests for the rebuilt "Set a New Password" page and the callback
/// page's error affordances (invitation acceptance task). Typing simulation is
/// not possible in the component-test binding (input events read
/// `event.target`), so filled-form paths are covered by
/// `tool/test_callback_flows.js` against the real bridge source.
void main() {
  testComponents('reset page renders the two-panel onboarding design', (
    tester,
  ) async {
    tester.pumpComponent(const ResetPasswordPage());

    // Left panel: brand, heading, three-step tracker. The hero heading is a
    // LetterRevealHeading, whose text lives in per-letter spans, so it is
    // matched as the h1 node; step 2's label is the plain-text copy.
    expect(find.text('SiteWise'), findsOneComponent);
    expect(find.tag('h1'), findsOneComponent);
    expect(find.text('Invitation Received'), findsOneComponent);
    expect(find.text('Set a New Password'), findsOneComponent);
    expect(find.text('Sign In & Get Activated'), findsOneComponent);

    // Right panel: fields, live requirements checklist, gradient action, back link.
    expect(find.text('New Password'), findsOneComponent);
    expect(find.text('Confirm Password'), findsOneComponent);
    expect(find.text('At least 8 characters'), findsOneComponent);
    expect(find.text('One uppercase letter (A–Z)'), findsOneComponent);
    expect(find.text('One lowercase letter (a–z)'), findsOneComponent);
    expect(find.text('One number (0–9)'), findsOneComponent);
    expect(find.text('One special character (!@#\$…)'), findsOneComponent);
    expect(find.text('Both passwords match'), findsOneComponent);
    expect(find.text('Set Password'), findsOneComponent);
    expect(find.text('Back to Sign In'), findsOneComponent);
  });

  testComponents('empty submit surfaces field errors and alert', (tester) async {
    tester.pumpComponent(const ResetPasswordPage());

    final submit = find.ancestor(
      of: find.text('Set Password'),
      matching: find.tag('button'),
    );
    await tester.click(submit);

    expect(find.text('Enter a new password.'), findsOneComponent);
    expect(find.text('Confirm your new password.'), findsOneComponent);
    expect(find.text('Please fix the highlighted fields.'), findsOneComponent);
  });

  testComponents('callback page error state links back to the staff portal', (
    tester,
  ) async {
    // On the VM the auth bridge is the not-configured stub: initialize() is a
    // no-op and complete() throws, which is exactly the error-state render.
    tester.pumpComponent(const AuthCallbackPage());
    // initState kicks off the async complete(); pump until the stub's
    // rejection has been setState'd into the error render.
    await tester.pump();
    await tester.pump();

    expect(find.text('Sign-in could not finish'), findsOneComponent);
    expect(find.text('Back to Staff Sign-in'), findsOneComponent);
    expect(find.text('Go to sign in'), findsOneComponent);
  });
}
