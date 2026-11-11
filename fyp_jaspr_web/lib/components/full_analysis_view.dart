/// The Full Analysis page body — sections A–J of the SiteWise location-evidence
/// design, rendered as native Jaspr components from real backend data.
///
/// This file only formats and visualizes. Every figure comes from [FullAnalysis]
/// (the trained artifact's metadata, the resolved measurements, or the persisted
/// validated SHAP explanation). A null is "Not recorded"; an unavailable model,
/// explanation or assessment renders an honest empty state, never a fabricated
/// number. The SHAP waterfall is emitted as static SVG from the persisted
/// contributions — no client-side scoring and no embedded research dataset.
library;

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import '../data/full_analysis_format.dart';
import 'property_leaflet_map.dart';
import 'ui.dart';

/// Renders every section. The owning page holds the interactive state (selected
/// category, table search, copy feedback) and passes it down with callbacks.
class FullAnalysisBody extends StatelessComponent {
  final FullAnalysis analysis;
  final String selectedCategory;
  final void Function(String) onSelectCategory;
  final String search;
  final void Function(String) onSearch;
  final bool copied;
  final void Function() onCopy;
  final void Function() onPrint;
  final String assessmentHref;
  final String reportHref;
  final bool signedIn;

  /// Why no validated explanation is shown (not signed in, no assessment, not
  /// generated yet, or withheld for failing additivity). Null when one exists.
  final String? explanationNote;

  const FullAnalysisBody({
    super.key,
    required this.analysis,
    required this.selectedCategory,
    required this.onSelectCategory,
    required this.search,
    required this.onSearch,
    required this.copied,
    required this.onCopy,
    required this.onPrint,
    required this.assessmentHref,
    required this.reportHref,
    required this.signedIn,
    this.explanationNote,
  });

  @override
  Component build(BuildContext context) {
    final property = analysis.property!;
    return div(classes: 'fa', [
      _Intro(copied: copied, onCopy: onCopy, onPrint: onPrint),
      _Notice(signedIn: signedIn),
      _Overview(analysis: analysis, property: property),
      _MapRow(analysis: analysis, property: property),
      _Evidence(
        analysis: analysis,
        selectedCategory: selectedCategory,
        onSelect: onSelectCategory,
      ),
      _Explanation(
        analysis: analysis,
        search: search,
        onSearch: onSearch,
        assessmentHref: assessmentHref,
        explanationNote: explanationNote,
      ),
      _Targets(
        analysis: analysis,
        assessmentHref: assessmentHref,
        signedIn: signedIn,
      ),
      _Summary(
        analysis: analysis,
        property: property,
        reportHref: reportHref,
        onPrint: onPrint,
      ),
      footer(classes: 'fa-footer', [
        Component.text(
          'Sitewise decision-support · Research association score, not a '
          'probability of F&B business success · Measurements are research '
          'inputs, not observed customer visits.',
        ),
      ]),
    ]);
  }
}

// ---------------------------------------------------------------------------
//  Intro + research notice
// ---------------------------------------------------------------------------

class _Intro extends StatelessComponent {
  final bool copied;
  final void Function() onCopy;
  final void Function() onPrint;

  const _Intro({
    required this.copied,
    required this.onCopy,
    required this.onPrint,
  });

  @override
  Component build(BuildContext context) => div(classes: 'fa-intro', [
    div(classes: 'fa-intro__text', [
      span(classes: 'fa-eyebrow', [
        Component.text('LOCATION ASSESSMENT · STAGE 3 & 4'),
      ]),
      h1([Component.text('Understand the property and its AI score.')]),
      p([
        Component.text(
          'Review property details, explore all five geographical evidence '
          'groups, and see a plain-language explanation of why the research '
          'model produced its result.',
        ),
      ]),
    ]),
    div(classes: 'fa-actions', [
      button(
        classes: 'fa-btn',
        attributes: const {'type': 'button'},
        events: events(onClick: onCopy),
        [
          Icon('content_copy', size: 'sm'),
          Component.text(copied ? 'Copied' : 'Copy explanation'),
        ],
      ),
      button(
        classes: 'fa-btn fa-btn--primary',
        attributes: const {'type': 'button'},
        events: events(onClick: onPrint),
        [Icon('print', size: 'sm'), Component.text('Print analysis')],
      ),
    ]),
  ]);
}

class _Notice extends StatelessComponent {
  final bool signedIn;
  const _Notice({required this.signedIn});

  @override
  Component build(BuildContext context) => div(classes: 'fa-notice', [
    span(classes: 'fa-notice__symbol', [Icon('info', size: 'sm')]),
    span([
      strong([Component.text('Research decision-support. ')]),
      Component.text(
        'The score is an uncalibrated positive-versus-unlabeled research '
        'association, not the likelihood of business success. '
        '${signedIn ? 'Explanation and target matching read your persisted assessment; loading this page never computes SHAP or advances a stage.' : 'Sign in to read your persisted explanation and business-target matching.'}',
      ),
    ]),
  ]);
}

// ---------------------------------------------------------------------------
//  A — Property overview  +  B — PU research score
// ---------------------------------------------------------------------------

class _Overview extends StatelessComponent {
  final FullAnalysis analysis;
  final CommercialProperty property;
  const _Overview({required this.analysis, required this.property});

  @override
  Component build(BuildContext context) => section(
    classes: 'fa-overview',
    attributes: const {'aria-label': 'Property overview and model score'},
    [_PropertyHero(property: property), _ScorePanel(analysis: analysis)],
  );
}

class _PropertyHero extends StatelessComponent {
  final CommercialProperty property;
  const _PropertyHero({required this.property});

  @override
  Component build(BuildContext context) {
    final location = [
      property.address,
      property.city,
      property.state,
    ].where((part) => part.trim().isNotEmpty).join(' · ');
    final psf =
        property.psf ?? (property.sizeSqft > 0 ? property.rentalPerSqft : null);
    final sourceHost = () {
      final url = property.sourceUrl;
      if (url == null || url.isEmpty) return null;
      final host = Uri.tryParse(url)?.host;
      return (host == null || host.isEmpty) ? url : host;
    }();

    return div(classes: 'fa-panel fa-hero', [
      div([
        div(classes: 'fa-hero__meta', [
          span(classes: 'fa-prop-id', [
            Component.text('PROPERTY ${property.id}'),
          ]),
          Pill(
            property.verification.label,
            tone: toneForVerification(property.verification),
          ),
        ]),
        h2(classes: 'fa-prop-name', [Component.text(property.title)]),
        p(classes: 'fa-prop-location', [
          Component.text(location.isEmpty ? 'Location not recorded' : location),
        ]),
        if (property.availability != null &&
            property.availability!.trim().isNotEmpty)
          p(classes: 'fa-prop-availability', [
            Icon('event_available', size: 'sm'),
            Component.text('Availability: ${property.availability}'),
          ]),
      ]),
      div([
        div(classes: 'fa-details', [
          _detail('Monthly rental', '${property.rentalDisplay}/mo'),
          _detail(
            'Built-up area',
            property.sizeSqft > 0
                ? '${faNum(property.sizeSqft)} sqft'
                : 'Not recorded',
          ),
          _detail(
            'Property type',
            property.propertyType.isEmpty
                ? 'Not recorded'
                : property.propertyType,
          ),
          _detail(
            'Rental / sqft',
            psf == null ? 'Not recorded' : 'RM ${faNum(psf, decimals: 2)}',
            note: property.psf == null && psf != null
                ? 'Derived from rental ÷ area'
                : null,
          ),
          _detail('Floor level', property.floorLevel ?? 'Not recorded'),
          Component.element(
            tag: 'div',
            classes: 'fa-detail',
            children: [
              small([Component.text('Listing source')]),
              if (sourceHost == null)
                b([Component.text('Not recorded')])
              else
                b([
                  a(
                    href: property.sourceUrl!,
                    attributes: const {
                      'target': '_blank',
                      'rel': 'noopener noreferrer',
                    },
                    [Component.text(sourceHost)],
                  ),
                ]),
            ],
          ),
        ]),
        p(classes: 'fa-prop-note', [
          Component.text(
            'Details are the original listing snapshot and have not been '
            'reverified. The model score does not establish F&B approval or '
            'listing availability.',
          ),
        ]),
      ]),
    ]);
  }

  Component _detail(String label, String value, {String? note}) =>
      div(classes: 'fa-detail', [
        small([Component.text(label)]),
        b([Component.text(value)]),
        if (note != null)
          span(classes: 'fa-detail__note', [Component.text(note)]),
      ]);
}

class _ScorePanel extends StatelessComponent {
  final FullAnalysis analysis;
  const _ScorePanel({required this.analysis});

  @override
  Component build(BuildContext context) {
    final score = analysis.score;
    final model = analysis.model;
    final explanation = analysis.explanation;
    final hasShap = analysis.hasValidShap;
    final association = score?.positiveLabelAssociation;
    final featureSet =
        model?.featureSet ?? explanation?.featureSet ?? 'Not recorded';
    final featureCount =
        model?.featureCount ??
        explanation?.featureCount ??
        (analysis.featureSpecs.isEmpty ? null : analysis.featureSpecs.length);
    final modelKind = model?.modelKind;

    final coverage = analysis.coverage;
    final recorded =
        coverage?.availableFeatures ??
        score?.availableFeatures ??
        explanation?.values.values.where((v) => v != null).length;
    final total =
        coverage?.featureCount ??
        score?.featureCount ??
        featureCount ??
        analysis.featureSpecs.length;

    final fillPct = association == null
        ? 0.0
        : (association * 100).clamp(0.0, 100.0);
    final baselinePct = hasShap
        ? (explanation!.baseValue * 100).clamp(0.0, 100.0)
        : null;

    return div(classes: 'fa-panel fa-score', [
      span(classes: 'fa-score__label', [
        Component.text('PU research association score'),
      ]),
      div(classes: 'fa-score__number', [
        Component.text(
          association == null ? 'Unavailable' : faPct(association),
        ),
      ]),
      p(classes: 'fa-score__explain', [
        Component.text(
          'Selected $featureSet · ${featureCount ?? '—'} model features'
          '${modelKind == null ? '' : ' · $modelKind'}',
        ),
      ]),
      if (association == null && score?.reason != null)
        p(classes: 'fa-score__reason', [Component.text(score!.reason!)]),
      div(classes: 'fa-score__track', [
        div(
          classes: 'fa-score__fill',
          attributes: {'style': 'width:${fillPct.toStringAsFixed(2)}%'},
          [],
        ),
        if (baselinePct != null)
          div(
            classes: 'fa-score__baseline-mark',
            attributes: {'style': 'left:${baselinePct.toStringAsFixed(2)}%'},
            [],
          ),
      ]),
      div(classes: 'fa-score__baseline', [
        span([Component.text('Selected property score')]),
        strong([
          Component.text(
            'SHAP baseline: ${hasShap ? faPct(explanation!.baseValue) : 'Not generated'}',
          ),
        ]),
      ]),
      div(classes: 'fa-score__delta', [
        span([
          Component.text('Total effect of ${featureCount ?? '—'} features'),
        ]),
        strong(
          classes: hasShap
              ? (explanation!.netContribution >= 0
                    ? 'fa-positive'
                    : 'fa-negative')
              : '',
          [
            Component.text(
              hasShap
                  ? '${faSigned(explanation!.netContribution * 100, decimals: 2)} pp'
                  : 'Not generated',
            ),
          ],
        ),
      ]),
      div(classes: 'fa-score__coverage', [
        Icon('fact_check', size: 'sm'),
        Component.text(
          recorded == null
              ? 'Feature coverage not recorded'
              : '$recorded of $total features recorded'
                    '${total - recorded > 0 ? ' · ${total - recorded} missing' : ''}',
        ),
      ]),
      p(classes: 'fa-score__warning', [
        Component.text(
          'This is an uncalibrated positive-versus-unlabeled research score, ',
        ),
        strong([Component.text('not')]),
        Component.text(
          ' the likelihood of business success or a personalized '
          'recommendation. It is also separate from the 0–100 suitability '
          'score used elsewhere in SiteWise.',
        ),
      ]),
    ]);
  }
}

// ---------------------------------------------------------------------------
//  C — Map + provenance facts
// ---------------------------------------------------------------------------

class _MapRow extends StatelessComponent {
  final FullAnalysis analysis;
  final CommercialProperty property;
  const _MapRow({required this.analysis, required this.property});

  @override
  Component build(BuildContext context) {
    final coords = property.hasCoordinates
        ? '${faNum(property.latitude, decimals: 5)}, ${faNum(property.longitude, decimals: 5)}'
        : 'No coordinates recorded';
    final limitations = analysis.limitations;
    return section(
      classes: 'fa-map-row',
      attributes: const {'aria-label': 'Location map and provenance'},
      [
        div(classes: 'fa-panel fa-pad', [
          div(classes: 'fa-section-head', [
            div([
              h3([Component.text('Property location map')]),
              p([
                Component.text(
                  'Circular straight-line radius; not travel distance',
                ),
              ]),
            ]),
          ]),
          PropertyLeafletMap(property: property, height: 340, radius: 500),
          p(classes: 'fa-map-caption', [
            Component.text('Coordinates: '),
            strong([Component.text(coords)]),
            Component.text(
              ' · Radius selectable inside the map · © OpenStreetMap contributors, © CARTO when tiles load',
            ),
          ]),
        ]),
        div(classes: 'fa-panel fa-pad fa-facts', [
          div(classes: 'fa-section-head', [
            div([
              h3([Component.text('Before interpreting the analysis')]),
              p([
                Component.text('What the evidence does and does not establish'),
              ]),
            ]),
          ]),
          div(classes: 'fa-facts__list', [
            _fact(
              'Location measurements',
              'Population estimates, nearby facilities and travel-network '
                  'metrics are research inputs — not observed customer visits.',
            ),
            _fact(
              'Quality of inputs',
              limitations.missingFeatures.isEmpty
                  ? 'Every model feature resolved for this property. Values use '
                        'the fitted model\'s original preprocessing.'
                  : '${limitations.missingFeatures.length} model feature(s) '
                        'unresolved: ${limitations.missingFeatures.take(4).join(', ')}'
                        '${limitations.missingFeatures.length > 4 ? '…' : ''}. '
                        'Missing values are never shown as zero.',
            ),
            _fact(
              'Unknown property conditions',
              'Verify actual availability, F&B licensing, landlord permission, '
                  'utilities and site access independently.',
            ),
            if (limitations.flags.isNotEmpty)
              _fact('Data-quality flags', limitations.flags.join(' · ')),
          ]),
        ]),
      ],
    );
  }

  Component _fact(String title, String body) => div(classes: 'fa-fact', [
    strong([Component.text(title)]),
    span([Component.text(body)]),
  ]);
}

// ---------------------------------------------------------------------------
//  D — Five geospatial category cards + detail + guide
// ---------------------------------------------------------------------------

class _Evidence extends StatelessComponent {
  final FullAnalysis analysis;
  final String selectedCategory;
  final void Function(String) onSelect;
  const _Evidence({
    required this.analysis,
    required this.selectedCategory,
    required this.onSelect,
  });

  @override
  Component build(BuildContext context) {
    final categories = analysis.categories;
    if (categories.isEmpty) {
      return section(classes: 'fa-section', [
        _sectionHeading(
          '01 / LOCATION EVIDENCE',
          'Five complete evidence categories',
          'Choose a category to see its measurements and model influence.',
        ),
        const EmptyState(
          title: 'Feature taxonomy unavailable',
          body:
              'The model metadata could not be read, so the five evidence '
              'categories cannot be listed. No measurements are invented.',
        ),
      ]);
    }
    final byName = {for (final m in analysis.measurements) m.name: m};
    final selected = categories.firstWhere(
      (c) => c.key == selectedCategory,
      orElse: () => categories.first,
    );
    final total = categories.fold<int>(0, (sum, c) => sum + c.featureCount);
    return section(
      classes: 'fa-section',
      attributes: const {'id': 'fa-evidence'},
      [
        div(classes: 'fa-section-heading', [
          div([
            span(classes: 'fa-step-label', [
              Component.text('01 / LOCATION EVIDENCE'),
            ]),
            h2([Component.text('Five complete evidence categories')]),
            p([
              Component.text(
                'Choose a category. Each one shows its key measurements, every '
                'available model feature, the SHAP impact and the evidence '
                'limitations.',
              ),
            ]),
          ]),
          span(classes: 'fa-badge', [
            Component.text(
              '$total features across ${categories.length} categories',
            ),
          ]),
        ]),
        div(classes: 'fa-category-cards', [
          for (final c in categories)
            _CategoryCard(
              category: c,
              byName: byName,
              selected: c.key == selected.key,
              onSelect: () => onSelect(c.key),
            ),
        ]),
        div(classes: 'fa-evidence-grid', [
          _CategoryDetail(category: selected, hasShap: analysis.hasValidShap),
          _CategoryGuide(category: selected, hasShap: analysis.hasValidShap),
        ]),
      ],
    );
  }
}

class _CategoryCard extends StatelessComponent {
  final GeospatialCategorySummary category;
  final Map<String, FeatureMeasurement> byName;
  final bool selected;
  final void Function() onSelect;
  const _CategoryCard({
    required this.category,
    required this.byName,
    required this.selected,
    required this.onSelect,
  });

  @override
  Component build(BuildContext context) {
    final spec = faCategorySpecs[category.key];
    final main = spec == null ? null : byName[spec.mainFeature];
    final second = spec == null ? null : byName[spec.secondFeature];
    final contribution = category.contribution;
    return button(
      classes: 'fa-category-card',
      attributes: {
        'type': 'button',
        'aria-pressed': selected ? 'true' : 'false',
      },
      events: events(onClick: onSelect),
      [
        span(classes: 'fa-cat-icon', [
          Icon(spec?.icon ?? 'category', size: 'sm'),
        ]),
        span(classes: 'fa-cat-name', [Component.text(category.label)]),
        span(classes: 'fa-cat-count', [
          Component.text('${category.featureCount} model features'),
        ]),
        span(classes: 'fa-cat-value', [
          Component.text(faNum(main?.value, decimals: _decimals(main?.value))),
        ]),
        if (spec != null) ...[
          span(classes: 'fa-cat-value-label', [
            Component.text(faFeatureLabel(spec.mainFeature)),
          ]),
          span(classes: 'fa-cat-value-label', [
            Component.text('${faFeatureLabel(spec.secondFeature)}: '),
            b([
              Component.text(
                faNum(second?.value, decimals: _decimals(second?.value)),
              ),
            ]),
          ]),
        ],
        span(
          classes:
              'fa-cat-impact ${contribution == null ? '' : (contribution >= 0 ? 'fa-positive' : 'fa-negative')}',
          [
            Component.text(
              contribution == null
                  ? 'SHAP not generated'
                  : '${faSigned(contribution)} SHAP · net',
            ),
          ],
        ),
      ],
    );
  }

  static int _decimals(double? v) =>
      (v == null || v == v.roundToDouble()) ? 0 : 2;
}

class _CategoryDetail extends StatelessComponent {
  final GeospatialCategorySummary category;
  final bool hasShap;
  const _CategoryDetail({required this.category, required this.hasShap});

  @override
  Component build(BuildContext context) {
    final measured = category.features
        .where((f) => f.hasValue)
        .take(6)
        .toList();
    return div(classes: 'fa-panel fa-pad fa-category-detail', [
      div(classes: 'fa-section-head', [
        div([
          h3([Component.text(category.label)]),
          p([
            Component.text(
              'All ${category.featureCount} research features · exact stored measurements',
            ),
          ]),
        ]),
        span(classes: 'fa-badge', [
          Component.text('${category.featureCount} features'),
        ]),
      ]),
      p(classes: 'fa-data-context', [
        Component.text(
          'These values describe the recorded research data at different '
          'spatial scales. A 500 m circular count is not the same as a '
          '10-minute walking network catchment.',
        ),
      ]),
      if (measured.isNotEmpty)
        div(classes: 'fa-metric-grid', [
          for (final m in measured)
            div(classes: 'fa-metric', [
              strong([
                Component.text(faNum(m.value, decimals: _decimals(m.value))),
              ]),
              small([Component.text(faFeatureLabel(m.name))]),
              span(classes: 'fa-unit', [Component.text(faUnit(m.name))]),
            ]),
        ]),
      div(classes: 'fa-table-scroller', [
        table(classes: 'fa-evidence-table', [
          thead([
            tr([
              th([Component.text('Geospatial feature')]),
              th([Component.text('Measured value')]),
              th([Component.text('Unit')]),
              th([Component.text('SHAP effect')]),
            ]),
          ]),
          tbody([
            for (final m in category.features)
              tr([
                td([Component.text(faFeatureLabel(m.name))]),
                td([Component.text(faNum(m.value, decimals: 3))]),
                td([Component.text(faUnit(m.name))]),
                td(
                  classes: m.shap == null
                      ? ''
                      : (m.shap! >= 0 ? 'fa-positive' : 'fa-negative'),
                  [
                    Component.text(
                      m.shap == null
                          ? 'Not generated'
                          : faSigned(m.shap, decimals: 4),
                    ),
                  ],
                ),
              ]),
          ]),
        ]),
      ]),
    ]);
  }

  static int _decimals(double? v) =>
      (v == null || v == v.roundToDouble()) ? 0 : 2;
}

class _CategoryGuide extends StatelessComponent {
  final GeospatialCategorySummary category;
  final bool hasShap;
  const _CategoryGuide({required this.category, required this.hasShap});

  @override
  Component build(BuildContext context) {
    final spec = faCategorySpecs[category.key];
    final strongest = category.strongestInfluence;
    final contribution = category.contribution;
    return div(classes: 'fa-panel fa-pad fa-guide', [
      div(classes: 'fa-section-head', [
        div([
          h3([Component.text('What does this category mean?')]),
          p([Component.text('How to understand the measurements')]),
        ]),
      ]),
      div(classes: 'fa-impact-line', [
        span([Component.text('Net effect on model score')]),
        strong(
          classes: contribution == null
              ? ''
              : (contribution >= 0 ? 'fa-positive' : 'fa-negative'),
          [
            Component.text(
              contribution == null
                  ? 'Not generated'
                  : faSigned(contribution, decimals: 4),
            ),
          ],
        ),
      ]),
      div(classes: 'fa-guide-block', [
        strong([Component.text('What these data describe')]),
        p([
          Component.text(
            spec?.description ??
                'These are research measurements grouped by the model\'s own '
                    'feature taxonomy.',
          ),
        ]),
      ]),
      div(classes: 'fa-guide-block', [
        strong([Component.text('Strongest model influence here')]),
        p([
          Component.text(
            strongest == null
                ? 'No validated SHAP explanation yet, so model influence is not shown.'
                : '${faFeatureLabel(strongest.name)} has the largest absolute '
                      'SHAP effect in this category (${faSigned(strongest.shap, decimals: 4)}); '
                      'its recorded feature value is ${faNum(strongest.value, decimals: 3)}. '
                      'This is model influence, not evidence of cause.',
          ),
        ]),
      ]),
      div(classes: 'fa-guide-block fa-guide-block--warn', [
        strong([Component.text('What remains uncertain')]),
        p([
          Component.text(
            spec?.limitation ??
                'Coverage and method vary by source; verify conditions independently.',
          ),
        ]),
      ]),
    ]);
  }
}

// ---------------------------------------------------------------------------
//  E — SHAP waterfall  +  F — narrative  +  G — drivers  +  H — table
// ---------------------------------------------------------------------------

class _Explanation extends StatelessComponent {
  final FullAnalysis analysis;
  final String search;
  final void Function(String) onSearch;
  final String assessmentHref;
  final String? explanationNote;
  const _Explanation({
    required this.analysis,
    required this.search,
    required this.onSearch,
    required this.assessmentHref,
    this.explanationNote,
  });

  @override
  Component build(BuildContext context) {
    final hasShap = analysis.hasValidShap;
    final explanation = analysis.explanation;
    final featureCount =
        explanation?.featureCount ?? analysis.featureSpecs.length;
    final String additivityLabel;
    final String additivityClass;
    if (hasShap) {
      additivityLabel = '✓ $featureCount contributions verified';
      additivityClass = 'fa-badge fa-badge--good';
    } else if (explanation != null && !explanation.isAdditive) {
      additivityLabel = '! Explanation mismatch — withheld';
      additivityClass = 'fa-badge fa-badge--warning';
    } else {
      additivityLabel = 'Explanation not generated';
      additivityClass = 'fa-badge fa-badge--warning';
    }

    return section(
      classes: 'fa-section',
      attributes: const {'id': 'fa-explanation'},
      [
        div(classes: 'fa-section-heading', [
          div([
            span(classes: 'fa-step-label', [
              Component.text('02 / EXPLAINABLE AI'),
            ]),
            h2([Component.text('Why did the model produce this score?')]),
            p([
              Component.text(
                'The chart shows how five category contributions move the model '
                'from its reference baseline to this property\'s actual output. '
                'The explanation beside it uses the same values.',
              ),
            ]),
          ]),
          span(classes: additivityClass, [Component.text(additivityLabel)]),
        ]),
        if (hasShap) ...[
          div(classes: 'fa-shap-layout', [
            _WaterfallPanel(analysis: analysis),
            _NarrativePanel(analysis: analysis),
          ]),
          _DriversPanel(analysis: analysis),
        ] else
          div(classes: 'fa-panel fa-pad fa-unavailable', [
            h3([Component.text('No validated SHAP explanation to show')]),
            p([
              Component.text(
                explanationNote ??
                    'Generate the AI explanation in your assessment workspace '
                        '(Stage 4). Reading this page never computes SHAP or '
                        'advances a stage.',
              ),
            ]),
            ActionLink(
              'Open assessment workspace',
              href: assessmentHref,
              variant: 'secondary',
              icon: 'arrow_forward',
            ),
          ]),
        if (analysis.featureSpecs.isNotEmpty)
          _AdvancedTable(
            analysis: analysis,
            search: search,
            onSearch: onSearch,
            hasShap: hasShap,
          ),
      ],
    );
  }
}

class _WaterfallPanel extends StatelessComponent {
  final FullAnalysis analysis;
  const _WaterfallPanel({required this.analysis});

  @override
  Component build(BuildContext context) {
    final e = analysis.explanation!;
    return div(classes: 'fa-panel fa-pad fa-shap-main', [
      div(classes: 'fa-section-head', [
        div([
          h3([Component.text('Simple SHAP waterfall')]),
          p([
            Component.text('Baseline + category contributions = model output'),
          ]),
        ]),
      ]),
      div(classes: 'fa-formula', [
        div([
          small([Component.text('Baseline')]),
          b([Component.text(faPct(e.baseValue))]),
        ]),
        span(classes: 'fa-op', [Component.text('+')]),
        div([
          small([Component.text('Net SHAP effect')]),
          b([
            Component.text(
              '${faSigned(e.netContribution * 100, decimals: 2)} pp',
            ),
          ]),
        ]),
        span(classes: 'fa-op', [Component.text('=')]),
        div([
          small([Component.text('Model output')]),
          b([Component.text(faPct(e.output))]),
        ]),
      ]),
      div(classes: 'fa-waterfall-scroll', [
        _waterfallSvg(e, analysis.categories),
      ]),
      div(classes: 'fa-legend', [
        span([Component.text('Increases model score')]),
        span(classes: 'fa-legend--red', [
          Component.text('Decreases model score'),
        ]),
        span(classes: 'fa-legend--gray', [Component.text('Reference / final')]),
      ]),
      p(classes: 'fa-chart-caption', [
        Component.text(
          'The chart groups all feature-level SHAP contributions into five net '
          'category totals. Individual positive and negative feature effects '
          'can cancel within a category.',
        ),
      ]),
    ]);
  }
}

/// Static SVG waterfall ported from the research design's geometry. Bars are
/// computed from the persisted baseline, category contributions and output —
/// no client-side scoring. Rendered as inline SVG so it works without JS.
Component _waterfallSvg(
  ResearchExplanation e,
  List<GeospatialCategorySummary> categories,
) {
  final bars = <_Bar>[_Bar('SHAP baseline', 0, e.baseValue, _BarKind.base, 0)];
  var current = e.baseValue;
  for (final c in categories) {
    final effect = c.contribution ?? 0;
    final next = current + effect;
    bars.add(_Bar(c.label, current, next, _BarKind.effect, effect));
    current = next;
  }
  bars.add(_Bar('Final model output', 0, e.output, _BarKind.output, 0));

  var domainMin = 0.0;
  var domainMax = 1.0;
  for (final b in bars) {
    domainMin = [domainMin, b.start, b.end].reduce((x, y) => x < y ? x : y);
    domainMax = [domainMax, b.start, b.end].reduce((x, y) => x > y ? x : y);
  }
  domainMin -= 0.045;
  domainMax += 0.045;
  double x(double v) => 202 + (v - domainMin) / (domainMax - domainMin) * 465;
  String n(double v) => v.toStringAsFixed(2);

  final children = <Component>[];
  for (final t in [0.0, 0.25, 0.5, 0.75, 1.0]) {
    if (t < domainMin || t > domainMax) continue;
    children.add(
      Component.element(
        tag: 'line',
        attributes: {
          'x1': n(x(t)),
          'x2': n(x(t)),
          'y1': '38',
          'y2': '326',
          'stroke': '#DFE8F3',
          'stroke-dasharray': '4 4',
        },
        children: [],
      ),
    );
    children.add(
      Component.element(
        tag: 'text',
        attributes: {
          'x': n(x(t)),
          'y': '22',
          'font-size': '10',
          'fill': '#71859E',
          'text-anchor': 'middle',
        },
        children: [Component.text('${(t * 100).round()}%')],
      ),
    );
  }
  for (var i = 0; i < bars.length; i++) {
    final b = bars[i];
    final y = 45 + i * 41;
    final lo = x(b.start) < x(b.end) ? x(b.start) : x(b.end);
    final w = (x(b.end) - x(b.start)).abs();
    final color = switch (b.kind) {
      _BarKind.base => '#91A9C8',
      _BarKind.output => '#1D4ED8',
      _BarKind.effect => b.effect >= 0 ? '#0D9488' : '#D65C55',
    };
    children.add(
      Component.element(
        tag: 'text',
        attributes: {
          'x': '8',
          'y': n(y + 14),
          'font-size': '11',
          'fill': '#324C68',
          'font-weight': b.kind == _BarKind.output ? '800' : '650',
        },
        children: [Component.text(b.name)],
      ),
    );
    children.add(
      Component.element(
        tag: 'rect',
        attributes: {
          'x': n(lo),
          'y': n(y.toDouble()),
          'rx': '5',
          'width': n(w < 2 ? 2 : w),
          'height': '21',
          'fill': color,
          'opacity': '.94',
        },
        children: [],
      ),
    );
    final label = b.kind == _BarKind.effect
        ? '${faSigned(b.effect * 100, decimals: 1)} pp'
        : faPct(b.end);
    final labelColor = b.kind == _BarKind.effect
        ? (b.effect >= 0 ? '#0D786F' : '#B94F49')
        : '#20466E';
    children.add(
      Component.element(
        tag: 'text',
        attributes: {
          'x': '685',
          'y': n(y + 15),
          'font-size': '11',
          'font-weight': '800',
          'fill': labelColor,
        },
        children: [Component.text(label)],
      ),
    );
    if (i > 0 && i < bars.length - 1) {
      children.add(
        Component.element(
          tag: 'circle',
          attributes: {
            'cx': n(x(b.end)),
            'cy': n(y + 11),
            'r': '2',
            'fill': '#20436D',
          },
          children: [],
        ),
      );
    }
  }
  return Component.element(
    tag: 'svg',
    classes: 'fa-waterfall',
    attributes: {
      'viewBox': '0 0 750 360',
      'role': 'img',
      'aria-label':
          'Waterfall chart of the signed contributions of the five categories '
          'from the SHAP baseline to the model output',
    },
    children: children,
  );
}

enum _BarKind { base, effect, output }

class _Bar {
  final String name;
  final double start;
  final double end;
  final _BarKind kind;
  final double effect;
  _Bar(this.name, this.start, this.end, this.kind, this.effect);
}

class _NarrativePanel extends StatelessComponent {
  final FullAnalysis analysis;
  const _NarrativePanel({required this.analysis});

  @override
  Component build(BuildContext context) {
    final narrative = faNarrative(analysis);
    return div(classes: 'fa-panel fa-pad fa-explain-main', [
      div(classes: 'fa-section-head', [
        div([
          h3([Component.text('✦ Sitewise AI explanation')]),
          p([
            Component.text('A short explanation entrepreneurs can understand'),
          ]),
        ]),
      ]),
      span(classes: 'fa-explain-tag', [
        Component.text('Deterministic template · no live LLM'),
      ]),
      div(classes: 'fa-llm-summary', [
        _llmBlock('What the score means', narrative.intro, ''),
        _llmBlock('What raised the score', narrative.up, 'fa-llm-block--pos'),
        _llmBlock(
          'What lowered the score',
          narrative.down,
          'fa-llm-block--neg',
        ),
        _llmBlock('What this does not tell you', narrative.caution, ''),
      ]),
      p(classes: 'fa-explain-foot', [
        Component.text(
          'This text is deterministically assembled from the saved model '
          'outputs. It demonstrates what a properly grounded LLM could '
          'explain, but no live LLM was called.',
        ),
      ]),
    ]);
  }

  Component _llmBlock(String heading, String body, String cls) =>
      div(classes: 'fa-llm-block $cls', [
        strong([Component.text(heading)]),
        p([Component.text(body)]),
      ]);
}

class _DriversPanel extends StatelessComponent {
  final FullAnalysis analysis;
  const _DriversPanel({required this.analysis});

  @override
  Component build(BuildContext context) {
    final ranked = [
      for (final m in analysis.measurements)
        if (m.shap != null) m,
    ]..sort((x, y) => y.shap!.abs().compareTo(x.shap!.abs()));
    final pos = ranked.where((m) => m.shap! > 0).take(2).toList();
    final neg = ranked.where((m) => m.shap! < 0).take(2).toList();
    final drivers = [...pos, ...neg];
    return div(classes: 'fa-panel fa-pad fa-drivers-panel', [
      div(classes: 'fa-section-head', [
        div([
          h3([Component.text('Largest individual features behind the score')]),
          p([
            Component.text(
              'Two positive and two negative drivers from this property\'s model features',
            ),
          ]),
        ]),
      ]),
      if (drivers.isEmpty)
        p(classes: 'fa-chart-caption', [
          Component.text('No signed feature contributions are available.'),
        ])
      else
        div(classes: 'fa-driver-grid', [
          for (final m in drivers)
            div(classes: 'fa-driver', [
              strong([Component.text(faFeatureLabel(m.name))]),
              small([
                Component.text(
                  '${m.categoryLabel} · recorded value ${faNum(m.value, decimals: 3)} (${faUnit(m.name)})',
                ),
              ]),
              b(classes: m.shap! >= 0 ? 'fa-positive' : 'fa-negative', [
                Component.text('${faSigned(m.shap, decimals: 4)} contribution'),
              ]),
            ]),
        ]),
    ]);
  }
}

class _AdvancedTable extends StatelessComponent {
  final FullAnalysis analysis;
  final String search;
  final void Function(String) onSearch;
  final bool hasShap;
  const _AdvancedTable({
    required this.analysis,
    required this.search,
    required this.onSearch,
    required this.hasShap,
  });

  @override
  Component build(BuildContext context) {
    final query = search.trim().toLowerCase();
    final rows = [
      for (final m in analysis.measurements)
        if (query.isEmpty ||
            '${m.name} ${m.categoryLabel} ${faFeatureLabel(m.name)}'
                .toLowerCase()
                .contains(query))
          m,
    ];
    final e = analysis.explanation;
    final featureCount = analysis.featureSpecs.length;
    return Component.element(
      tag: 'details',
      classes: 'fa-panel fa-advanced',
      children: [
        summary([
          Component.text(
            'View complete $featureCount-feature technical explanation and model evidence',
          ),
        ]),
        div(classes: 'fa-advanced-content', [
          p(classes: 'fa-chart-caption', [
            Component.text(
              'Model: ${e?.featureSet ?? analysis.model?.featureSet ?? '—'}'
              '${e?.modelVersion == null ? '' : ' · version ${e!.modelVersion}'}'
              '${e?.explainer == null ? '' : ' · ${e!.explainer}'}'
              '${e?.backgroundSize == null ? '' : ' · ${e!.backgroundSize} background observations'}. '
              'Each contribution must match this property and model version. '
              'Missing values read "Not recorded", never zero.',
            ),
          ]),
          div(classes: 'fa-advanced-search', [
            SearchInput(
              placeholder: 'Search feature or category…',
              ariaLabel: 'Filter SHAP feature table',
              onInput: onSearch,
            ),
          ]),
          div(classes: 'fa-advanced-table-wrap', [
            table(classes: 'fa-advanced-table', [
              thead([
                tr([
                  th([Component.text('Category')]),
                  th([Component.text('Model feature')]),
                  th([Component.text('Value')]),
                  th([Component.text('Unit')]),
                  th([Component.text('Signed SHAP')]),
                ]),
              ]),
              tbody([
                if (rows.isEmpty)
                  tr([
                    td(
                      attributes: const {'colspan': '5'},
                      [Component.text('No features match this search.')],
                    ),
                  ])
                else
                  for (final m in rows)
                    tr([
                      td([Component.text(m.categoryLabel)]),
                      td([
                        Component.text(faFeatureLabel(m.name)),
                        span(classes: 'fa-feature-key', [
                          Component.text(m.name),
                        ]),
                      ]),
                      td([Component.text(faNum(m.value, decimals: 3))]),
                      td([Component.text(faUnit(m.name))]),
                      td(
                        classes: m.shap == null
                            ? ''
                            : (m.shap! >= 0 ? 'fa-positive' : 'fa-negative'),
                        [
                          Component.text(
                            m.shap == null
                                ? 'Not generated'
                                : faSigned(m.shap, decimals: 5),
                          ),
                        ],
                      ),
                    ]),
              ]),
            ]),
          ]),
        ]),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
//  I — Business-target matching
// ---------------------------------------------------------------------------

class _Targets extends StatelessComponent {
  final FullAnalysis analysis;
  final String assessmentHref;
  final bool signedIn;
  const _Targets({
    required this.analysis,
    required this.assessmentHref,
    required this.signedIn,
  });

  @override
  Component build(BuildContext context) {
    final targets = analysis.targets;
    return section(
      classes: 'fa-section',
      attributes: const {'id': 'fa-targets'},
      [
        div(classes: 'fa-section-heading', [
          div([
            span(classes: 'fa-step-label', [
              Component.text('03 / BUSINESS PREFERENCE MATCHING'),
            ]),
            h2([Component.text('Separate business targets from SHAP')]),
            p([
              Component.text(
                'Read-only deterministic checks against your saved Stage 2 '
                'answers. They do not influence the trained PU score.',
              ),
            ]),
          ]),
          if (analysis.hasRequirements && targets != null)
            span(classes: 'fa-badge', [
              Component.text(
                '${targets.matched} achieved · ${targets.mismatched} not achieved · ${targets.unknown} unverified',
              ),
            ]),
        ]),
        if (!analysis.hasRequirements)
          div(classes: 'fa-panel fa-pad', [
            EmptyState(
              title: 'No business preferences saved',
              body: signedIn
                  ? 'Complete your business preferences to see personalized target matching.'
                  : 'Sign in and complete your business preferences to see personalized target matching.',
              action: ActionLink(
                'Complete business preferences',
                href: assessmentHref,
                icon: 'tune',
              ),
            ),
          ])
        else if (targets == null || !targets.hasChecks)
          div(classes: 'fa-panel fa-pad', [
            p(classes: 'fa-chart-caption', [
              Component.text(
                'Target matching is unavailable for this assessment. The '
                'report service returned no comparable checks.',
              ),
            ]),
          ])
        else
          div(classes: 'fa-panel fa-pad', [
            div(classes: 'fa-section-head', [
              div([
                h3([Component.text('Target checks')]),
                p([
                  Component.text(
                    'Only comparable, measured constraints can be marked '
                    'achieved or not achieved.',
                  ),
                ]),
              ]),
            ]),
            div(classes: 'fa-target-grid', [
              for (final check in targets.checks) _TargetItem(check: check),
            ]),
            if (targets.note != null)
              p(classes: 'fa-chart-caption', [Component.text(targets.note!)]),
          ]),
      ],
    );
  }
}

class _TargetItem extends StatelessComponent {
  final BusinessTargetCheck check;
  const _TargetItem({required this.check});

  @override
  Component build(BuildContext context) {
    final status = check.status;
    final label = switch (status) {
      BusinessTargetStatus.achieved => 'Achieved',
      BusinessTargetStatus.notAchieved => 'Not achieved',
      BusinessTargetStatus.context => 'Context',
      BusinessTargetStatus.requiresVerification => 'Requires verification',
    };
    final cls = switch (status) {
      BusinessTargetStatus.achieved => 'fa-status--achieved',
      BusinessTargetStatus.notAchieved => 'fa-status--missed',
      _ => '',
    };
    return div(classes: 'fa-target-item', [
      div([
        strong([Component.text(check.label)]),
        small([Component.text(check.detail)]),
      ]),
      span(classes: 'fa-status $cls', [Component.text(label)]),
    ]);
  }
}

// ---------------------------------------------------------------------------
//  J — Assessment summary
// ---------------------------------------------------------------------------

class _Summary extends StatelessComponent {
  final FullAnalysis analysis;
  final CommercialProperty property;
  final String reportHref;
  final void Function() onPrint;
  const _Summary({
    required this.analysis,
    required this.property,
    required this.reportHref,
    required this.onPrint,
  });

  @override
  Component build(BuildContext context) {
    final hasShap = analysis.hasValidShap;
    final narrative = hasShap ? faNarrative(analysis) : null;
    final targets = analysis.targets;
    final featureSet =
        analysis.model?.featureSet ?? analysis.explanation?.featureSet ?? '—';
    final featureCount =
        analysis.model?.featureCount ?? analysis.featureSpecs.length;
    final location = [
      property.address,
      property.city,
    ].where((part) => part.trim().isNotEmpty).join(', ');
    return section(
      classes: 'fa-section',
      attributes: const {'id': 'fa-report'},
      [
        div(classes: 'fa-section-heading', [
          div([
            span(classes: 'fa-step-label', [
              Component.text('04 / ASSESSMENT SUMMARY'),
            ]),
            h2([Component.text('Summary for review or printing')]),
            p([
              Component.text(
                'A concise report view that keeps the property, research model '
                'explanation, preference checks and verification needs separate.',
              ),
            ]),
          ]),
          button(
            classes: 'fa-btn fa-btn--dark',
            attributes: const {'type': 'button'},
            events: events(onClick: onPrint),
            [Icon('print', size: 'sm'), Component.text('Print this report')],
          ),
        ]),
        div(classes: 'fa-panel fa-pad', [
          div(classes: 'fa-report-grid', [
            _reportItem('Property', '${property.id} · $location'),
            _reportItem(
              'Research association',
              '${faPct(analysis.score?.positiveLabelAssociation)} (P/U research only)',
            ),
            _reportItem(
              'Model / explanation',
              '$featureSet · $featureCount features',
            ),
          ]),
          p(classes: 'fa-report-body', [
            Component.text(
              narrative?.plain ??
                  'No validated SHAP explanation has been generated for this '
                      'assessment yet.',
            ),
          ]),
          p(classes: 'fa-report-body', [
            Component.text(
              !analysis.hasRequirements
                  ? 'Business criteria: no Stage 2 answers saved, so no target '
                        'checks were evaluated.'
                  : targets == null
                  ? 'Business criteria: target matching unavailable.'
                  : 'Business criteria: ${targets.matched} achieved, '
                        '${targets.mismatched} not achieved, ${targets.unknown} '
                        'require verification. These checks are separate from '
                        'the PU and SHAP model.',
            ),
          ]),
          div(classes: 'fa-notice fa-notice--warn', [
            span(classes: 'fa-notice__symbol', [Icon('warning', size: 'sm')]),
            span([
              Component.text(
                'Sitewise is decision-support software. This research score is '
                'not a probability of F&B business success, and assessment '
                'checks do not confirm municipal approval, licensing, '
                'engineering conditions or landlord permission.',
              ),
            ]),
          ]),
          div(classes: 'fa-actions fa-actions--report', [
            ActionLink(
              'Open assessment report',
              href: reportHref,
              icon: 'description',
            ),
            ActionLink(
              'Back to property',
              href:
                  '/entrepreneur/property-detail?id=${Uri.encodeComponent(property.id)}',
              variant: 'secondary',
              icon: 'arrow_back',
            ),
          ]),
        ]),
      ],
    );
  }

  Component _reportItem(String label, String value) =>
      div(classes: 'fa-report-item', [
        small([Component.text(label)]),
        strong([Component.text(value)]),
      ]);
}

// ---------------------------------------------------------------------------
//  Shared section heading
// ---------------------------------------------------------------------------

Component _sectionHeading(String step, String title, String body) =>
    div(classes: 'fa-section-heading', [
      div([
        span(classes: 'fa-step-label', [Component.text(step)]),
        h2([Component.text(title)]),
        p([Component.text(body)]),
      ]),
    ]);
