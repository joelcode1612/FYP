import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'ui.dart';

/// One entry in an [AppBreadcrumbs] trail.
///
/// `route` is the Sitewise path the crumb links to (rendered as an
/// [AppLink], so it crawls as a real anchor and upgrades to client-side
/// navigation). A `null` route marks the current page: it renders as plain
/// emphasised text carrying `aria-current="page"`, because linking to the
/// page the reader is already on is noise, not navigation.
class BreadcrumbItem {
  final String label;
  final String? route;

  const BreadcrumbItem({required this.label, this.route});

  /// Convenience for the current (last) crumb.
  const BreadcrumbItem.current(String label) : this(label: label);
}

/// The global breadcrumb trail rendered by [AppLayout] on every
/// authenticated page, directly below the sticky pill nav.
///
/// Semantics follow the WAI-ARIA breadcrumbs pattern: a `<nav>` landmark
/// labelled "Breadcrumb" wrapping an ordered list, with `aria-current="page"`
/// on the final item. Two or fewer entries carry no information a single
/// link would not, so the component renders nothing for short trails (the
/// workspace home pages).
///
/// Visual language: royal-blue links (`#1D4ED8`) matching the action colour
/// of the light workspaces, with the current page in ink. The stylesheet
/// (`web/styles.css`, `.app-crumbs`) re-tints the trail on the dark admin and
/// owner shells for contrast.
class AppBreadcrumbs extends StatelessComponent {
  final List<BreadcrumbItem> items;

  const AppBreadcrumbs(this.items, {super.key});

  @override
  Component build(BuildContext context) {
    // "Home" alone says nothing the brand mark does not already say; a trail
    // only becomes wayfinding once there is at least one ancestor to click.
    if (items.length < 2) return const Component.fragment([]);

    return nav(
      classes: 'app-crumbs',
      attributes: const {'aria-label': 'Breadcrumb'},
      [
        ol(classes: 'app-crumbs__list', [
          for (var i = 0; i < items.length; i++)
            li(classes: 'app-crumbs__item', [
              if (i > 0)
                span(
                  classes: 'app-crumbs__sep',
                  attributes: const {'aria-hidden': 'true'},
                  [Component.text('›')],
                ),
              if (i < items.length - 1 && items[i].route != null)
                AppLink(
                  to: items[i].route!,
                  classes: 'app-crumbs__link',
                  children: [Component.text(items[i].label)],
                )
              else
                span(
                  classes: 'app-crumbs__current',
                  attributes: const {'aria-current': 'page'},
                  [Component.text(items[i].label)],
                ),
            ]),
        ]),
      ],
    );
  }
}
