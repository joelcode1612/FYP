import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../../data/location_evidence_api.dart';

/// "Who lives in the wider district?" — official DOSM district demographics.
///
/// Every figure here is DISTRICT-WIDE and is labelled that way. It must never
/// be presented as the population or age mix of the people within 500 m or
/// 1 km of the property: DOSM publishes administrative-district statistics,
/// and no validated method exists to redistribute district ages into a
/// walking catchment. The nearby WorldPop estimates are shown next to the
/// district total so the two scopes stay visibly separate, and neither the
/// radius nor the property changes the district block.
///
/// Each block (population with its sex split, age bands, household income) is
/// rendered from its own value and its own reference year, because the DOSM
/// datasets cover different districts and different years. A figure that the
/// source does not publish reads "Not available" with the backend's reason;
/// nothing is estimated, rounded into existence, or carried over from another
/// district to fill a gap.
///
/// The horizontal age bars are plain DOM (a labelled track with a percentage
/// fill), keyboard-reachable via the section itself, and carry per-bar
/// accessible labels with both the count and the share.
class DistrictDemographicsPanel extends StatelessComponent {
  /// The nearby catchment estimates shown beside the district figures.
  final EvidenceMetric? residents500m;
  final EvidenceMetric? residents1km;
  final DistrictStatistics? statistics;

  const DistrictDemographicsPanel({
    super.key,
    required this.statistics,
    this.residents500m,
    this.residents1km,
  });

  static const _barColors = [
    '#6285d3',
    '#366fce',
    '#0f8294',
    '#1d4ed8',
    '#7b70b7',
    '#cc8656',
  ];

  static const _notAvailable = 'Not available';

  /// A headcount or ringgit amount as whole units with thousands separators —
  /// `2,082,300` and `8,837`. People are never counted in fractions, so the
  /// one decimal place DOSM uses for its thousands is dropped here rather than
  /// shown as `.0`. A null stays visibly missing instead of printing `0`.
  static String _fmt(num? value) {
    if (value == null) return _notAvailable;
    return value.round().toString().replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
      (m) => '${m[1]},',
    );
  }

  /// "W.P. Kuala Lumpur" — DOSM publishes the federal territory as both the
  /// state and the district, which would otherwise read twice.
  static String _caption(String? district, String? state) {
    final parts = [district?.trim() ?? '', state?.trim() ?? '']
      ..removeWhere((part) => part.isEmpty);
    return parts.toSet().join(', ');
  }

  String get _scopeLabel {
    final s = statistics;
    if (s == null || !s.available) return 'District data not available';
    final caption = _caption(s.district, s.state);
    return caption.isEmpty ? 'District data not available' : caption;
  }

  /// The four-digit year of an ISO date string, or null when unusable.
  static String? _yearOf(String? iso) {
    if (iso == null || iso.length < 4) return null;
    return iso.substring(0, 4);
  }

  @override
  Component build(BuildContext context) {
    final s = statistics;
    final hasAgeGroups = s != null && s.available && s.ageGroups.isNotEmpty;
    final districtPopulation = s?.districtPopulation;
    final income = s?.incomeMedianMyr;

    return section(
      classes: 'sw-age',
      attributes: const {'aria-labelledby': 'sw-age-title'},
      [
        div(classes: 'sw-age__head', [
          div([
            span(classes: 'sw-pd__eyebrow', [
              Component.text('People and age groups'),
            ]),
            h3(
              attributes: const {'id': 'sw-age-title'},
              [Component.text('Who lives in the wider district?')],
            ),
            p(classes: 'sw-age__lede', [
              Component.text(
                'Official district statistics from the Department of '
                'Statistics Malaysia (DOSM), shown alongside the estimated '
                'number of people living close to this property.',
              ),
            ]),
          ]),
          span(classes: 'sw-age__scope', [Component.text(_scopeLabel)]),
        ]),
        div(classes: 'sw-age__layout', [
          // ------------------------------------------------------------ bars
          div(classes: 'sw-age__main', [
            div(classes: 'sw-age__bar-head', [
              div([
                strong([Component.text('Residents by age')]),
                small([
                  Component.text(
                    hasAgeGroups
                        ? 'District-wide population estimates · DOSM'
                        : 'Official district-wide population estimates · DOSM',
                  ),
                ]),
              ]),
              span(classes: 'sw-age__year', [
                Component.text(
                  hasAgeGroups
                      ? 'DOSM ${s.ageYear ?? 'year not stated'}'
                      : 'No age data',
                ),
              ]),
            ]),
            if (!hasAgeGroups)
              p(classes: 'sw-age__empty', [
                Component.text(
                  s?.ageNote ??
                      s?.reason ??
                      'Age-group figures for this district have not been '
                          'imported yet. Nothing is estimated in their place.',
                ),
              ])
            else ...[
              _ageSection(s),
            ],
          ]),
          // ----------------------------------------------------------- side
          aside(classes: 'sw-age__side', [
            div(classes: 'sw-age__stat', [
              span([Component.text('Estimated residents within 500 m')]),
              strong([
                Component.text(
                  residents500m?.value == null
                      ? _notAvailable
                      : '${_fmt(residents500m?.value)} estimated residents',
                ),
              ]),
              small([
                Component.text(
                  'Neighbourhood estimate · not a DOSM district count',
                ),
              ]),
            ]),
            div(classes: 'sw-age__stat', [
              span([Component.text('Estimated residents within 1 km')]),
              strong([
                Component.text(
                  residents1km?.value == null
                      ? _notAvailable
                      : '${_fmt(residents1km?.value)} estimated residents',
                ),
              ]),
              small([
                Component.text('Neighbourhood estimate · not an age breakdown'),
              ]),
            ]),
            div(classes: 'sw-age__stat sw-age__stat--district', [
              span([Component.text('Residents in the whole district')]),
              strong([
                Component.text(
                  districtPopulation == null
                      ? _notAvailable
                      : '${_fmt(districtPopulation)} people',
                ),
              ]),
              small([
                Component.text(s?.populationNote ?? _districtPopulationNote(s)),
              ]),
            ]),
            if (s?.malePopulation != null || s?.femalePopulation != null)
              div(classes: 'sw-age__people', [
                Component.text(
                  'District population by sex: ${_fmt(s?.malePopulation)} male '
                  '· ${_fmt(s?.femalePopulation)} female '
                  '(DOSM ${_yearOf(s?.populationAsOf) ?? 'year not stated'}).',
                ),
              ]),
          ]),
        ]),
        // ---------------------------------------------------------- source
        div(classes: 'sw-age__source', [
          div([
            strong([Component.text('Where do these figures come from?')]),
            p([
              Component.text(
                'The district population, age groups and household income come '
                'from official DOSM datasets stored in SiteWise\'s analytics '
                'database, joined to the administrative district matched to '
                'this property. Each figure carries the reference year of the '
                'dataset it came from, so the years differ by design.',
              ),
            ]),
          ]),
          span(classes: 'sw-age__income', [
            Component.text(
              income == null
                  ? 'Typical monthly household income in this district: '
                        '$_notAvailable'
                  : 'Typical monthly household income in this district: '
                        'RM ${_fmt(income)}/month '
                        '(${_yearOf(s?.incomeAsOf) ?? 'year not stated'})',
            ),
          ]),
        ]),
      ],
    );
  }

  /// Fallback note for the district card when the backend states no reason for
  /// a missing value — the year travels with the population dataset, never
  /// with the age bands or the income survey.
  static String _districtPopulationNote(DistrictStatistics? stats) {
    final year = _yearOf(stats?.populationAsOf);
    return year == null
        ? 'DOSM district-wide population'
        : 'DOSM district-wide population · $year';
  }

  Component _ageSection(DistrictStatistics stats) {
    // Shares come from the backend only when every displayed group holds its
    // published bands. When they do not, the bars are still drawn to scale
    // against the largest group so the shape stays readable, but the value
    // text carries headcounts and no percentage is claimed.
    final sharesAvailable = stats.ageGroups.every(
      (group) => group.share != null,
    );
    final largest = stats.ageGroups.fold<int>(
      0,
      (best, group) => group.persons == null
          ? best
          : (group.persons! > best ? group.persons! : best),
    );
    return div(classes: 'sw-age__available', [
      if (stats.ageNote != null)
        p(classes: 'sw-age__warning', [Component.text(stats.ageNote!)]),
      div(
        classes: 'sw-age__bars',
        attributes: const {'aria-live': 'polite'},
        [
          for (final (index, group) in stats.ageGroups.indexed)
            _ageBar(
              group,
              _barColors[index % _barColors.length],
              sharesAvailable: sharesAvailable,
              largest: largest,
            ),
        ],
      ),
      p(classes: 'sw-age__warning', [
        Component.text(
          '${stats.ageYear ?? 'The latest available'} district figures '
          'describe the whole administrative district, not the ages of '
          'people within 500 m or 1 km of this property. District ages are '
          'not used to calculate the recommendation score.',
        ),
      ]),
    ]);
  }

  Component _ageBar(
    DistrictAgeGroup group,
    String color, {
    required bool sharesAvailable,
    required int largest,
  }) {
    final persons = group.persons;
    final share = group.share;
    final percent = persons == null
        ? 0.0
        : sharesAvailable && share != null
        ? (share * 100).clamp(0.0, 100.0)
        : (largest <= 0 ? 0.0 : persons / largest * 100).clamp(0.0, 100.0);
    final hasShare = sharesAvailable && share != null;
    final valueLabel = persons == null
        ? 'No data'
        : hasShare
        ? '${percent.toStringAsFixed(1)}%'
        : _fmt(persons);
    return div(
      classes: 'sw-age__bar',
      attributes: {
        'role': 'img',
        'aria-label': persons == null
            ? 'Age ${group.label}: no district figure published'
            : 'Age ${group.label}: ${_fmt(persons)} people'
                  '${hasShare ? ', ${percent.toStringAsFixed(1)} percent' : ''}',
      },
      [
        span(classes: 'sw-age__bar-label', [Component.text(group.label)]),
        span(classes: 'sw-age__track', [
          span(
            classes: 'sw-age__fill',
            attributes: {
              'style':
                  'width:${percent.toStringAsFixed(2)}%;--sw-age-color:$color',
            },
            const [],
          ),
        ]),
        span(classes: 'sw-age__bar-value', [
          Component.text(valueLabel),
          small([
            Component.text(
              persons == null
                  ? 'no published bands'
                  : '${_fmt(persons)} people',
            ),
          ]),
        ]),
      ],
    );
  }
}
