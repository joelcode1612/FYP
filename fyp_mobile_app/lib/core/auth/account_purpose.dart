/// The two account *purposes* offered by the mobile registration flow.
///
/// This is deliberately NOT the backend role model. SiteWise's authoritative
/// roles remain `entrepreneur`, `agent` and `admin`, and are provisioned only
/// by the backend (`GET /api/v1/auth/me` reads the local profile row, never
/// token metadata). Choosing [ownerAgent] here is a statement of intent for
/// onboarding: it grants no ownership, no agency authorisation and no
/// publication permission. Those are verified separately in the Add Property
/// workflow. There is intentionally no `admin` purpose — nobody may
/// self-register as an administrator.
///
/// The [wireValue] is stored in Supabase `user_metadata` under
/// [metadataKey] so the choice survives the email-verification and Google
/// OAuth flows. It is a preference string, not a role claim, and must never be
/// used by a client or endpoint to decide what a user may do.
enum AccountPurpose {
  entrepreneur('entrepreneur'),
  ownerAgent('listing_provider');

  const AccountPurpose(this.wireValue);

  /// Non-authoritative metadata value sent to Supabase.
  final String wireValue;

  static const String metadataKey = 'account_purpose';

  String get label => switch (this) {
    AccountPurpose.entrepreneur => 'Entrepreneur',
    AccountPurpose.ownerAgent => 'Property Owner / Agent',
  };

  String get description => switch (this) {
    AccountPurpose.entrepreneur =>
      'Find and evaluate suitable F&B commercial locations with AI '
          'recommendations.',
    AccountPurpose.ownerAgent => 'List and manage commercial properties.',
  };
}
