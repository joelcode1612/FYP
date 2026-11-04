/// User roles mirrored from the HTML prototype navigation.
enum AppRole { admin, owner, entrepreneur, agent }

extension AppRoleLabel on AppRole {
  String get label => switch (this) {
    AppRole.admin => 'Administrator',
    AppRole.owner => 'Property Owner',
    AppRole.entrepreneur => 'F&B Entrepreneur',
    AppRole.agent => 'Property Agent',
  };

  /// Initial route for the role shell.
  String get homeRoute => switch (this) {
    AppRole.admin => '/admin',
    AppRole.owner => '/owner',
    AppRole.entrepreneur => '/entrepreneur',
    AppRole.agent => '/agent',
  };

  /// Staff Portal (`agent`, `admin`) vs Public Portal (`entrepreneur`, `owner`).
  ///
  /// The two portals share every Sitewise component but not their permissions:
  /// staff workspaces are provisioned by an administrator and never offer a
  /// workspace switcher, so the flag also drives which shell chrome renders.
  bool get isStaff => this == AppRole.admin || this == AppRole.agent;

  String get portal => isStaff ? 'Staff Portal' : 'Public Portal';
}
