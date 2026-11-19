import 'dart:async';

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../components/ui.dart';
import '../../layouts/app_layout.dart';

/// Compare shortlisted properties by observable differences only.
///
/// This page NEVER calls the recommendation search, never computes an overall
/// score and never names a winner. It renders the batch result from
/// `POST /api/v1/compare`, which derives every sentence from verified
/// measurements of the selected properties themselves.
@client
class ComparePage extends StatefulComponent {
  const ComparePage({super.key});

  @override
  State<ComparePage> createState() => _ComparePageState();
}

class _ComparePageState extends State<ComparePage> {
  /// The selection we last sent, so a rebuild cannot queue duplicate reads.
  String _requestedIds = '';

  @override
  Component build(BuildContext context) {
    final compared = context.watch(
      appNotifierProvider.select((app) => app.compared),
    );
    final comparison = context.watch(propertyCompareProvider);
    final ids = compared.toList();
    final signature = ids.join('|');

    if (signature != _requestedIds) {
      _requestedIds = signature;
      Future.microtask(() {
        context.read(propertyCompareProvider.notifier).load(ids);
      });
    }

    return AppLayout(
      role: AppRole.entrepreneur,
      currentRoute: '/entrepreneur/compare',
      title: 'Compare your shortlisted properties',
      eyebrow: 'Compare',
      subtitle:
          'Objective differences between up to three properties you selected. '
          'No overall score, no winner — the decision stays with you.',
      child: div(classes: 'cmp', [
        _topBar(ids.length),
        if (ids.isEmpty)
          EmptyState(
            title: 'Nothing to compare yet',
            body: 'Add two or three properties from Recommendations, then '
                'return here to see their measured differences.',
            action: const ActionLink(
              'Back to Recommendations',
              href: '/entrepreneur/recommendations',
              variant: 'primary',
            ),
          )
        else if (ids.length < 2)
          div(classes: 'notice notice-warn', [
            Component.text(
              'One property selected. Add another from Recommendations for a '
              'side-by-side comparison.',
            ),
          ]),
        if (comparison.error != null)
          div(classes: 'notice notice-warn', [
            Component.text(comparison.error!),
            ActionButton(
              'Retry',
              variant: 'secondary',
              onClick: () => context
                  .read(propertyCompareProvider.notifier)
                  .load(ids, refresh: true),
            ),
          ]),
        if (comparison.loading && comparison.data == null)
          div(classes: 'loading', [
            span(classes: 'spinner', []),
            Component.text('Loading the selected properties…'),
          ]),
        if (comparison.data case final result?)
          _body(context, result, ids.length),
      ]),
    );
  }

  Component _topBar(int count) => div(classes: 'cmp__top', [
    div(classes: 'cmp__count', [
      Component.text('$count of 3 selected'),
    ]),
    const ActionLink(
      'Back to Recommendations',
      href: '/entrepreneur/recommendations',
      variant: 'secondary',
    ),
  ]);

  Component _body(
    BuildContext context,
    PropertyCompareResult result,
    int selectedCount,
  ) {
    final properties = result.properties;
    if (properties.isEmpty) return Component.fragment([]);

    return div(classes: 'cmp__stack', [
      if (result.unresolvedIds.isNotEmpty)
        div(classes: 'notice notice-warn', [
          Component.text(
            '${result.unresolvedIds.length} selected '
            '${result.unresolvedIds.length == 1 ? 'property was' : 'properties were'} '
            'not found in the property catalogue and were left out.',
          ),
        ]),
      if (selectedCount > result.resolvedCount)
        div(classes: 'notice notice-warn', [
          Component.text('Add at least two available properties to compare.'),
        ]),
      _overview(context, properties),
      _keyDifferences(result),
      _category(
        'Cost & space',
        properties,
        const [
          'monthly_rent_rm',
          'size_sqft',
          'rent_per_sqft',
          'floor_level_text',
          'has_parking',
        ],
        result,
      ),
      _category(
        'Location & accessibility',
        properties,
        const [
          'population_500m',
          'population_1000m',
          'nearest_transit_walk_m',
          'bus_stops_500m_walk',
          'walk_isochrone_area_10min_km2',
          'parking_facilities_500m',
          'office_pois_500m',
          'universities_count_500m',
          'malls_count_500m',
        ],
        result,
      ),
      _category(
        'Nearby F&B competition',
        properties,
        const [
          'fnb_competitors_500m',
          'fnb_competitors_1000m',
          'cafe_count_500m',
          'restaurant_count_500m',
          'nearest_competitor_distance_m',
        ],
        result,
      ),
      _tradeoffs(result),
      _detailTable(properties, result),
      div(classes: 'cmp__notes', [
        for (final note in result.notes)
          p([Component.text(note)]),
        p(classes: 'cmp__context', [
          Component.text(
            'Research association index is supporting context only: an '
            'uncalibrated 0–100 research measure, not a success probability '
            'and not used to order this comparison.',
          ),
        ]),
      ]),
      div(classes: 'cmp__actions', [
        ActionButton(
          'Clear comparison',
          variant: 'secondary',
          onClick: () {
            context.read(appNotifierProvider.notifier).clearCompared();
            context.read(propertyCompareProvider.notifier).reset();
          },
        ),
        const ActionLink(
          'Back to Recommendations',
          href: '/entrepreneur/recommendations',
          variant: 'secondary',
        ),
      ]),
    ]);
  }

  /// Section A — property cards in one horizontal row.
  Component _overview(BuildContext context, List<CompareProperty> properties) =>
      div(classes: 'cmp__section', [
        h2([Component.text('Property overview')]),
        div(classes: 'cmp__cards', [
          for (final property in properties)
            div(classes: 'cmp__card', [
              if (property.imageUrl != null && property.imageUrl!.isNotEmpty)
                img(
                  src: property.imageUrl!,
                  attributes: {
                    'alt': property.title,
                    'loading': 'lazy',
                  },
                  classes: 'cmp__card-img',
                )
              else
                div(classes: 'cmp__card-noimg', [
                  Component.text('No property photo'),
                ]),
              div(classes: 'cmp__card-body', [
                h3([Component.text(property.title)]),
                p([Component.text(property.location)]),
                div(classes: 'cmp__card-facts', [
                  span([Component.text(property.propertyType)]),
                  span([
                    Component.text(
                      property.metric('monthly_rent_rm').display,
                    ),
                  ]),
                  span([Component.text(property.metric('size_sqft').display)]),
                ]),
                if (property.availabilityConfirmed)
                  span(classes: 'cmp__tag cmp__tag--ok', [
                    Component.text('Availability confirmed'),
                  ])
                else
                  span(classes: 'cmp__tag', [
                    Component.text('Availability not confirmed'),
                  ]),
                if (property.panoramaAvailable)
                  span(classes: 'cmp__tag', [Component.text('360° tour ready')]),
                div(classes: 'cmp__card-actions', [
                  ActionLink(
                    'View details',
                    href: '/entrepreneur/property-detail?id=${Uri.encodeComponent(property.id)}',
                    variant: 'secondary',
                  ),
                  ActionButton(
                    'Remove',
                    variant: 'ghost',
                    onClick: () => context
                        .read(appNotifierProvider.notifier)
                        .toggleCompared(property.id),
                  ),
                ]),
              ]),
            ]),
        ]),
      ]);

  /// Section E — factual labels only, followed by measured trade-offs.
  Component _keyDifferences(PropertyCompareResult result) =>
      div(classes: 'cmp__section', [
        h2([Component.text('Key differences')]),
        if (result.insights.isEmpty)
          p([Component.text('Not enough comparable evidence for a summary.')])
        else
          div(classes: 'cmp__insights', [
            for (final insight in result.insights)
              div(classes: 'cmp__insight', [
                h3([Component.text(insight.title)]),
                ul([
                  for (final point in insight.points)
                    li([Component.text(point)]),
                ]),
              ]),
          ]),
        div(classes: 'cmp__diffs', [
          for (final difference in result.differences)
            p([Component.text(difference.sentence)]),
        ]),
      ]);

  Component _category(
    String title,
    List<CompareProperty> properties,
    List<String> keys,
    PropertyCompareResult result,
  ) {
    final rows = <Component>[];
    for (final key in keys) {
      final metric = properties.first.metric(key);
      final values = [
        for (final property in properties) property.metric(key),
      ];
      final available = values.where((item) => item.available).toList();
      final max = available.isEmpty
          ? null
          : available
              .map((item) => item.value?.toDouble() ?? 0)
              .reduce((low, high) => low > high ? low : high);
      rows.add(div(classes: 'cmp__row', [
        div(classes: 'cmp__row-label', [
          Component.text(metric.caption),
          if (metric.unit.isNotEmpty)
            span(classes: 'cmp__unit', [Component.text(metric.unit)]),
        ]),
        for (final value in values)
          div(classes: 'cmp__row-cell', [
            span([Component.text(value.display)]),
            if (value.available &&
                max != null &&
                max > 0 &&
                value.value != null &&
                metric.unit.isNotEmpty)
              div(classes: 'cmp__bar-track', [
                div(
                  classes: 'cmp__bar',
                  attributes: {
                    'style': 'width: ${((value.value!.toDouble() / max) * 100).round()}%',
                  },
                  [],
                ),
              ]),
          ]),
      ]));
    }
    return div(classes: 'cmp__section', [
      h2([Component.text(title)]),
      div(classes: 'cmp__grid', [
        div(classes: 'cmp__row cmp__row--head', [
          div(classes: 'cmp__row-label', [Component.text('Measurement')]),
          for (final property in properties)
            div(classes: 'cmp__row-cell', [Component.text(property.title)]),
        ]),
        ...rows,
      ]),
      if (title == 'Nearby F&B competition')
        p(classes: 'cmp__hint', [
          Component.text(
            'Counts use the same source and radius for every property. Fewer '
            'recorded competitors does not mean better demand — it can also '
            'mean a less established area.',
          ),
        ]),
    ]);
  }

  Component _tradeoffs(PropertyCompareResult result) =>
      div(classes: 'cmp__section', [
        h2([Component.text('Key trade-offs')]),
        for (final tradeoff in result.tradeoffs)
          div(classes: 'cmp__tradeoff', [Component.text(tradeoff.text)]),
      ]);

  Component _detailTable(
    List<CompareProperty> properties,
    PropertyCompareResult result,
  ) {
    const keys = [
      'monthly_rent_rm',
      'size_sqft',
      'rent_per_sqft',
      'floor_level_text',
      'has_parking',
      'population_500m',
      'population_1000m',
      'nearest_transit_walk_m',
      'bus_stops_500m_walk',
      'walk_isochrone_area_10min_km2',
      'parking_facilities_500m',
      'office_pois_500m',
      'universities_count_500m',
      'malls_count_500m',
      'fnb_competitors_500m',
      'fnb_competitors_1000m',
      'cafe_count_500m',
      'restaurant_count_500m',
      'fast_food_count_500m',
      'nearest_competitor_distance_m',
    ];
    return div(classes: 'cmp__section', [
      h2([Component.text('Detailed comparison')]),
      div(classes: 'table-scroll', [
        table(classes: 'compare-table', [
          thead([
            tr([
              th([Component.text('Measurement')]),
              for (final property in properties)
                th([Component.text(property.title)]),
            ]),
          ]),
          tbody([
            for (final key in keys)
              tr([
                th(attributes: const {'scope': 'row'}, [
                  Component.text(properties.first.metric(key).caption),
                ]),
                for (final property in properties)
                  td([Component.text(property.metric(key).display)]),
              ]),
            tr([
              th(attributes: const {'scope': 'row'}, [
                Component.text('PU research index (context only)'),
              ]),
              for (final property in properties)
                td([
                  Component.text(
                    property.researchIndexAvailable
                        ? '${property.researchIndex?.toStringAsFixed(0)} / 100'
                        : 'Data not available',
                  ),
                ]),
            ]),
          ]),
        ]),
      ]),
    ]);
  }
}
