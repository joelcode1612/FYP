import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../data/app_locator.dart';
import '../data/auth_service.dart';
import 'ui.dart';

/// Header controls ported from the Flutter web tree's
/// `web_topbar.dart`: listing search, the notification bell and the avatar
/// menu (profile + demo role switch).
///
/// Behavioural notes:
/// * Dialogs/panels start closed, so the static server render contains only
///   the buttons; data futures run in the browser once opened.
/// * Navigation uses plain links (`?id=` query params), so every result works
///   without JavaScript.
/// * Role switching is navigation to the other role's home route. The role
///   displayed comes from the URL (see `roleForPath`), not from mutable
///   client state, so the sidebar and the page always agree after a switch.

String detailRouteFor(AppRole role) => switch (role) {
  AppRole.admin => '/admin/listing-detail',
  AppRole.owner => '/owner/property-detail',
  AppRole.entrepreneur => '/entrepreneur/property-detail',
};

String profileRouteFor(AppRole role) => switch (role) {
  AppRole.admin => '/admin/profile',
  AppRole.owner => '/owner/profile',
  AppRole.entrepreneur => '/entrepreneur/profile',
};

({String name, String email}) profileFor(AppRole role) => switch (role) {
  AppRole.admin => (name: 'Aina Razak', email: 'aina@sitewise.my'),
  AppRole.owner => (name: 'Daniel Wong', email: 'daniel@wongproperties.my'),
  AppRole.entrepreneur => (name: 'Sarah Lim', email: 'sarah@nasihouse.my'),
};

/// The three header controls, rendered in the topbar's right-hand slot.
class TopbarControls extends StatelessComponent {
  final AppRole role;

  const TopbarControls({super.key, required this.role});

  @override
  Component build(BuildContext context) {
    return div(classes: 'topbar__controls', [
      SearchControl(role: role),
      NotificationControl(role: role),
      AvatarMenu(role: role),
    ]);
  }
}

// --- Search -------------------------------------------------------------------

class SearchControl extends StatefulComponent {
  final AppRole role;
  const SearchControl({super.key, required this.role});

  @override
  State<SearchControl> createState() => SearchControlState();
}

class SearchControlState extends State<SearchControl> {
  bool _open = false;
  String _query = '';

  @override
  Component build(BuildContext context) {
    return div([
      button(
        classes: 'icon-btn',
        attributes: const {
          'type': 'button',
          'aria-label': 'Search listings',
          // W-01: tell assistive tech this opens a dialog, and whether it is open.
          'aria-haspopup': 'dialog',
        },
        events: events(onClick: () => setState(() => _open = true)),
        [Icon('search')],
      ),
      if (_open)
        div(
          classes: 'overlay',
          events: events(onClick: () => setState(() => _open = false)),
          [
            // Stop clicks inside the dialog from closing the overlay.
            // W-01: role/aria-modal make it an actual modal dialog; the Escape
            // handler on the container is what lets a keyboard user leave it.
            div(
              classes: 'dialog dialog--wide',
              attributes: const {
                'role': 'dialog',
                'aria-modal': 'true',
                'aria-label': 'Search listings',
              },
              events: {
                ...events(onClick: () {}),
                'keydown': (event) {
                  final key = (event as dynamic).key;
                  if (key == 'Escape' || key == 'Esc') {
                    setState(() => _open = false);
                  }
                },
              },
              [
                div(classes: 'dialog__head', [
                  input(
                    type: InputType.text,
                    classes: 'input',
                    attributes: {
                      'placeholder': 'Search locations, areas, listings…',
                      // Move focus into the panel on open — the W-01 defect was
                      // that focus stayed on the trigger and Tab walked behind
                      // the overlay.
                      'autofocus': '',
                    },
                    events: events<String>(
                      onInput: (value) => setState(() => _query = value),
                    ),
                  ),
                  button(
                    classes: 'icon-btn',
                    attributes: {'type': 'button', 'aria-label': 'Close'},
                    events: events(
                      onClick: () => setState(() => _open = false),
                    ),
                    [Component.text('✕')],
                  ),
                ]),
                _SearchResults(query: _query, role: component.role),
              ],
            ),
          ],
        ),
    ]);
  }
}

class _SearchResults extends StatelessComponent {
  final String query;
  final AppRole role;
  const _SearchResults({required this.query, required this.role});

  @override
  Component build(BuildContext context) {
    return FutureBuilder<List<CommercialProperty>>(
      future: AppLocator.properties.listings(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return div(classes: 'dialog__loading', [
            Component.text('Loading listings…'),
          ]);
        }
        final q = query.toLowerCase();
        final items = snapshot.data!
            .where(
              (property) =>
                  q.isEmpty ||
                  '${property.title} ${property.city} ${property.address}'
                      .toLowerCase()
                      .contains(q),
            )
            .toList();
        if (items.isEmpty) {
          return div(classes: 'dialog__empty', [Component.text('No matches.')]);
        }
        final detail = detailRouteFor(role);
        return ul(classes: 'result-list', [
          for (final property in items)
            li([
              AppLink(
                to: '$detail?id=${property.id}',
                classes: 'result-list__item',
                children: [
                  div(classes: 'grow', [
                    div(classes: 'result-list__title', [
                      Component.text(property.title),
                    ]),
                    div(classes: 'small muted', [
                      Component.text(
                        '${property.city} · ${property.rentalDisplay}',
                      ),
                    ]),
                  ]),
                  div(classes: 'metric text-action', [
                    Component.text(
                      property.suitabilityScore.toStringAsFixed(0),
                    ),
                  ]),
                ],
              ),
            ]),
        ]);
      },
    );
  }
}

// --- Notifications ------------------------------------------------------------

class NotificationControl extends StatefulComponent {
  final AppRole role;
  const NotificationControl({super.key, required this.role});

  @override
  State<NotificationControl> createState() => NotificationControlState();
}

class NotificationControlState extends State<NotificationControl> {
  bool _open = false;

  String get _panelTitle => switch (component.role) {
    AppRole.admin => 'Verification queue',
    AppRole.owner => 'Your listings',
    AppRole.entrepreneur => 'Top picks for you',
  };

  Future<List<({String title, String subtitle, String id, String route})>>
  _items() async {
    switch (component.role) {
      case AppRole.admin:
        final queue = await AppLocator.verification.queue();
        return [
          for (final p in queue.take(5))
            (
              title: p.title,
              subtitle: '${p.city} · ${p.rentalDisplay}',
              id: p.id,
              route: '/admin/verification-detail',
            ),
        ];
      case AppRole.owner:
        final items = await AppLocator.properties.ownerListings(
          DemoData.demoOwnerId,
        );
        return [
          for (final p in items.take(5))
            (
              title: p.title,
              subtitle: p.verification.label,
              id: p.id,
              route: '/owner/property-detail',
            ),
        ];
      case AppRole.entrepreneur:
        final recs = await AppLocator.recommendations.ranked(
          AppLocator.preferences,
        );
        return [
          for (final r in recs.take(5))
            (
              title: r.property.title,
              subtitle: r.reason,
              id: r.property.id,
              route: '/entrepreneur/property-detail',
            ),
        ];
    }
  }

  @override
  Component build(BuildContext context) {
    return div([
      button(
        classes: 'icon-btn',
        attributes: {
          'type': 'button',
          'aria-label': _panelTitle,
          'aria-haspopup': 'dialog',
        },
        events: events(onClick: () => setState(() => _open = true)),
        [Icon('notifications')],
      ),
      if (_open)
        div(
          classes: 'overlay',
          events: events(onClick: () => setState(() => _open = false)),
          [
            div(
              classes: 'dialog',
              attributes: {
                'role': 'dialog',
                'aria-modal': 'true',
                'aria-label': _panelTitle,
              },
              events: {
                ...events(onClick: () {}),
                'keydown': (event) {
                  final key = (event as dynamic).key;
                  if (key == 'Escape' || key == 'Esc') {
                    setState(() => _open = false);
                  }
                },
              },
              [
                div(classes: 'dialog__title', [Component.text(_panelTitle)]),
                _NotificationList(future: _items(), role: component.role),
              ],
            ),
          ],
        ),
    ]);
  }
}

class _NotificationList extends StatelessComponent {
  final Future<List<({String title, String subtitle, String id, String route})>>
  future;
  final AppRole role;
  const _NotificationList({required this.future, required this.role});

  @override
  Component build(BuildContext context) {
    return FutureBuilder<
      List<({String title, String subtitle, String id, String route})>
    >(
      future: future,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return div(classes: 'dialog__loading', [Component.text('Loading…')]);
        }
        if (snapshot.data!.isEmpty) {
          return div(classes: 'dialog__empty', [
            Component.text('Nothing needs attention.'),
          ]);
        }
        return ul(classes: 'result-list', [
          for (final item in snapshot.data!)
            li([
              AppLink(
                to: '${item.route}?id=${item.id}',
                classes: 'result-list__item',
                children: [
                  div(classes: 'grow', [
                    div(classes: 'result-list__title', [
                      Component.text(item.title),
                    ]),
                    div(classes: 'small muted', [
                      Component.text(item.subtitle),
                    ]),
                  ]),
                  span(classes: 'ms', [Component.text('chevron_right')]),
                ],
              ),
            ]),
        ]);
      },
    );
  }
}

// --- Avatar menu --------------------------------------------------------------

class AvatarMenu extends StatefulComponent {
  final AppRole role;
  const AvatarMenu({super.key, required this.role});

  @override
  State<AvatarMenu> createState() => AvatarMenuState();
}

class AvatarMenuState extends State<AvatarMenu> {
  bool _open = false;

  @override
  Component build(BuildContext context) {
    final account = WebAuth.profile;
    final profile = account == null
        ? profileFor(component.role)
        : (
            name: account['display_name'] as String,
            email: account['email'] as String,
          );
    return div(classes: 'avatar-menu', [
      button(
        classes: 'avatar-menu__trigger',
        attributes: {
          'type': 'button',
          'aria-label': profile.name,
          'aria-haspopup': 'true',
        },
        events: events(onClick: () => setState(() => _open = !_open)),
        [
          div(classes: 'avatar', [
            Component.text(profile.name.substring(0, 1)),
          ]),
          span(classes: 'ms ms--sm muted', [
            Component.text('keyboard_arrow_down'),
          ]),
        ],
      ),
      if (_open)
        div(
          classes: 'overlay overlay--menu',
          events: events(onClick: () => setState(() => _open = false)),
          [
            div(
              classes: 'menu',
              attributes: const {
                'role': 'dialog',
                'aria-modal': 'true',
                'aria-label': 'Account menu',
              },
              events: {
                ...events(onClick: () {}),
                'keydown': (event) {
                  final key = (event as dynamic).key;
                  if (key == 'Escape' || key == 'Esc') {
                    setState(() => _open = false);
                  }
                },
              },
              [
                div(classes: 'menu__head', [
                  div(classes: 'menu__name', [Component.text(profile.name)]),
                  div(classes: 'small muted', [
                    Component.text(
                      '${profile.email} · ${component.role.label}',
                    ),
                  ]),
                ]),
                div(classes: 'menu__divider', []),
                AppLink(
                  to: profileRouteFor(component.role),
                  classes: 'menu__item',
                  children: [Component.text('View profile')],
                ),
                div(classes: 'menu__divider', []),
                for (final role in AppRole.values.where(
                  (role) => role.name == account?['role'],
                ))
                  AppLink(
                    to: role.homeRoute,
                    classes:
                        'menu__item${role == component.role ? ' menu__item--current' : ''}',
                    children: [
                      Component.text(
                        '${role.label}${role == component.role ? ' ✓' : ''}',
                      ),
                    ],
                  ),
                button(
                  classes: 'menu__item',
                  events: events(
                    onClick: () async {
                      await WebAuth.signout();
                    },
                  ),
                  [Component.text('Sign out')],
                ),
              ],
            ),
          ],
        ),
    ]);
  }
}
