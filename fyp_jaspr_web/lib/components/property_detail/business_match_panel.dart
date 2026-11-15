import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../data/location_evidence_api.dart';
import '../../data/metric_format.dart';
import '../../data/preference_labels.dart';
import '../../data/property_insights_api.dart';
import '../ui.dart';

/// The "Your business & this property" presentation.
///
/// Two coordinated views driven by the SAME context:
/// * [BusinessMatchHero] — the section above the tabs: the selected business,
///   the saved recommendation match (ring + bar) and measured quick facts.
/// * [BusinessMatchDetail] — tab 1: reasons to consider the location and
///   things to check in person.
///
/// Data honesty rules encoded here:
/// * The match score is ONLY the saved Layer 2 result's final score, carried
///   by the `?result=` context. It is never derived from the PU location
///   score, and when no result context exists the hero says the personalised
///   match is unavailable instead of inventing a number.
/// * Evidence-based reasons describe recorded measurements; they are support
///   material, never claimed as model contributions.
/// * A missing measurement renders "Not available", never zero.
class BusinessMatchHero extends StatelessComponent {
  /// The persisted recommendation explanation, or null when the page was
  /// opened without a result context (or it failed to load).
  final PersonalisedExplanation? explanation;

  /// True while the explanation request is still in flight.
  final bool loading;

  final PropertyEvidence? evidence;
  final CommercialProperty property;

  /// The resolved insights payload, when the location analysis answered. Its
  /// `feature_coverage` block drives the model-input availability strip; the
  /// counts always come from the backend, never a hardcoded total.
  final PropertyInsights? insights;

  /// Whether the expandable "View all location details" list is open. The
  /// state lives on the page (the `@client` boundary) so this panel stays
  /// stateless, matching the SHAP chart's disclosure pattern.
  final bool detailsOpen;
  final void Function()? onToggleDetails;

  const BusinessMatchHero({
    super.key,
    required this.property,
    this.explanation,
    this.loading = false,
    this.evidence,
    this.insights,
    this.detailsOpen = false,
    this.onToggleDetails,
  });

  bool get _hasContext => explanation != null;

  /// The saved final score as a 0-100 integer, or null when unavailable.
  /// Layer 2 scores are proportions in [0,1]; a value already above 1 is
  /// treated as already-scaled only up to 100, and anything else is refused.
  int? get _matchPercent {
    final raw = explanation?.finalScore;
    if (raw == null) return null;
    if (raw < 0 || raw > 100) return null;
    final pct = raw <= 1 ? raw * 100 : raw;
    return pct.round();
  }

  @override
  Component build(BuildContext context) {
    final business = _BusinessDisplay.of(explanation);
    final match = _matchPercent;
    final featureBlock = _featureAvailability(insights);

    return section(
      classes: 'sw-match',
      attributes: const {'aria-labelledby': 'sw-match-title'},
      [
        div(classes: 'sw-match__intro', [
          div([
            span(classes: 'sw-match__eyebrow', [
              Component.text('Your business & this property'),
            ]),
            h2(
              classes: 'sw-match__title',
              attributes: const {'id': 'sw-match-title'},
              [Component.text('Why this property matches your business')],
            ),
            p(classes: 'sw-match__lede', [
              Component.text(
                'See how the surroundings, rent and accessibility may support '
                'the food business you selected on the recommendations page.',
              ),
            ]),
          ]),
          span(
            classes: _hasContext
                ? 'sw-match__context is-saved'
                : 'sw-match__context',
            [
              Component.text(
                _hasContext
                    ? 'Your saved recommendation'
                    : 'No recommendation loaded',
              ),
            ],
          ),
        ]),
        div(classes: 'sw-match__grid', [
          // ------------------------------------------------------ focus card
          div(classes: 'sw-match__focus', [
            div(classes: 'sw-match__focusrow', [
              span(
                classes: 'sw-match__business-icon',
                attributes: const {'aria-hidden': 'true'},
                [Component.text(business.icon)],
              ),
              div(classes: 'sw-match__business-text', [
                span(classes: 'sw-match__micro', [
                  Component.text('YOUR CHOSEN BUSINESS'),
                ]),
                h3([Component.text(business.label)]),
                p([Component.text(business.note)]),
              ]),
            ]),
            div(classes: 'sw-match__rule', const []),
            div(classes: 'sw-match__matchrow', [
              div(classes: 'sw-match__matchtext', [
                span(classes: 'sw-match__micro', [
                  Component.text('MATCHES YOUR REQUIREMENTS'),
                ]),
                div(classes: 'sw-match__match', [
                  Component.text(
                    loading
                        ? 'Checking…'
                        : match == null
                            ? 'Not available'
                            : '$match/100',
                  ),
                ]),
                p([
                  Component.text(
                    match == null
                        ? 'Your personalised match is not available. You can '
                            'still explore this property\'s location '
                            'information.'
                        : 'Overall recommendation score for your saved '
                            'preferences. It is not a probability of '
                            'commercial success.',
                  ),
                ]),
              ]),
              div(
                classes: 'sw-match__ring',
                attributes: {
                  if (match != null) 'style': '--match:$match%',
                  'role': 'img',
                  'aria-label': match == null
                      ? 'Recommendation match is not available'
                      : 'Recommendation match $match out of 100',
                },
                [
                  div(classes: 'sw-match__ring-inner', [
                    strong([Component.text(match == null ? '—' : '$match')]),
                    small([Component.text('out of 100')]),
                  ]),
                ],
              ),
            ]),
            div(
              classes: 'sw-match__matchbar',
              attributes: {
                'role': 'progressbar',
                'aria-valuemin': '0',
                'aria-valuemax': '100',
                'aria-valuetext': match == null ? 'Score unavailable' : '$match out of 100',
              },
              [
                span(
                  classes: 'sw-match__matchfill',
                  attributes: {
                    'style': 'width:${match ?? 0}%',
                  },
                  const [],
                ),
              ],
            ),
            div(classes: 'sw-match__status', [
              span(classes: 'sw-match__statusdot', const []),
              Component.text(
                loading
                    ? 'Loading your recommendation context…'
                    : _hasContext
                        ? 'Recommendation context provided for this property.'
                        : 'Open this property from your personalised '
                            'recommendations to see its verified match score.',
              ),
            ]),
            ActionLink(
              'Back to my recommendations',
              href: '/entrepreneur/recommendations',
              variant: 'ghost',
              icon: 'arrow_back',
            ),
          ]),
          // ---------------------------------------------------- quick facts
          div(classes: 'sw-match__insights', [
            div(classes: 'sw-match__insightshead', [
              div([
                span(classes: 'sw-match__micro', [
                  Component.text('REAL AREA INFORMATION'),
                ]),
                h3([Component.text('What matters for your business')]),
              ]),
              span(classes: 'sw-match__badge', [
                Component.text('Local evidence'),
              ]),
            ]),
            _quickFacts(business),
            div(classes: 'sw-match__explain', [
              span(attributes: const {'aria-hidden': 'true'}, [
                Component.text('ⓘ'),
              ]),
              p([
                Component.text(
                  'Nearby-area measurements help you investigate a site. They '
                  'do not, on their own, predict sales or guarantee that the '
                  'premises are suitable for your business.',
                ),
              ]),
            ]),
          ]),
        ]),
        ?featureBlock,
      ],
    );
  }

  /// Category order mirrors the backend's CATEGORY_ORDER so the grouped list
  /// reads the same way as the score explanation; unknown labels fall last.
  static const _categoryOrder = <String>[
    'Population',
    'Demand generators',
    'Accessibility and transportation',
    'Parking',
    'Competitors',
    'Residential environment',
    'Other',
    'Other model features',
  ];

  /// All measured model rows for this property: the SHAP decomposition's
  /// factors when it succeeded, otherwise the same rows carried by the
  /// category payloads. Every row already carries an entrepreneur-facing
  /// label and a rendered value — nothing is formatted from raw columns here.
  List<InsightFactor> _modelFactors(PropertyInsights insights) {
    final explanation = insights.explanation;
    if (explanation != null && explanation.factors.isNotEmpty) {
      return explanation.factors;
    }
    return [for (final category in insights.categories) ...category.factors];
  }

  /// The measured rows grouped by their backend-supplied category label, in
  /// the backend's canonical order.
  List<(String, List<InsightFactor>)> _groupedFactors(
    List<InsightFactor> factors,
  ) {
    final byLabel = <String, List<InsightFactor>>{};
    for (final factor in factors) {
      byLabel.putIfAbsent(factor.categoryLabel, () => []).add(factor);
    }
    final entries = byLabel.entries.toList()
      ..sort((entryA, entryB) {
        int rank(String label) {
          final index = _categoryOrder.indexOf(label);
          return index < 0 ? _categoryOrder.length : index;
        }

        return rank(entryA.key) - rank(entryB.key);
      });
    return [for (final entry in entries) (entry.key, entry.value)];
  }

  /// The same fallback the backend uses when a feature has no curated label:
  /// the raw key with separators turned into spaces, never shown as primary
  /// text when a real label exists.
  String _friendlyFeatureName(String technical) =>
      technical.replaceAll('_', ' ');

  /// The "Location feature availability" strip rendered under the hero grid.
  ///
  /// Rendered only when the insights payload actually carried a coverage
  /// block, so the displayed counts are always the backend's confirmed
  /// numbers. It describes the property's data record — it is deliberately
  /// not a suitability claim and never merged with the match score.
  Component? _featureAvailability(PropertyInsights? insights) {
    final coverage = insights?.featureCoverage;
    if (coverage == null || coverage.featureCount <= 0) return null;
    final groups = _groupedFactors(_modelFactors(insights!));
    final missing = coverage.missingFeatures;
    final open = detailsOpen;

    return div(classes: 'sw-matchfeat', [
      div(classes: 'sw-matchfeat__head', [
        div(classes: 'sw-matchfeat__headtext', [
          span(classes: 'sw-match__micro', [
            Component.text('LOCATION FEATURE AVAILABILITY'),
          ]),
          p(classes: 'sw-matchfeat__lede', [
            Component.text(
              'The recorded measurements the location analysis reads for '
              'this property, grouped by what they describe.',
            ),
          ]),
        ]),
        span(
          classes:
              'sw-matchfeat__count${coverage.isComplete ? ' is-complete' : ' is-partial'}',
          [
            Component.text(
              '${coverage.availableFeatures} of ${coverage.featureCount} '
              'location features available',
            ),
          ],
        ),
      ]),
      if (groups.isNotEmpty)
        div(classes: 'sw-matchfeat__groups', [
          for (final (label, members) in groups)
            span(classes: 'sw-matchfeat__group', [
              Component.text('$label · ${members.length} measured'),
            ]),
        ]),
      if (onToggleDetails != null) ...[
        button(
          classes: 'sw-matchfeat__toggle',
          attributes: {
            'type': 'button',
            'aria-expanded': '$open',
            'aria-controls': 'sw-matchfeat-details',
          },
          events: onToggleDetails != null
              ? events(onClick: () => onToggleDetails!())
              : null,
          [
            Component.text(open ? 'Hide location details' : 'View all location details'),
            span(classes: 'sw-matchfeat__chevron', [
              const Icon('expand_more', size: 'sm'),
            ]),
          ],
        ),
        div(
          classes: 'sw-matchfeat__details${open ? ' is-open' : ''}',
          attributes: {
            'id': 'sw-matchfeat-details',
            'aria-hidden': open ? 'false' : 'true',
          },
          [
            for (final (label, members) in groups)
              div(classes: 'sw-matchfeat__detailgroup', [
                div(classes: 'sw-matchfeat__detailhead', [
                  span(classes: 'sw-matchfeat__detailtitle', [
                    Component.text(label),
                  ]),
                  span(classes: 'sw-matchfeat__detailcount', [
                    Component.text('${members.length} measured'),
                  ]),
                ]),
                div(classes: 'sw-matchfeat__rows', [
                  for (final factor in members)
                    div(classes: 'sw-matchfeat__row', [
                      span(classes: 'sw-matchfeat__rowlabel', [
                        Component.text(factor.label),
                      ]),
                      span(classes: 'sw-matchfeat__rowvalue', [
                        Component.text(
                          factor.value == null
                              ? 'Not measured'
                              : factor.valueDisplay,
                        ),
                      ]),
                    ]),
                ]),
              ]),
            if (missing.isNotEmpty)
              div(classes: 'sw-matchfeat__missing', [
                strong([Component.text('Not measured for this location')]),
                p([
                  Component.text(
                    'These model inputs have no recorded value here: '
                    '${missing.map(_friendlyFeatureName).join(', ')}.',
                  ),
                ]),
              ]),
          ],
        ),
      ],
      p(classes: 'sw-matchfeat__note', [
        Component.text(
          'Feature availability describes the data record behind the area '
          'analysis. It is not a measure of how well this location matches '
          'your business.',
        ),
      ]),
    ]);
  }

  Component _fact(String icon, String label, String value) => div(
        classes: 'sw-match__fact',
        [
          span(classes: 'sw-match__facticon', [
            Component.text(icon),
          ]),
          div([
            small([Component.text(label)]),
            strong([
              Component.text(value),
            ]),
          ]),
        ],
      );

  Component _quickFacts(_BusinessDisplay business) {
    final residents = _metricOf(evidence, 'pop_1000m');
    final transit = _metricOf(evidence, 'nearest_transit_walk_m');
    final shops = _metricOf(evidence, 'retail_pois_1000m');
    final competitors = _metricOf(evidence, business.competitorKey);
    final parking = _metricOf(evidence, 'parking_facilities_500m');

    // Values are formatted by lib/data/metric_format.dart from the raw
    // numbers the backend serves — the same numbers the ML reads. A missing
    // measurement renders "Not available", never a guessed zero.
    return div(
      classes: 'sw-match__quickfacts',
      attributes: const {'aria-live': 'polite'},
      [
        _fact(
          '👥',
          'People living within 1 km',
          fmtResidents(residents?.value) ?? 'Not available',
        ),
        _fact(
          '🚏',
          'Nearest public transport',
          fmtDistance(transit?.value) ?? 'Not available',
        ),
        _fact(
          business.competitorIcon,
          business.competitorTileLabel,
          fmtCount(
            competitors?.value,
            singular: business.competitorNounSingular,
            plural: business.competitorNounPlural,
          ) ??
              'Not available',
        ),
        _fact(
          '🏬',
          'Shops within 1 km',
          fmtCount(shops?.value, singular: 'shop', plural: 'shops') ??
              'Not available',
        ),
        _fact(
          '🅿️',
          'Parking facilities within 500 m',
          fmtCount(parking?.value, singular: 'facility', plural: 'facilities') ??
              'Not available',
        ),
        _fact(
          '💰',
          'Monthly rental',
          fmtMonthlyRental(property.rentalRm, rentalMaxRm: property.rentalMaxRm) ??
              'Not available',
        ),
      ],
    );
  }
}

/// Tab 1 — the reasons and checks behind the match above.
class BusinessMatchDetail extends StatelessComponent {
  final PersonalisedExplanation? explanation;
  final bool loading;
  final PropertyEvidence? evidence;
  final CommercialProperty property;

  const BusinessMatchDetail({
    super.key,
    required this.property,
    this.explanation,
    this.loading = false,
    this.evidence,
  });

  _BusinessDisplay get _business => _BusinessDisplay.of(explanation);

  @override
  Component build(BuildContext context) {
    final e = explanation;
    EvidenceMetric? metric(String key) => _metricOf(evidence, key);

    final reasons = <_Reason>[];
    final checks = <_Reason>[];

    if (e != null) {
      for (final reason in e.preferenceReasons.take(4)) {
        reasons.add(_Reason('✓', 'Matches a saved preference', reason));
      }
      for (final caution in e.cautions.take(3)) {
        checks.add(_Reason('!', 'Recommendation consideration', caution));
      }
    }
    if (reasons.isEmpty) {
      final residents = metric('pop_1000m');
      final shops = metric('retail_pois_1000m');
      final transit = metric('nearest_transit_walk_m');
      if (residents?.available == true) {
        reasons.add(_Reason(
          '👥',
          'Potential customers nearby',
          '${residents!.displayValue} estimated people live within 1 km. '
              'This indicates local population, not expected customer numbers.',
        ));
      }
      if (shops?.available == true) {
        reasons.add(_Reason(
          '🛍',
          'Nearby shopping activity',
          '${shops!.displayValue} mapped shops are within 1 km. Their presence '
              'may bring visitors, but passing foot traffic has not been '
              'measured.',
        ));
      }
      if (transit?.available == true) {
        reasons.add(_Reason(
          '🚏',
          'Access by public transport',
          'The closest recorded public transport stop is approximately '
              '${transit!.displayValue} away on the walking network.',
        ));
      }
      if (reasons.isEmpty) {
        reasons.add(_Reason(
          'ⓘ',
          'Location evidence unavailable',
          'No measured local information is currently available for this '
              'property.',
        ));
      }
    }

    final competitors = metric(_business.competitorKey);
    if (competitors?.available == true) {
      checks.add(_Reason(
        _business.competitorIcon,
        'Understand nearby competitors',
        '${competitors!.displayValue} ${_business.competitorLabel.toLowerCase()} '
            'are mapped within 500 m. Compare menus, pricing, opening times '
            'and customer traffic.',
      ));
    }
    checks.add(_Reason(
      '💳',
      'Confirm rent against your budget',
      'The asking rent is ${property.rentalDisplay} per month. Your budget '
          'match requires your saved preferences.',
    ));
    checks.add(_business.operatingCheck);

    final source = e == null
        ? 'The figures above are recorded area measurements, not a '
            'business-type model prediction. A verified personalised '
            'explanation appears when the page is opened from your saved '
            'recommendation.'
        : 'The preference reasons above come from your recommendation result. '
            'Neighborhood measurements are separate supporting evidence.';

    return section(
      classes: 'sw-matchdetail',
      attributes: const {'aria-labelledby': 'sw-matchdetail-title'},
      [
        div(classes: 'sw-info__intro', [
          h3(
            attributes: const {'id': 'sw-matchdetail-title'},
            [Component.text('What should I check before opening here?')],
          ),
          p([
            Component.text(
              'The reasons below refer to your chosen business, using your '
              'saved recommendation explanation where available and measured '
              'facts about this location.',
            ),
          ]),
        ]),
        div(classes: 'sw-matchdetail__grid', [
          _reasonCard(
            title: 'Reasons to consider this location',
            subtitle: 'What the location information can tell you',
            tone: 'positive',
            reasons: reasons,
          ),
          _reasonCard(
            title: 'Things to check in person',
            subtitle: 'Practical checks before committing to rent',
            tone: 'caution',
            reasons: checks,
          ),
        ]),
        div(classes: 'sw-matchdetail__source', [
          span(attributes: const {'aria-hidden': 'true'}, [
            Component.text('ⓘ'),
          ]),
          p([Component.text(source)]),
        ]),
        if (e != null && e.components.isNotEmpty) ...[
          h3(classes: 'sw-matchdetail__subheading', [
            Component.text('Match for each preference'),
          ]),
          div(classes: 'sw-matchdetail__components', [
            for (final entry in e.components.entries)
              div(classes: 'sw-matchdetail__component', [
                span([Component.text(componentLabel(entry.key))]),
                span(
                  classes: entry.value.status == 'unknown'
                      ? 'is-unknown'
                      : null,
                  [
                    Component.text(
                      entry.value.status == 'unknown' ||
                              entry.value.value == null
                          ? 'not enough information'
                          : '${(entry.value.value! * 100).toStringAsFixed(0)}%',
                    ),
                  ],
                ),
              ]),
          ]),
        ],
      ],
    );
  }

  Component _reasonCard({
    required String title,
    required String subtitle,
    required String tone,
    required List<_Reason> reasons,
  }) {
    return article(classes: 'sw-matchdetail__card', [
      div(classes: 'sw-matchdetail__cardtitle', [
        span(classes: 'sw-matchdetail__cardicon sw-matchdetail__cardicon--$tone', [
          Component.text(tone == 'positive' ? '✓' : '!'),
        ]),
        div([
          h3([Component.text(title)]),
          p([Component.text(subtitle)]),
        ]),
      ]),
      div(classes: 'sw-matchdetail__reasons', [
        for (final reason in reasons.take(4))
          div(classes: 'sw-matchdetail__reason', [
            span(classes: 'sw-matchdetail__reasonicon', [
              Component.text(reason.icon),
            ]),
            div([
              strong([Component.text(reason.title)]),
              p([Component.text(reason.body)]),
            ]),
          ]),
      ]),
    ]);
  }
}

class _Reason {
  final String icon;
  final String title;
  final String body;
  const _Reason(this.icon, this.title, this.body);
}

/// The saved business type rendered as a display name, icon and behaviour.
///
/// The stored vocabulary comes from the backend's CONCEPT_LABELS; an unknown
/// category falls back to a neutral F&B display rather than a guessed one.
class _BusinessDisplay {
  final String label;
  final String icon;
  final String note;
  final String kind;
  final String competitorKey;
  final String competitorLabel;
  final String competitorIcon;

  const _BusinessDisplay({
    required this.label,
    required this.icon,
    required this.note,
    required this.kind,
    required this.competitorKey,
    required this.competitorLabel,
    required this.competitorIcon,
  });

  static const _fallback = _BusinessDisplay(
    label: 'Your food business',
    icon: '🍴',
    note: 'The type of business you want to open.',
    kind: 'general',
    competitorKey: 'competitor_count_500m',
    competitorLabel: 'F&B businesses',
    competitorIcon: '🍽',
  );

  factory _BusinessDisplay.of(PersonalisedExplanation? explanation) {
    final category =
        explanation?.selectedBusinessCategory?.trim().toLowerCase() ?? '';
    final concept = explanation?.selectedFnbConcept?.trim().toLowerCase() ?? '';
    final key = concept.isNotEmpty ? concept : category;

    // Match on the stored concept key first, then the human label the
    // backend normalises to, so either vocabulary renders correctly.
    if (key.contains('cafe') || key.contains('coffee')) {
      return const _BusinessDisplay(
        label: 'Café & coffee shop',
        icon: '☕',
        note: 'Coffee, drinks and light meals.',
        kind: 'cafe',
        competitorKey: 'cafe_count_500m',
        competitorLabel: 'Cafés',
        competitorIcon: '☕',
      );
    }
    if (key.contains('bakery') || key.contains('dessert')) {
      return const _BusinessDisplay(
        label: 'Bakery & dessert shop',
        icon: '🥐',
        note: 'Baked goods and daily purchases.',
        kind: 'bakery',
        competitorKey: 'competitor_count_500m',
        competitorLabel: 'F&B businesses',
        competitorIcon: '🥐',
      );
    }
    if (key.contains('fast food') || key.contains('quick')) {
      return const _BusinessDisplay(
        label: 'Fast food & takeaway',
        icon: '🥡',
        note: 'Quick meals and collection.',
        kind: 'quick',
        competitorKey: 'fast_food_count_500m',
        competitorLabel: 'Fast-food outlets',
        competitorIcon: '🥡',
      );
    }
    if (key.contains('beverage') || key.contains('kiosk')) {
      return const _BusinessDisplay(
        label: 'Beverage shop / kiosk',
        icon: '🧋',
        note: 'Drinks and grab-and-go service.',
        kind: 'beverage',
        competitorKey: 'competitor_count_500m',
        competitorLabel: 'F&B businesses',
        competitorIcon: '🧋',
      );
    }
    if (key.contains('restaurant')) {
      return const _BusinessDisplay(
        label: 'Restaurant',
        icon: '🍽️',
        note: 'Seated meals and food service.',
        kind: 'restaurant',
        competitorKey: 'restaurant_count_500m',
        competitorLabel: 'Restaurants',
        competitorIcon: '🍽️',
      );
    }
    if (category.isNotEmpty) {
      final label = explanation?.selectedBusinessCategory?.trim() ?? '';
      return _BusinessDisplay(
        label: label,
        icon: '🍴',
        note: 'Your selected food business.',
        kind: 'general',
        competitorKey: 'competitor_count_500m',
        competitorLabel: 'F&B businesses',
        competitorIcon: '🍽',
      );
    }
    return _fallback;
  }

  /// The competitor tile's label. The generic F&B fallback reads
  /// "Food businesses" on the tile — "F&B businesses" stays tab-1 prose
  /// vocabulary — while a specific kind already names itself
  /// ("Cafés within 500 m").
  String get competitorTileLabel => competitorLabel == 'F&B businesses'
      ? 'Food businesses within 500 m'
      : '$competitorLabel within 500 m';

  /// The count noun for the tile's value ("7 businesses", "1 café").
  /// Derived from the label vocabulary in one place so tile value and tile
  /// label stay grammatically consistent for every business kind.
  String get competitorNounPlural {
    switch (competitorLabel) {
      case 'F&B businesses':
        return 'businesses';
      case 'Cafés':
        return 'cafés';
      case 'Fast-food outlets':
        return 'fast-food outlets';
      case 'Restaurants':
        return 'restaurants';
      default:
        return competitorLabel.toLowerCase();
    }
  }

  String get competitorNounSingular {
    final plural = competitorNounPlural;
    if (plural == 'businesses') return 'business';
    if (plural.endsWith('s') && plural.length > 1) {
      return plural.substring(0, plural.length - 1);
    }
    return plural;
  }

  _Reason get operatingCheck {
    switch (kind) {
      case 'cafe':
        return const _Reason(
          '☕',
          'Check café operating needs',
          'Observe morning customers, seating demand, utilities and the '
              'nearest coffee competitors.',
        );
      case 'bakery':
        return const _Reason(
          '🥐',
          'Check bakery operating needs',
          'Confirm power supply, ovens, ventilation and likely daily buying '
              'patterns.',
        );
      case 'quick':
        return const _Reason(
          '🥡',
          'Check takeaway access',
          'Assess takeaway pickup, rider waiting space, lunchtime demand and '
              'kitchen requirements.',
        );
      case 'beverage':
        return const _Reason(
          '🧋',
          'Check beverage kiosk needs',
          'Confirm counter space, water and power supply, and the flow of '
              'passing customers.',
        );
      default:
        return const _Reason(
          '🍽',
          'Check food-premises requirements',
          'Confirm kitchen ventilation, permitted use, grease traps, '
              'accessibility and local licences.',
        );
    }
  }
}

/// Look up one metric by key across every evidence group.
EvidenceMetric? _metricOf(PropertyEvidence? evidence, String key) {
  if (evidence == null) return null;
  for (final group in evidence.groups) {
    for (final m in group.metrics) {
      if (m.key == key) return m;
    }
  }
  return null;
}
