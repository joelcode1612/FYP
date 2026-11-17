import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../../data/location_evidence_api.dart';
import '../../data/metric_format.dart';
import '../../data/property_insights_api.dart';
import '../ui.dart';

/// The "Your business & this property" presentation.
///
/// Two coordinated views driven by the SAME context:
/// * [BusinessMatchHero] — the section above the tabs: the resolved business
///   type, its Stage-2 category suitability score (ring + bar) and measured
///   quick facts.
/// * [BusinessMatchDetail] — tab 1: the entrepreneur's saved preferences
///   compared against this property row by row, driven by the saved
///   recommendation when the page carries a `?result=` context.
///
/// Data honesty rules encoded here:
/// * The hero score is ONLY the category model's output for the
///   entrepreneur's own selected type (`selected_category`). It is never the
///   PU location score, never another category's score, and the model's top
///   category is never silently substituted for the selection.
/// * SHAP-derived sentences render only when the backend's explanation
///   describes the selected category itself.
/// * Evidence-based reasons describe recorded measurements; they are support
///   material, never claimed as model contributions.
/// * A missing measurement renders "Not available", never zero.
class BusinessMatchHero extends StatelessComponent {
  final PropertyEvidence? evidence;
  final CommercialProperty property;

  /// The resolved insights payload, when the location analysis answered. Its
  /// `category_model` block drives the suitability score, its
  /// `feature_coverage` block the model-input availability strip; the counts
  /// always come from the backend, never a hardcoded total.
  final PropertyInsights? insights;

  /// True when the insights request finished without a payload — the hero
  /// then reports the failure instead of spinning forever.
  final bool insightsFailed;

  /// The F&B type this hero scores, resolved by the page: the Recommendations
  /// URL selection first, then the signed-in account's saved preference, then
  /// this browser's stored selection. Empty means none resolved — the hero
  /// asks for a selection instead of scoring another category.
  final String businessType;

  /// The resolution source: 'recommendations' | 'account' | 'browser' | ''.
  final String typeSource;

  /// Whether the expandable "View all location details" list is open. The
  /// state lives on the page (the `@client` boundary) so this panel stays
  /// stateless, matching the SHAP chart's disclosure pattern.
  final bool detailsOpen;
  final void Function()? onToggleDetails;

  const BusinessMatchHero({
    super.key,
    required this.property,
    this.evidence,
    this.insights,
    this.insightsFailed = false,
    this.businessType = '',
    this.typeSource = '',
    this.detailsOpen = false,
    this.onToggleDetails,
  });

  CategoryFit? get _fit => insights?.categoryFit;

  /// The selected-category block — present only when the resolved type maps
  /// onto one of the model's canonical classes.
  SelectedCategory? get _selected {
    final fit = _fit;
    if (fit == null || !fit.available) return null;
    return fit.selectedCategory;
  }

  /// The selected category's score rescaled to 0-100, or null when the model
  /// returned nothing usable. The model output is a 0-1 conditional
  /// probability (association index); ×100 is display scaling only.
  int? get _suitPercent {
    final raw = _selected?.score;
    if (raw == null || raw < 0 || raw > 1) return null;
    return (raw * 100).round();
  }

  /// Category-specific SHAP factors, only when the backend's explanation
  /// describes THIS selection. An unknown selection makes the backend explain
  /// its own top category, and those factors must never appear here.
  List<InsightFactor> get _matchedFactors {
    final fit = _fit;
    final selected = _selected;
    final explanation = fit?.explanation;
    if (fit == null || selected == null || explanation == null) return const [];
    if (explanation.businessType != selected.businessType) return const [];
    return explanation.factors;
  }

  @override
  Component build(BuildContext context) {
    final business = _BusinessDisplay.ofType(businessType);
    final fit = _fit;
    final selected = _selected;
    final match = _suitPercent;
    final hasType = businessType.isNotEmpty;
    final loading = insights == null && !insightsFailed;
    final unsupported =
        hasType && fit != null && fit.available && selected == null;
    final factors = _matchedFactors;
    final featureBlock = _featureAvailability(insights);

    final badge = !hasType
        ? 'No business type selected'
        : typeSource == 'recommendations'
        ? 'Type from Recommendations'
        : typeSource == 'account'
        ? 'Type from your saved preferences'
        : 'Type from this browser';

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
                'See how well this location resembles the places where the '
                'food business you selected already operates.',
              ),
            ]),
          ]),
          span(
            classes: hasType
                ? 'sw-match__context is-saved'
                : 'sw-match__context',
            [Component.text(badge)],
          ),
        ]),
        div(classes: 'sw-match__grid', [
          // ------------------------------------------------------ focus card
          div(classes: 'sw-match__focus', [
            div(classes: 'sw-match__focusrow', [
              span(
                classes: 'sw-match__business-icon',
                attributes: const {'aria-hidden': 'true'},
                [Icon(business.icon)],
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
                  Component.text('SUITABILITY FOR YOUR BUSINESS TYPE'),
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
                    _scoreNote(
                      loading: loading,
                      hasType: hasType,
                      unsupported: unsupported,
                      fit: fit,
                      selected: selected,
                      match: match,
                      factorsEmpty: factors.isEmpty,
                    ),
                  ),
                ]),
                if (match != null && selected?.rank != null && fit != null)
                  span(classes: 'sw-match__micro', [
                    Component.text(
                      'RANK ${selected!.rank} OF ${fit.rankings.length} '
                      'CATEGORY TYPES',
                    ),
                  ]),
              ]),
              div(
                classes: 'sw-match__ring',
                attributes: {
                  if (match != null) 'style': '--match:$match%',
                  'role': 'img',
                  'aria-label': match == null
                      ? 'Suitability for your business type is not available'
                      : 'Suitability for ${business.label} $match out of 100',
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
                'aria-valuetext': match == null
                    ? 'Score unavailable'
                    : '$match out of 100',
              },
              [
                span(
                  classes: 'sw-match__matchfill',
                  attributes: {'style': 'width:${match ?? 0}%'},
                  const [],
                ),
              ],
            ),
            if (factors.isNotEmpty)
              div(classes: 'sw-match__explain', [
                span(
                  attributes: const {'aria-hidden': 'true'},
                  [Icon('info', size: 'sm')],
                ),
                p([Component.text(_factorSentence(factors))]),
              ]),
            div(classes: 'sw-match__status', [
              span(classes: 'sw-match__statusdot', const []),
              Component.text(
                _statusText(
                  loading: loading,
                  hasType: hasType,
                  unsupported: unsupported,
                  fit: fit,
                ),
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
              span(
                attributes: const {'aria-hidden': 'true'},
                [Icon('info', size: 'sm')],
              ),
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

  /// The paragraph under the hero score. Every branch names what is actually
  /// known; none invents a number or borrows another category's claim.
  String _scoreNote({
    required bool loading,
    required bool hasType,
    required bool unsupported,
    required CategoryFit? fit,
    required SelectedCategory? selected,
    required int? match,
    required bool factorsEmpty,
  }) {
    if (loading) {
      return 'Reading the category analysis for your selected business type…';
    }
    if (!hasType) {
      return 'Select your F&B business type in Preferences to see how well '
          'this location resembles operating outlets of that kind.';
    }
    if (unsupported) {
      return '"${businessType.trim()}" is not one of the categories this '
          'model scores: cafés/coffee, restaurants, bakery/dessert/beverage '
          'and fast food/takeaway. No other category\'s score is shown in '
          'its place.';
    }
    if (fit == null || !fit.available) {
      return 'Business-type score unavailable. '
          '${fit?.unavailableReason ?? 'The analysis service did not return a result.'}';
    }
    if (match == null || selected == null) {
      return 'The model did not return a usable score for this category.';
    }
    return 'How closely this location resembles operating outlets of the '
        'selected type, from the research category model. It is not a '
        'probability of commercial success.'
        '${factorsEmpty ? ' A category-specific explanation is not available for this score.' : ''}';
  }

  String _statusText({
    required bool loading,
    required bool hasType,
    required bool unsupported,
    required CategoryFit? fit,
  }) {
    if (loading) return 'Loading the suitability analysis…';
    if (!hasType) {
      return 'Choose your business type in Preferences to see this score.';
    }
    if (unsupported) {
      return 'Score withheld rather than showing another category\'s result.';
    }
    if (fit == null || !fit.available) {
      return 'Business-type score unavailable — shown as missing, never as zero.';
    }
    return 'Research resemblance score — exploratory, weakly validated, '
        'not a success probability.';
  }

  /// One sentence naming the strongest supporting and limiting measured
  /// factors for the selected category — the backend's own SHAP factors,
  /// never re-ranked from raw columns.
  String _factorSentence(List<InsightFactor> factors) {
    final supporting =
        [
          for (final f in factors)
            if (f.contribution > 0) f,
        ]..sort(
          (factorA, factorB) =>
              factorB.contribution.compareTo(factorA.contribution),
        );
    final lowering =
        [
          for (final f in factors)
            if (f.contribution < 0) f,
        ]..sort(
          (factorA, factorB) =>
              factorA.contribution.compareTo(factorB.contribution),
        );
    final parts = <String>[];
    if (supporting.isNotEmpty) {
      parts.add(
        'Strongest support: ${supporting.take(2).map((f) => f.label).join(', ')}',
      );
    }
    if (lowering.isNotEmpty) {
      parts.add(
        'Most limiting: ${lowering.take(1).map((f) => f.label).join(', ')}',
      );
    }
    return parts.isEmpty
        ? 'No category-specific factors are available for this score.'
        : '${parts.join('. ')}.';
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
            Component.text(
              open ? 'Hide location details' : 'View all location details',
            ),
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

  Component _fact(String icon, String label, String value) =>
      div(classes: 'sw-match__fact', [
        span(
          classes: 'sw-match__facticon',
          attributes: const {'aria-hidden': 'true'},
          [Icon(icon)],
        ),
        div([
          small([Component.text(label)]),
          strong([Component.text(value)]),
        ]),
      ]);

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
          'group',
          'People living within 1 km',
          fmtResidents(residents?.value) ?? 'Not available',
        ),
        _fact(
          'directions_bus',
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
          'storefront',
          'Shops within 1 km',
          fmtCount(shops?.value, singular: 'shop', plural: 'shops') ??
              'Not available',
        ),
        _fact(
          'local_parking',
          'Parking facilities within 500 m',
          fmtCount(
                parking?.value,
                singular: 'facility',
                plural: 'facilities',
              ) ??
              'Not available',
        ),
        _fact(
          'payments',
          'Monthly rental',
          fmtMonthlyRental(
                property.rentalRm,
                rentalMaxRm: property.rentalMaxRm,
              ) ??
              'Not available',
        ),
      ],
    );
  }
}

/// Tab 1 — the entrepreneur's own saved preferences compared against this
/// property, row by row.
///
/// Every row is built from the SAME data the recommendation used: the saved
/// inputs echoed by the explanation endpoint and the rule engine's own
/// component results. Nothing is re-scored here, and the research PU
/// location score never appears — a rule is explained by the rule engine,
/// never by SHAP.
///
/// Statuses (mirroring the engine's own thresholds):
/// * **Matched** — the component was scored at or above the engine's
///   strength threshold (0.65, `ScoringConfig.strength_threshold`).
/// * **Needs review** — scored, but below the threshold.
/// * **Not enough data** — the preference was not saved, or the engine
///   could not score it. Unknown components are never zero-filled, so an
///   unverified requirement can never read as matched.
class BusinessMatchDetail extends StatelessComponent {
  final PersonalisedExplanation? explanation;

  /// The applied Recommendations filters, when the entrepreneur opened this
  /// property from a search rather than a saved recommendation. Shown only as
  /// a direct comparison with the listing's own details — never as a score.
  final RecommendationSearchRequest? appliedFilters;
  final bool loading;
  final CommercialProperty property;

  const BusinessMatchDetail({
    super.key,
    required this.property,
    this.explanation,
    this.appliedFilters,
    this.loading = false,
  });

  @override
  Component build(BuildContext context) {
    return section(
      classes: 'sw-matchdetail',
      attributes: const {'aria-labelledby': 'sw-matchdetail-title'},
      [
        div(classes: 'sw-info__intro', [
          h3(
            attributes: const {'id': 'sw-matchdetail-title'},
            [Component.text('Your preferences vs this property')],
          ),
          p([
            Component.text(
              explanation != null
                  ? 'Each row compares what you saved with your recommendation '
                      'against this property, using the same scoring the '
                      'recommendation used.'
                  : 'Each row compares the filters you applied on Recommendations '
                      'with this property’s own details.',
            ),
          ]),
        ]),
        if (loading)
          div(classes: 'sw-compare__loading', [
            Component.text('Loading your saved recommendation…'),
          ])
        else if (explanation != null) ...[
          ..._comparison(_rows(explanation!)),
        ] else if (appliedFilters != null &&
            !appliedFilters!.isBrowseOnly) ...[
          // No saved recommendation exists for a fresh search. Compare the
          // ACTUAL applied filters with the listing; call it what it is
          // instead of presenting a fabricated saved preference.
          ..._filterComparison(_filterRows(appliedFilters!, property)),
        ] else
          _invite(),
      ],
    );
  }

  /// The search-filter comparison uses the same row layout as a saved
  /// recommendation, but its summary and source note say plainly that these
  /// are the entrepreneur's applied search criteria — not a model score.
  List<Component> _filterComparison(List<_Row> rows) {
    final checked = rows.where((r) => r.status != _RowStatus.notEnough).length;
    final matches = rows.where((r) => r.status == _RowStatus.matched).length;
    return [
      div(classes: 'sw-compare', [
        div(classes: 'sw-compare__head', [
          for (final label in const [
            'Filter',
            'Your selection',
            'This property',
            'Status',
          ])
            span([Component.text(label)]),
        ]),
        for (final row in rows) _row(row),
      ]),
      div(classes: 'sw-compare__summary', [
        Icon('fact_check', size: 'sm'),
        p([
          Component.text(
            checked == 0
                ? 'None of your search filters can be checked against this '
                    'listing’s details.'
                : '$matches of $checked checkable filters match this listing.',
          ),
        ]),
      ]),
      div(classes: 'sw-matchdetail__source', [
        span(attributes: const {'aria-hidden': 'true'}, [
          Icon('info', size: 'sm'),
        ]),
        p([
          Component.text(
            'These are the filters you applied when you opened this property '
            'from Recommendations. They are compared with the listing’s own '
            'details; this is not a model score. Business type changes the '
            'order of results, and target market cannot be checked from the '
            'property record.',
          ),
        ]),
      ]),
    ];
  }

  /// Direct, honest comparisons. A filter the catalogue cannot answer is
  /// shown as "Not enough data" — never as a match or a zero.
  List<_Row> _filterRows(RecommendationSearchRequest request, CommercialProperty p) {
    final rows = <_Row>[];
    final business = request.businessType?.trim() ?? '';
    if (business.isNotEmpty) {
      rows.add(_Row(
        name: 'Business type',
        stated: true,
        yourValue: _BusinessDisplay.ofType(business).label,
        propertyValue: 'Shown in your business match above',
        status: _RowStatus.review,
        note: 'Business type orders the results; it does not remove properties.',
      ));
    }
    final state = request.preferredState?.trim() ?? '';
    if (state.isNotEmpty) {
      final actual = p.state.trim();
      final matches = actual.toLowerCase() == state.toLowerCase();
      rows.add(_Row(
        name: 'Preferred state',
        stated: true,
        yourValue: state,
        propertyValue: actual.isEmpty ? 'Not provided' : actual,
        status: matches ? _RowStatus.matched : _RowStatus.review,
      ));
    }
    final type = request.propertyType?.trim() ?? '';
    if (type.isNotEmpty) {
      final actual = p.propertyType.trim();
      final matches = actual.toLowerCase() == type.toLowerCase();
      rows.add(_Row(
        name: 'Property type',
        stated: true,
        yourValue: type,
        propertyValue: actual.isEmpty ? 'Not provided' : actual,
        status: matches ? _RowStatus.matched : _RowStatus.review,
      ));
    }
    final rentMin = request.minRentalRm;
    final rentMax = request.maxRentalRm;
    if (rentMin != null || rentMax != null) {
      final low = rentMin ?? 0;
      final high = rentMax ?? double.infinity;
      final pLow = p.rentalRm;
      final pHigh = p.rentalMaxRm;
      final inRange = pHigh >= low && pLow <= high;
      rows.add(_Row(
        name: 'Monthly rental',
        stated: true,
        yourValue: rentMin == null
            ? 'Up to ${_thousands(high)} RM'
            : fmtMonthlyRental(
                  low,
                  rentalMaxRm: rentMax == null ? null : high,
                ) ??
                'Not stated',
        propertyValue:
            fmtMonthlyRental(pLow, rentalMaxRm: pHigh) ?? 'Not provided',
        status: inRange ? _RowStatus.matched : _RowStatus.review,
      ));
    }
    final sizeMin = request.minSizeSqft;
    final sizeMax = request.maxSizeSqft;
    if (sizeMin != null || sizeMax != null) {
      final inRange =
          p.sizeSqft >= (sizeMin ?? 0) && p.sizeSqft <= (sizeMax ?? double.infinity);
      rows.add(_Row(
        name: 'Property size',
        stated: true,
        yourValue: sizeMin == null
            ? 'Up to ${_thousands(sizeMax!)} sq ft'
            : sizeMax == null
                ? '${_thousands(sizeMin)}+ sq ft'
                : '${_thousands(sizeMin)}–${_thousands(sizeMax)} sq ft',
        propertyValue: '${_thousands(p.sizeSqft)} sq ft',
        status: inRange ? _RowStatus.matched : _RowStatus.review,
      ));
    }
    if (request.layoutPreferences.isNotEmpty) {
      rows.add(_Row(
        name: 'Target market',
        stated: true,
        yourValue: request.layoutPreferences.join(', '),
        propertyValue: 'Not recorded for this listing',
        status: _RowStatus.notEnough,
        note: 'The property record has no customer-mix information.',
      ));
    }
    return rows;
  }

  static String _thousands(double value) {
    final digits = value.toStringAsFixed(0);
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }

  Component _invite() {
    return div(classes: 'sw-compare__invite', [
      span(
        classes: 'sw-compare__inviteicon',
        attributes: const {'aria-hidden': 'true'},
        [Icon('recommend', size: 'lg')],
      ),
      h3([Component.text('Compare this property with your saved preferences')]),
      p([
        Component.text(
          'This page is not linked to a saved recommendation yet. Generate a '
              'recommendation from your saved business preferences, then open '
              'this property from its results to see each requirement '
              'compared side by side.',
        ),
      ]),
      a(
        classes: 'sw-btn sw-btn-primary',
        href: '/entrepreneur/recommendations',
        [Component.text('Create a recommendation')],
      ),
    ]);
  }

  List<Component> _comparison(List<_Row> rows) {
    final evaluated =
        rows.where((r) => r.status != _RowStatus.notEnough).length;
    final matched = rows.where((r) => r.status == _RowStatus.matched).length;
    return [
      div(classes: 'sw-compare', [
        div(classes: 'sw-compare__head', [
          for (final label in const [
            'Preference',
            'Your selection',
            'This property',
            'Status',
          ])
            span([Component.text(label)]),
        ]),
        for (final row in rows) _row(row),
      ]),
      // The summary counts only preferences the engine actually evaluated —
      // never a percentage, never an invented score.
      div(classes: 'sw-compare__summary', [
        Icon('fact_check', size: 'sm'),
        p([
          Component.text(
            evaluated == 0
                ? 'No saved preference could be evaluated for this listing '
                      'from your recommendation yet.'
                : '$matched of $evaluated saved preferences matched.',
          ),
        ]),
      ]),
      div(classes: 'sw-matchdetail__source', [
        span(
          attributes: const {'aria-hidden': 'true'},
          [Icon('info', size: 'sm')],
        ),
        p([
          Component.text(
            'Rows come from your saved recommendation\'s own rule-engine '
                'scoring for this listing. A preference you did not save, or '
                'one the engine could not score, is shown as "Not enough '
                'data" — never as zero or a guess.',
          ),
        ]),
      ]),
    ];
  }

  Component _row(_Row row) {
    final (icon, tone, label) = switch (row.status) {
      _RowStatus.matched => ('check_circle', 'matched', 'Matched'),
      _RowStatus.review => ('warning', 'review', 'Needs review'),
      _RowStatus.notEnough => ('info', 'unknown', 'Not enough data'),
    };
    return div(classes: 'sw-compare__row', [
      div(classes: 'sw-compare__name', [Component.text(row.name)]),
      div(
        classes: row.stated
            ? 'sw-compare__cell'
            : 'sw-compare__cell sw-compare__cell--muted',
        [Component.text(row.yourValue)],
      ),
      div(classes: 'sw-compare__cell', [Component.text(row.propertyValue)]),
      div(classes: 'sw-compare__status sw-compare__status--$tone', [
        Icon(icon, size: 'sm'),
        span([Component.text(label)]),
      ]),
      if (row.note != null)
        div(classes: 'sw-compare__note', [Component.text(row.note!)]),
      if (row.caution != null)
        div(
          classes: 'sw-compare__note sw-compare__note--caution',
          [Component.text(row.caution!)],
        ),
    ]);
  }

  /// One row per preference the recommendation scored, in the order the
  /// questionnaire asks them. The "your selection" column is the entrepreneur's
  /// own saved input echoed by the explanation endpoint; the "this property"
  /// column is the evidence the rule engine itself scored against.
  List<_Row> _rows(PersonalisedExplanation e) {
    ComponentDetail? component(String key) => e.components[key];
    final saved = e.selectedPreferences;
    final rows = <_Row>[];

    const notSaved =
        'Not saved with this recommendation, so it is not compared; the '
        'listing value is shown for reference.';

    // 1. Business type — the selected F&B category (concept first, matching
    //    the hero above) and the engine's own premises-type rule. Never the
    //    research PU score and never another category's model output.
    final typeComp = component('property_type_fit');
    final typeEv = typeComp?.evidence ?? const {};
    final category = e.selectedBusinessCategory?.trim() ?? '';
    final concept = e.selectedFnbConcept?.trim() ?? '';
    final typeKey = concept.isNotEmpty ? concept : category;
    final typeStated = typeKey.isNotEmpty;
    var yourType =
        typeStated ? _BusinessDisplay.ofType(typeKey).label : 'Not stated';
    if (saved.preferredPropertyTypes.isNotEmpty) {
      yourType +=
          ' · prefers ${saved.preferredPropertyTypes.join(', ')}';
    }
    rows.add(_Row(
      name: 'Business type',
      stated: typeStated,
      yourValue: yourType,
      propertyValue: _orNotRecorded(
        _evText(typeEv, 'property_type') ?? property.propertyType,
      ),
      status: typeStated ? _statusOf(typeComp) : _RowStatus.notEnough,
      note: typeStated ? typeComp?.reason : notSaved,
    ));

    // 2. Target market — strictly the engine's target_market_fit result and
    //    its own supporting signals. Nearby population alone is never claimed
    //    as proven customer demand here.
    final marketComp = component('target_market_fit');
    final marketEv = marketComp?.evidence ?? const {};
    final customers = saved.targetCustomers;
    final marketStated = customers.isNotEmpty;
    final marketSignals = _evList(marketEv, 'signals')
        .map((signal) => _signalText(signal, e))
        .join(' · ');
    rows.add(_Row(
      name: 'Target market',
      stated: marketStated,
      yourValue: marketStated
          ? customers.map(_tokenWords).join(', ')
          : 'Not stated',
      propertyValue: marketSignals.isEmpty ? 'Not measured' : marketSignals,
      status: marketStated ? _statusOf(marketComp) : _RowStatus.notEnough,
      note: marketStated ? marketComp?.reason : notSaved,
      caution: marketStated ? marketComp?.caution : null,
    ));

    // 3. Rental budget.
    final budgetComp = component('budget_fit');
    final budgetEv = budgetComp?.evidence ?? const {};
    final maxBudget = saved.maxRentMyr;
    final minBudget = saved.minRentMyr;
    final budgetStated = maxBudget != null || (minBudget != null && minBudget > 0);
    String budgetText = 'Not stated';
    if (maxBudget != null && minBudget != null && minBudget > 0) {
      budgetText = 'RM ${metricGrouped(minBudget.round())}–'
          'RM ${metricGrouped(maxBudget.round())}/month';
    } else if (maxBudget != null) {
      budgetText = 'Up to RM ${metricGrouped(maxBudget.round())}/month';
    } else if (minBudget != null && minBudget > 0) {
      budgetText = 'From RM ${metricGrouped(minBudget.round())}/month';
    }
    final rentText = fmtMonthlyRental(_evNum(budgetEv, 'monthly_rental_myr')) ??
        fmtMonthlyRental(property.rentalRm, rentalMaxRm: property.rentalMaxRm) ??
        'Not recorded';
    rows.add(_Row(
      name: 'Rental budget',
      stated: budgetStated,
      yourValue: budgetText,
      propertyValue: rentText,
      status: budgetStated ? _statusOf(budgetComp) : _RowStatus.notEnough,
      note: budgetStated ? budgetComp?.reason : notSaved,
    ));

    // 4. Property size.
    final sizeComp = component('size_fit');
    final sizeEv = sizeComp?.evidence ?? const {};
    final minArea = saved.minFloorAreaSqft;
    final maxArea = saved.maxFloorAreaSqft;
    final sizeStated = minArea != null || maxArea != null;
    String sizeText = 'Not stated';
    if (minArea != null && maxArea != null) {
      sizeText = '${metricGrouped(minArea.round())}–'
          '${metricGrouped(maxArea.round())} sq ft';
    } else if (minArea != null) {
      sizeText = 'At least ${metricGrouped(minArea.round())} sq ft';
    } else if (maxArea != null) {
      sizeText = 'Up to ${metricGrouped(maxArea.round())} sq ft';
    }
    final builtUp = _evNum(sizeEv, 'built_up_sqft') ?? property.builtUpSqft;
    rows.add(_Row(
      name: 'Property size',
      stated: sizeStated,
      yourValue: sizeText,
      propertyValue: builtUp == null
          ? 'Not recorded'
          : '${metricGrouped(builtUp.round())} sq ft',
      status: sizeStated ? _statusOf(sizeComp) : _RowStatus.notEnough,
      note: sizeStated ? sizeComp?.reason : notSaved,
    ));

    // 5. Preferred location — the one preference the rule engine does not
    //    score. The comparison is a plain lexical check of the echoed saved
    //    states/districts against the listing's recorded city/state, the same
    //    documented approach as the engine's own property-type matching. No
    //    distance or score is invented here.
    final states = saved.preferredStates;
    final districts = saved.preferredDistricts;
    final locationStated = states.isNotEmpty || districts.isNotEmpty;
    final locationText = [
      if (states.isNotEmpty) states.join(', '),
      if (districts.isNotEmpty) districts.join(', '),
    ].join(' · ');
    final city = property.city.trim();
    final state = property.state.trim();
    final locationValue = city.isEmpty
        ? (state.isEmpty ? 'Not recorded' : state)
        : (state.isEmpty ? city : '$city, $state');
    _RowStatus locationStatus = _RowStatus.notEnough;
    String? locationNote = notSaved;
    if (locationStated) {
      final stateLower = state.toLowerCase();
      final cityLower = city.toLowerCase();
      final overlap = (stateLower.isNotEmpty &&
              states.any((pref) => pref.trim().toLowerCase() == stateLower)) ||
          (cityLower.isNotEmpty &&
              districts.any((d) => d.trim().toLowerCase() == cityLower));
      locationStatus = overlap ? _RowStatus.matched : _RowStatus.review;
      locationNote = overlap
          ? 'The recorded location is in your saved preferred list (compared '
                'as written text, like the recommendation\'s own checks).'
          : 'The recorded location is not in your saved preferred list '
                '(compared as written text, like the recommendation\'s own '
                'checks).';
    }
    rows.add(_Row(
      name: 'Preferred location',
      stated: locationStated,
      yourValue: locationStated ? locationText : 'Not stated',
      propertyValue: locationValue,
      status: locationStatus,
      note: locationNote,
    ));

    // 6. Accessibility.
    final accessComp = component('accessibility_fit');
    final accessEv = accessComp?.evidence ?? const {};
    final accessMode = saved.customerAccessMode;
    final accessStated = accessMode != null;
    final accessSignals = _evList(accessEv, 'signals')
        .map((signal) => _signalText(signal, e))
        .join(' · ');
    rows.add(_Row(
      name: 'Accessibility',
      stated: accessStated,
      yourValue: accessStated ? _tokenWords(accessMode) : 'Not stated',
      propertyValue: accessSignals.isEmpty ? 'Not measured' : accessSignals,
      status: accessStated ? _statusOf(accessComp) : _RowStatus.notEnough,
      note: accessStated ? accessComp?.reason : notSaved,
    ));

    // 7. Parking.
    final parkingComp = component('parking_fit');
    final parkingEv = parkingComp?.evidence ?? const {};
    final parkingReqs = saved.parkingRequirements;
    final parkingStated = parkingReqs.isNotEmpty;
    final parkingSignals = _evList(parkingEv, 'signals')
        .map((signal) => _signalText(signal, e))
        .join(' · ');
    rows.add(_Row(
      name: 'Parking',
      stated: parkingStated,
      yourValue: parkingStated
          ? parkingReqs.map(_tokenWords).join(', ')
          : 'Not stated',
      propertyValue: parkingSignals.isEmpty ? 'Not measured' : parkingSignals,
      status: parkingStated ? _statusOf(parkingComp) : _RowStatus.notEnough,
      note: parkingStated ? parkingComp?.reason : notSaved,
      caution: parkingStated ? parkingComp?.caution : null,
    ));

    // 8. Competition.
    final competitionComp = component('competition_fit');
    final competitionEv = competitionComp?.evidence ?? const {};
    final tolerance = saved.competitionTolerance;
    final competitionStated = tolerance != null;
    final competitorCount = _evNum(competitionEv, 'fnb_competitors_500m');
    rows.add(_Row(
      name: 'Competition',
      stated: competitionStated,
      yourValue: competitionStated
          ? '${_tokenWords(tolerance)} tolerance'
          : 'Not stated',
      propertyValue: competitorCount == null
          ? 'Not measured'
          : fmtCount(
              competitorCount,
              singular: 'F&B outlet within 500 m',
              plural: 'F&B outlets within 500 m',
            )!,
      status: competitionStated
          ? _statusOf(competitionComp)
          : _RowStatus.notEnough,
      note: competitionStated ? competitionComp?.reason : notSaved,
    ));

    // 9. Physical suitability — only meaningful when the listing records
    //    verified physical attributes; the engine echoes both sides.
    final physicalComp = component('physical_fit');
    final physicalEv = physicalComp?.evidence ?? const {};
    final requirements = _evList(physicalEv, 'physical_requirements');
    final measured = _evList(physicalEv, 'measured');
    rows.add(_Row(
      name: 'Physical suitability',
      stated: requirements.isNotEmpty,
      yourValue: requirements.isNotEmpty
          ? requirements.map(_tokenWords).join(', ')
          : 'Not stated',
      propertyValue:
          measured.isEmpty ? 'Not recorded' : measured.join(' · '),
      status: requirements.isNotEmpty
          ? _statusOf(physicalComp)
          : _RowStatus.notEnough,
      note: requirements.isNotEmpty ? physicalComp?.reason : notSaved,
      caution: requirements.isNotEmpty ? physicalComp?.caution : null,
    ));

    return rows;
  }
}

/// The comparison outcome of one row.
enum _RowStatus { matched, review, notEnough }

/// One preference comparison row.
class _Row {
  final String name;

  /// Whether the entrepreneur actually saved this preference. An unstated
  /// preference is never evaluated — "Not enough data", never a default.
  final bool stated;
  final String yourValue;
  final String propertyValue;
  final _RowStatus status;
  final String? note;
  final String? caution;

  const _Row({
    required this.name,
    required this.stated,
    required this.yourValue,
    required this.propertyValue,
    required this.status,
    this.note,
    this.caution,
  });
}

/// Mirrors `ScoringConfig.strength_threshold` in the backend's
/// `recommendation_scoring.py`: a scored component at or above it is one of
/// the recommendation's own strengths.
const double _kStrengthThreshold = 0.65;

_RowStatus _statusOf(ComponentDetail? component) {
  if (component == null || component.status != 'scored') {
    return _RowStatus.notEnough;
  }
  final value = component.value;
  if (value == null) return _RowStatus.notEnough;
  return value >= _kStrengthThreshold ? _RowStatus.matched : _RowStatus.review;
}

/// Presentation-only wording for the saved questionnaire tokens. Unknown
/// tokens fall back to a de-underscored form — never dropped, never guessed
/// into a different meaning.
String _tokenWords(String token) {
  final t = token.trim();
  return switch (t) {
    'office_workers' => 'Office workers',
    'students' => 'Students',
    'commuters' => 'Commuters',
    'nearby_residents' => 'Nearby residents',
    'general_public' => 'General public',
    'walking' => 'Walking',
    'public_transportation' => 'Public transport',
    'private_vehicle' => 'Private vehicle',
    'mixed_transportation' => 'Mixed transport and driving',
    'low' => 'Low',
    'moderate' => 'Moderate',
    'high' => 'High',
    _ => t.isEmpty ? 'Not stated' : t.replaceAll('_', ' '),
  };
}

/// A demand/access/parking signal label. The backend sends either
/// `feature=value` (already formatted) or a bare feature key; both get the
/// explanation's friendly feature label, never a raw column name.
String _signalText(String signal, PersonalisedExplanation e) {
  final eq = signal.indexOf('=');
  if (eq <= 0) return e.labelFor(signal.trim());
  return '${e.labelFor(signal.substring(0, eq).trim())} '
      '${signal.substring(eq + 1).trim()}';
}

String _orNotRecorded(String? value) {
  final v = value?.trim() ?? '';
  return v.isEmpty ? 'Not recorded' : v;
}

double? _evNum(Map<String, dynamic> evidence, String key) {
  final v = evidence[key];
  if (v is num && v.isFinite) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

String? _evText(Map<String, dynamic> evidence, String key) {
  final v = evidence[key];
  return v is String && v.trim().isNotEmpty ? v.trim() : null;
}

List<String> _evList(Map<String, dynamic> evidence, String key) =>
    (evidence[key] as List?)
        ?.whereType<Object>()
        .map((e) => e.toString())
        .toList(growable: false) ??
    const [];

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
    icon: 'restaurant',
    note: 'Select your business type in Preferences to personalise this page.',
    kind: 'general',
    competitorKey: 'competitor_count_500m',
    competitorLabel: 'F&B businesses',
    competitorIcon: 'restaurant',
  );

  /// Resolves the display from the entrepreneur's selected type text — the
  /// page's resolved selection (Recommendations URL, saved account preference
  /// or browser selection). The pattern chain mirrors the backend's
  /// `match_business_type` vocabulary.
  factory _BusinessDisplay.ofType(String type) =>
      _ofKey(type.trim().toLowerCase(), type.trim());

  /// Shared pattern chain: match on the concept key first, then the human
  /// label, so either vocabulary renders correctly. [rawLabel] is what a
  /// non-empty but unmatched selection shows — the entrepreneur's own words,
  /// never a guessed category.
  static _BusinessDisplay _ofKey(String key, String? rawLabel) {
    if (key.contains('cafe') || key.contains('coffee')) {
      return const _BusinessDisplay(
        label: 'Café & coffee shop',
        icon: 'local_cafe',
        note: 'Coffee, drinks and light meals.',
        kind: 'cafe',
        competitorKey: 'cafe_count_500m',
        competitorLabel: 'Cafés',
        // One supported utensils icon for the competitor fact across every
    // business type: type-specific glyphs rendered inconsistently and made
    // the same measurement look like different things.
    competitorIcon: 'restaurant',
      );
    }
    if (key.contains('bakery') || key.contains('dessert')) {
      return const _BusinessDisplay(
        label: 'Bakery & dessert shop',
        icon: 'bakery_dining',
        note: 'Baked goods and daily purchases.',
        kind: 'bakery',
        competitorKey: 'competitor_count_500m',
        competitorLabel: 'F&B businesses',
        competitorIcon: 'restaurant',
      );
    }
    if (key.contains('fast food') ||
        key.contains('fast') ||
        key.contains('quick')) {
      return const _BusinessDisplay(
        label: 'Fast food & takeaway',
        icon: 'takeout_dining',
        note: 'Quick meals and collection.',
        kind: 'quick',
        competitorKey: 'fast_food_count_500m',
        competitorLabel: 'Fast-food outlets',
        competitorIcon: 'restaurant',
      );
    }
    if (key.contains('beverage') ||
        key.contains('drink') ||
        key.contains('kiosk')) {
      return const _BusinessDisplay(
        label: 'Beverage shop / kiosk',
        icon: 'local_drink',
        note: 'Drinks and grab-and-go service.',
        kind: 'beverage',
        competitorKey: 'competitor_count_500m',
        competitorLabel: 'F&B businesses',
        competitorIcon: 'restaurant',
      );
    }
    if (key.contains('restaurant')) {
      return const _BusinessDisplay(
        label: 'Restaurant',
        icon: 'restaurant',
        note: 'Seated meals and food service.',
        kind: 'restaurant',
        competitorKey: 'restaurant_count_500m',
        competitorLabel: 'Restaurants',
        competitorIcon: 'restaurant',
      );
    }
    if (key.isNotEmpty && rawLabel != null && rawLabel.isNotEmpty) {
      return _BusinessDisplay(
        label: rawLabel,
        icon: 'restaurant',
        note: 'Your selected food business.',
        kind: 'general',
        competitorKey: 'competitor_count_500m',
        competitorLabel: 'F&B businesses',
        competitorIcon: 'restaurant',
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
