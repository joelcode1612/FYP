import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/pages/login_page.dart';

/// Component tests for the redesigned login page (`lib/pages/login_page.dart`):
/// structure and client-side validation. Typing simulation is not possible in
/// the component-test binding (input events read `event.target`, which has no
/// backing DOM here), so the filled-form paths — demo-submit alert, eye
/// toggle, remember-checkbox hydration, routing — are covered end-to-end by
/// `tool/probe_login.js` against the built site.
void main() {
  testComponents('login page renders the split design', (tester) async {
    tester.pumpComponent(const LoginPage());

    // Hero column.
    expect(
      find.text('Commercial F&B Location Intelligence'),
      findsOneComponent,
    );
    expect(find.text('Welcome back to'), findsOneComponent);
    expect(find.text('SiteWise.'), findsOneComponent);
    expect(find.text('Find Better Locations'), findsOneComponent);
    expect(find.text('Manage Your Shortlists'), findsOneComponent);
    expect(find.text('Data-Driven Decisions'), findsOneComponent);

    // Credential card.
    expect(find.text('Sign in to SiteWise'), findsOneComponent);
    expect(find.text('Continue with Google'), findsOneComponent);
    expect(find.text('Continue with Apple'), findsOneComponent);
    expect(find.text('Forgot password?'), findsOneComponent);
    expect(find.text('Create one now'), findsOneComponent);

    // Social providers are rendered as explicitly unavailable.
    expect(
      find.text('Social sign-in is not configured in this deployment.'),
      findsOneComponent,
    );
  });

  testComponents('empty submit surfaces field errors and alert', (
    tester,
  ) async {
    tester.pumpComponent(const LoginPage());

    final submit = find.ancestor(
      of: find.text('Sign in'),
      matching: find.tag('button'),
    );
    await tester.click(submit);

    expect(find.text('Enter a valid email address.'), findsOneComponent);
    expect(find.text('Password is required.'), findsOneComponent);
    expect(find.text('Please fix the highlighted fields.'), findsOneComponent);
  });
}
