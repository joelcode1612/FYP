import 'package:jaspr/jaspr.dart';
import 'staff_security_flow.dart';

/// Returning Agent/Admin TOTP challenge; never accepts unverified passwords.
@client
class StaffVerifyPage extends StatelessComponent {
  const StaffVerifyPage({super.key});

  @override
  Component build(BuildContext context) => const StaffSecurityFlow();
}
