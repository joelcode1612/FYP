import 'package:jaspr/jaspr.dart';
import 'staff_security_flow.dart';

/// First-time TOTP enrollment. The flow verifies the real Supabase factor.
@client
class StaffMfaPage extends StatelessComponent {
  const StaffMfaPage({super.key});

  @override
  Component build(BuildContext context) => const StaffSecurityFlow(enrollment: true);
}
