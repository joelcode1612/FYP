import 'package:jaspr/jaspr.dart';
import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/components/staff_security_shell.dart';

/// Task-1/F3 regression: the staff MFA shell renders its own branded header —
/// never the public auth navbar. Sign in / Sign up chrome must not reappear.
void main() {
  testComponents('staff shell keeps public section links and no auth chrome', (
    tester,
  ) async {
    tester.pumpComponent(StaffSecurityShell(card: Component.text('x')));

    // Branded header + public anchors + secure chip.
    expect(find.text('SITEWISE'), findsOneComponent);
    expect(find.text('Problem & solution'), findsOneComponent);
    expect(find.text('Explore'), findsOneComponent);
    expect(find.text('Recommendations'), findsOneComponent);
    expect(find.text('SECURE STAFF VERIFICATION'), findsOneComponent);

    // No Sign in / Sign up anywhere in the shell.
    expect(find.text('Sign in'), findsNothing);
    expect(find.text('Sign up'), findsNothing);
    expect(find.text('Sign in to SiteWise'), findsNothing);
  });
}