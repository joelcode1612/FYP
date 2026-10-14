/// User roles mirrored from the HTML prototype navigation.
enum AppRole { admin, owner, entrepreneur }

extension AppRoleLabel on AppRole {
  String get label => switch (this) {
    AppRole.admin => 'Administrator',
    AppRole.owner => 'Property Owner',
    AppRole.entrepreneur => 'F&B Entrepreneur',
  };

  /// Initial route for the role shell.
  String get homeRoute => switch (this) {
    AppRole.admin => '/admin',
    AppRole.owner => '/owner',
    AppRole.entrepreneur => '/entrepreneur',
  };
}
