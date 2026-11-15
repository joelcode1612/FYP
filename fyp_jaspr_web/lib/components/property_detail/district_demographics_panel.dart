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
/// district total so the two scopes stay visibly separate.
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

  static String _fmt(num? value) {
    if (value == null) return 'Not available';
    final whole = value.toDouble();
    if (whole == whole.roundToDouble()) {
      return whole.round().toString().replaceAllMapped(
            RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
            (m) => '${m[1]},',
          );
    }
    return whole.toStringAsFixed(1);
  }

  String get _scopeLabel {
    final s = statistics;
    if (s == null || !s.available) return 'District data not available';
    final district = s.district?.trim() ?? '';
    final state = s.state?.trim() ?? '';
    return [district, state].where((part) => part.isNotEmpty).join(', ');
  }

  @override
  Component build(BuildContext context) {
    final s = statistics;
    final available = s != null && s.available && s.ageGroups.isNotEmpty;

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
                    available
                        ? 'District-wide population estimates · DOSM'
                        : 'Official district-wide population estimates · DOSM',
                  ),
                ]),
              ]),
              span(
                classes: 'sw-age__year',
                [Component.text(available ? 'DOSM ${s.ageYear ?? ''}' : 'No age data')],
              ),
            ]),
            if (!available)
              p(classes: 'sw-age__empty', [
                Component.text(
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
              strong([Component.text(_fmt(residents500m?.value))]),
              small([
                Component.text(
                  'Neighbourhood estimate · not a DOSM district count',
                ),
              ]),
            ]),
            div(classes: 'sw-age__stat', [
              span([Component.text('Estimated residents within 1 km')]),
              strong([Component.text(_fmt(residents1km?.value))]),
              small([
                Component.text(
                  'Neighbourhood estimate · not an age breakdown',
                ),
              ]),
            ]),
            div(classes: 'sw-age__stat sw-age__stat--district', [
              span([Component.text('Residents in the whole district')]),
              strong([
                Component.text(
                  available ? _fmt(s.districtPopulation ?? s.totalPopulation) : 'Not available',
                ),
              ]),
              small([
                Component.text(
                  available
                      ? _districtPopulationNote(s)
                      : 'Available when the district match succeeds',
                ),
              ]),
            ]),
            if (available &&
                (s.malePopulation != null || s.femalePopulation != null))
              div(classes: 'sw-age__people', [
                Component.text(
                  'District population by sex: ${_fmt(s.malePopulation)} male '
                  '· ${_fmt(s.femalePopulation)} female (DOSM ${s.ageYear}).',
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
                'database, joined to this property\'s recorded district.',
              ),
            ]),
          ]),
          span(classes: 'sw-age__income', [
            Component.text(
              available && s.incomeMedianMyr != null
                  ? 'Typical monthly household income in this district: '
                      'RM ${_fmt(s.incomeMedianMyr)} (${_yearOf(s.incomeAsOf) ?? 'year not stated'})'
                  : 'Typical monthly household income in this district: '
                      'Not available',
            ),
          ]),
        ]),
      ],
    );
  }

  /// The four-digit year of an ISO date string, or null when unusable.
  static String? _yearOf(String? iso) {
    if (iso == null || iso.length < 4) return null;
    return iso.substring(0, 4);
  }

  static String _districtPopulationNote(DistrictStatistics stats) {
    final year = _yearOf(stats.populationAsOf);
    return year == null
        ? 'DOSM district-wide population'
        : 'DOSM district-wide population · $year';
  }

  Component _ageSection(DistrictStatistics stats) {
    return div(classes: 'sw-age__available', [
      div(
        classes: 'sw-age__bars',
        attributes: const {'aria-live': 'polite'},
        [
          for (final (index, group) in stats.ageGroups.indexed)
            _ageBar(group, _barColors[index % _barColors.length]),
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

  Component _ageBar(DistrictAgeGroup group, String color) {
    final share = group.share;
    final pct = share == null ? 0.0 : (share * 100).clamp(0.0, 100.0);
    final shareLabel = share == null ? '' : ' ${pct.toStringAsFixed(1)} percent';
    return div(
      classes: 'sw-age__bar',
      attributes: {
        'role': 'img',
        'aria-label':
            'Age ${group.label}: ${_fmt(group.persons)} people,$shareLabel',
      },
      [
        span(classes: 'sw-age__bar-label', [
          Component.text(group.label),
        ]),
        span(classes: 'sw-age__track', [
          span(
            classes: 'sw-age__fill',
            attributes: {'style': 'width:${pct.toStringAsFixed(2)}%;--sw-age-color:$color'},
            const [],
          ),
        ]),
        span(classes: 'sw-age__bar-value', [
          Component.text(share == null ? _fmt(group.persons) : '${pct.toStringAsFixed(1)}%'),
          small([Component.text('${_fmt(group.persons)} people')]),
        ]),
      ],
    );
  }
}
