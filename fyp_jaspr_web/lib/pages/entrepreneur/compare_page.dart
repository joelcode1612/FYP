import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/bloc.dart';
import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web compare: desktop comparison table (up to 3 properties).
///
/// Ported from `entrepreneur_compare_web_page.dart` in the Flutter web tree.
/// The Flutter version rebuilds on `AppCubit` and pulls listings through
/// `ServiceLocator.properties`; this version rebuilds on the shared
/// `AppLocator.appCubit` via [CubitBuilder] and reads the same shared service.
/// Detail ids travel as `?id=` query params instead of `settings.arguments`.
class ComparePage extends StatelessComponent {
  final AppCubit appCubit;
  const ComparePage({super.key, required this.appCubit});

  @override
  Component build(BuildContext context) {
    return CubitBuilder<AppCubit, AppState>(
      cubit: appCubit,
      builder: (ctx, _) {
        final compared = appCubit.compared;
        return AppLayout(
          role: AppRole.entrepreneur,
          currentRoute: '/entrepreneur/compare',
          title: 'Compare',
          subtitle: AppRole.entrepreneur.label,
          child: compared.isEmpty
              ? _EmptyCompare()
              : FutureBuilder<List<CommercialProperty>>(
                  future: AppLocator.properties.listings(),
                  builder: (c, snap) {
                    if (!snap.hasData) return _Loading();
                    final items = snap.data!
                        .where((property) => compared.contains(property.id))
                        .toList();
                    return _CompareBody(items: items, appCubit: appCubit);
                  },
                ),
        );
      },
    );
  }
}

class _Loading extends StatelessComponent {
  @override
  Component build(BuildContext context) {
    return div(classes: 'card', [
      p(classes: 'body muted', [Component.text('Loading listings…')]),
    ]);
  }
}

class _EmptyCompare extends StatelessComponent {
  @override
  Component build(BuildContext context) {
    return div(classes: 'card stack', [
      span(classes: 'overline', [Component.text('Compare')]),
      h2(classes: 'title-lg', [Component.text('Nothing to compare')]),
      p(classes: 'body', [
        Component.text(
          'Add up to 3 properties from Explore or Recommendations.',
        ),
      ]),
      const ActionLink(
        'Explore properties',
        href: '/entrepreneur/explore',
        variant: 'secondary',
      ),
    ]);
  }
}

class _CompareBody extends StatelessComponent {
  final List<CommercialProperty> items;
  final AppCubit appCubit;
  const _CompareBody({required this.items, required this.appCubit});

  @override
  Component build(BuildContext context) {
    return div(classes: 'stack', [
      div(classes: 'card', [
        div(classes: 'table-scroll', [
          table(classes: 'table', [
            thead([
              tr([
                th([Component.text('Metric')]),
                for (final property in items)
                  th([Component.text(property.city)]),
              ]),
            ]),
            tbody([
              _row(
                'Property',
                items.map((property) => property.title).toList(),
              ),
              _row(
                'Rental',
                items
                    .map(
                      (property) => 'RM${property.rentalRm.toStringAsFixed(0)}',
                    )
                    .toList(),
              ),
              _row(
                'Size',
                items
                    .map(
                      (property) =>
                          '${property.sizeSqft.toStringAsFixed(0)} sq ft',
                    )
                    .toList(),
              ),
              _row(
                'RM / sq ft',
                items
                    .map(
                      (property) =>
                          'RM${property.rentalPerSqft.toStringAsFixed(2)}',
                    )
                    .toList(),
              ),
              _row(
                'Suitability',
                items
                    .map(
                      (property) =>
                          '${property.suitabilityScore.toStringAsFixed(0)}/100',
                    )
                    .toList(),
                highlight: true,
              ),
              _row(
                'Status',
                items.map((property) => property.verification.label).toList(),
              ),
              _row(
                '360° tour',
                items
                    .map((property) => property.hasTour ? 'Yes' : '—')
                    .toList(),
              ),
            ]),
          ]),
        ]),
      ]),
      div(classes: 'row', [
        ActionButton(
          'Clear',
          variant: 'secondary',
          onClick: appCubit.clearCompared,
        ),
        if (items.isNotEmpty)
          ActionLink(
            'Open first detail',
            href: '/entrepreneur/property-detail?id=${items.first.id}',
          ),
      ]),
    ]);
  }

  Component _row(String metric, List<String> values, {bool highlight = false}) {
    return tr(classes: highlight ? 'table__row--highlight' : null, [
      td(classes: 'table__metric', [Component.text(metric)]),
      for (final v in values) td([Component.text(v)]),
    ]);
  }
}
