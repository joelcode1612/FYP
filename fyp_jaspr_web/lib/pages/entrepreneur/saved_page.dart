import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/bloc.dart';
import '../../components/property_card.dart';
import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web saved shortlist: 3-column desktop grid.
///
/// Ported from `entrepreneur_saved_web_page.dart` in the Flutter web tree.
/// The list is filtered by the shared `AppLocator.appCubit` saved set, and
/// both Flutter empty states ("No saved properties" / "Shortlist is empty")
/// are preserved verbatim. Cards wire the bookmark toggle only — the Flutter
/// page passes no compare callback, so no compare button is rendered.
class SavedPage extends StatelessComponent {
  const SavedPage({super.key});

  @override
  Component build(BuildContext context) {
    final appCubit = AppLocator.appCubit;
    return CubitBuilder<AppCubit, AppState>(
      cubit: appCubit,
      builder: (context, _) {
        return AppLayout(
          role: AppRole.entrepreneur,
          currentRoute: '/entrepreneur/saved',
          title: 'Saved',
          subtitle: AppRole.entrepreneur.label,
          child: appCubit.saved.isEmpty
              ? const _Empty(
                  title: 'No saved properties',
                  message:
                      'Tap the bookmark on any listing to build your shortlist.',
                  withAction: true,
                )
              : FutureBuilder<List<CommercialProperty>>(
                  future: AppLocator.properties.listings(),
                  builder: (c, snap) {
                    if (!snap.hasData) return const _Loading();
                    final items = snap.data!
                        .where(
                          (property) => appCubit.saved.contains(property.id),
                        )
                        .toList();
                    if (items.isEmpty) {
                      return const _Empty(
                        title: 'Shortlist is empty',
                        message: 'Saved items were removed or are unavailable.',
                        withAction: false,
                      );
                    }
                    return div(classes: 'card-grid', [
                      for (final property in items)
                        PropertyCard(
                          property: property,
                          href:
                              '/entrepreneur/property-detail?id=${property.id}',
                          saved: true,
                          onToggleSaved: () =>
                              appCubit.toggleSaved(property.id),
                        ),
                    ]);
                  },
                ),
        );
      },
    );
  }
}

class _Loading extends StatelessComponent {
  const _Loading();

  @override
  Component build(BuildContext context) {
    return div(classes: 'card', [
      p(classes: 'body muted', [Component.text('Loading…')]),
    ]);
  }
}

class _Empty extends StatelessComponent {
  final String title;
  final String message;
  final bool withAction;

  const _Empty({
    required this.title,
    required this.message,
    required this.withAction,
  });

  @override
  Component build(BuildContext context) {
    return div(classes: 'card stack', [
      span(classes: 'overline', [Component.text('Saved')]),
      h2(classes: 'title-lg', [Component.text(title)]),
      p(classes: 'body', [Component.text(message)]),
      if (withAction)
        const ActionLink(
          'Explore properties',
          href: '/entrepreneur/explore',
          variant: 'secondary',
        ),
    ]);
  }
}
