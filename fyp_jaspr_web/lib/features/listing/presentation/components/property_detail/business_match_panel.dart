import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import 'package:sitewise_jaspr_web/core/utils/metric_format.dart';
import 'package:sitewise_jaspr_web/shared/presentation/components/ui.dart';

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
      classes: 'sw-matchdetail sw-matchdetail--refined',
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

/// The entrepreneur's selected food business, rendered as a display name.
///
/// The pattern chain mirrors the backend's `match_business_type` vocabulary,
/// so a selection stored as a concept key and one stored as human words both
/// resolve. An unmatched selection keeps the entrepreneur's own text — it is
/// never renamed into a category the page cannot verify — and an empty
/// selection falls back to a neutral F&B name rather than a guessed one.
class _BusinessDisplay {
  final String label;

  const _BusinessDisplay({required this.label});

  static const _fallback = _BusinessDisplay(label: 'Your food business');

  /// Resolves the display from the entrepreneur's selected type text — the
  /// page's resolved selection (Recommendations URL, saved account preference
  /// or browser selection).
  factory _BusinessDisplay.ofType(String type) =>
      _ofKey(type.trim().toLowerCase(), type.trim());

  static _BusinessDisplay _ofKey(String key, String rawLabel) {
    if (key.contains('cafe') || key.contains('coffee')) {
      return const _BusinessDisplay(label: 'Café & coffee shop');
    }
    if (key.contains('bakery') || key.contains('dessert')) {
      return const _BusinessDisplay(label: 'Bakery & dessert shop');
    }
    if (key.contains('fast food') ||
        key.contains('fast') ||
        key.contains('quick')) {
      return const _BusinessDisplay(label: 'Fast food & takeaway');
    }
    if (key.contains('beverage') ||
        key.contains('drink') ||
        key.contains('kiosk')) {
      return const _BusinessDisplay(label: 'Beverage shop / kiosk');
    }
    if (key.contains('restaurant')) {
      return const _BusinessDisplay(label: 'Restaurant');
    }
    if (rawLabel.isNotEmpty) {
      return _BusinessDisplay(label: rawLabel);
    }
    return _fallback;
  }
}
