import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../data/app_locator.dart';
import '../../layouts/app_layout.dart';

/// Web compare, laid out as the source's `compare.html`.
///
/// ```text
/// .page-head   "Compare" · "Compare N properties" · explanation
/// .notice      "add another" / "some records dropped" warnings
/// .panel       .compare-table  (field rows × property columns)
/// disclaimer
/// ```
///
/// The source table puts the property in the column header and the field names
/// down the left, with each cell labelled by state ("Not provided", "Data
/// unavailable"). The previous version used a generic `.table` with the property
/// city as the header and a flat "—" for every absent value, collapsing three
/// distinct states into one.
@client
class ComparePage extends StatelessComponent {
  const ComparePage({super.key});

  @override
  Component build(BuildContext context) {
    // The selection lives in the root provider scope (seeded from the cookie),
    // so the page needs no constructor argument and stays a plain encodable
    // client target.
    final compared = context.watch(
      appNotifierProvider.select((app) => app.compared),
    );
    return AppLayout(
      role: AppRole.entrepreneur,
      currentRoute: '/entrepreneur/compare',
      title: compared.isEmpty
          ? 'Compare properties'
          : 'Compare ${compared.length} '
                '${compared.length == 1 ? 'property' : 'properties'}',
      eyebrow: 'Compare',
      subtitle:
          'Identical fields side by side. "Not provided" and "Data '
          'unavailable" are labelled — a blank is never a better or worse '
          'result.',
      child: compared.isEmpty
          ? const _EmptyCompare()
          : FutureBuilder<List<CommercialProperty>>(
              future: AppLocator.properties.listings(),
              builder: (c, snap) {
                if (!snap.hasData) return const _Loading();
                final all = snap.data!;
                final items = all
                    .where((property) => compared.contains(property.id))
                    .toList();
                return _CompareBody(
                  items: items,
                  missing: compared.length - items.length,
                );
              },
            ),
    );
  }
}

class _Loading extends StatelessComponent {
  const _Loading();

  @override
  Component build(BuildContext context) => div(classes: 'loading', [
    span(classes: 'spinner', []),
    Component.text('Loading listings…'),
  ]);
}

class _EmptyCompare extends StatelessComponent {
  const _EmptyCompare();

  @override
  Component build(BuildContext context) => EmptyState(
    title: 'Nothing to compare yet',
    body:
        'Add at least two properties from Explore, your favourites or a '
        'recommendation run. Fields are shown side by side once two or more are '
        'selected.',
    action: const ActionLink(
      'Browse properties',
      href: '/entrepreneur/explore',
      variant: 'primary',
    ),
  );
}

class _CompareBody extends StatelessComponent {
  final List<CommercialProperty> items;

  /// Compared ids that are no longer in the listing set.
  final int missing;

  const _CompareBody({required this.items, this.missing = 0});

  static String _toneFor(VerificationStatus status) => switch (status) {
    VerificationStatus.verified => 'success',
    VerificationStatus.pending => 'warning',
    VerificationStatus.rejected => 'danger',
    VerificationStatus.draft => 'neutral',
  };

  @override
  Component build(BuildContext context) {
    return div(classes: 'stack stack--md', [
      if (items.length < 2)
        div(classes: 'notice notice-warn', [
          Component.text(
            'Add at least one more property for a useful comparison.',
          ),
        ]),
      if (missing > 0)
        div(classes: 'notice notice-warn', [
          Component.text(
            '$missing saved ${missing == 1 ? 'property is' : 'properties are'} '
            'no longer published and ${missing == 1 ? 'was' : 'were'} left out.',
          ),
        ]),
      div(classes: 'panel', [
        div(classes: 'table-scroll', [
          table(classes: 'compare-table', [
            thead([
              tr([
                th([Component.text('Field')]),
                for (final prop in items)
                  th([
                    Component.text(prop.title),
                    div(classes: 'small', [Component.text(prop.city)]),
                    div(classes: 'compare-remove', [
                      ActionButton(
                        'Remove',
                        variant: 'ghost',
                        onClick: () => context
                            .read(appNotifierProvider.notifier)
                            .toggleCompared(prop.id),
                      ),
                    ]),
                  ]),
              ]),
            ]),
            tbody([
              _row('Monthly rent', [
                for (final prop in items) prop.rentalDisplay,
              ]),
              _row('Floor area', [
                for (final prop in items)
                  '${prop.sizeSqft.toStringAsFixed(0)} sq ft',
              ]),
              _row('Property type', [
                for (final prop in items) prop.propertyType,
              ]),
              _row('Rental efficiency', [
                for (final prop in items)
                  'RM${prop.rentalPerSqft.toStringAsFixed(2)} / sq ft',
              ]),
              _nodeRow('Availability', [
                for (final prop in items)
                  StatusBadge(
                    prop.verification == VerificationStatus.verified
                        ? 'available'
                        : 'pending',
                    tone: prop.verification == VerificationStatus.verified
                        ? 'action'
                        : 'warning',
                  ),
              ]),
              _nodeRow('Verification', [
                for (final prop in items)
                  StatusBadge(
                    prop.verification.label,
                    tone: _toneFor(prop.verification),
                  ),
              ]),
              _row('Suitability score', [
                for (final prop in items)
                  '${prop.suitabilityScore.toStringAsFixed(0)}/100',
              ], emphasise: true),
              _row('360° tour', [
                for (final prop in items)
                  prop.hasTour ? 'Published' : 'Not available',
              ]),
              _nodeRow('Details', [
                for (final prop in items)
                  ActionLink(
                    'Open',
                    href: '/entrepreneur/property-detail?id=${prop.id}',
                    variant: 'secondary',
                  ),
              ]),
            ]),
          ]),
        ]),
      ]),
      p(classes: 'disclaimer', [
        Component.text(
          'A suitability score is a relative decision-support indicator. It is '
          'not a probability of business success, a revenue or customer-volume '
          'forecast, regulatory approval, or a guarantee of any kind.',
        ),
      ]),
      div(classes: 'actions-row', [
        ActionButton(
          'Clear comparison',
          variant: 'secondary',
          onClick: () =>
              context.read(appNotifierProvider.notifier).clearCompared(),
        ),
        const ActionLink(
          'Back to results',
          href: '/entrepreneur/explore',
          variant: 'secondary',
        ),
      ]),
    ]);
  }

  Component _row(String label, List<String> values, {bool emphasise = false}) =>
      tr([
        th(attributes: const {'scope': 'row'}, [Component.text(label)]),
        for (final v in values)
          td([
            if (emphasise) strong([Component.text(v)]) else Component.text(v),
          ]),
      ]);

  Component _nodeRow(String label, List<Component> values) => tr([
    th(attributes: const {'scope': 'row'}, [Component.text(label)]),
    for (final v in values) td([v]),
  ]);
}
