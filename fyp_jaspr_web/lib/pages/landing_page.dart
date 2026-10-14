import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../components/ui.dart';
import '../data/site_content.dart';
import '../layouts/marketing_layout.dart';

/// Public pre-auth landing page — the Jaspr port of
/// `lib/presentation/web/landing/pages/landing_web_page.dart`.
///
/// Section order matches the Flutter original: hero, audience, workflow,
/// location intelligence, explainable recommendations, 360° tours, CTA.
///
/// What is genuinely different from the Flutter version, beyond syntax:
///
/// * **It is real HTML.** The Flutter page paints to a canvas, so a crawler
///   sees an empty `<canvas>` element. Here every heading, paragraph and link
///   is in the DOM and indexable — which is the entire reason for this port.
/// * **Anchors replace imperative scrolling.** The Flutter page held a
///   `GlobalKey` per section and called `Scrollable.ensureVisible`. Here the
///   masthead links are `#how`, `#geo`, … and CSS does the smooth scroll.
/// * **No `CustomPainter`.** The Flutter visuals were canvas painters; these
///   are CSS gradients and positioned elements, so they scale, print, and
///   respond to user font-size settings.
class LandingPage extends StatelessComponent {
  const LandingPage({super.key});

  @override
  Component build(BuildContext context) {
    return const MarketingLayout(
      child: div([
        _Hero(),
        _Audience(),
        _Workflow(),
        _LocationIntelligence(),
        _Recommendations(),
        _TourShowcase(),
        _ClosingCta(),
      ]),
    );
  }
}

// ===========================================================================
// Hero
// ===========================================================================

class _Hero extends StatelessComponent {
  const _Hero();

  @override
  Component build(BuildContext context) {
    return section(id: 'top', classes: 'section', [
      div(classes: 'container hero', [
        div(classes: 'stack', [
          const Eyebrow(LandingContent.eyebrow),
          h1(classes: 'hero__title', [
            Component.text(LandingContent.heroTitleA),
            em([Component.text(LandingContent.heroTitleEm)]),
            Component.text(LandingContent.heroTitleB),
          ]),
          p(classes: 'hero__lead', [Component.text(LandingContent.heroLead)]),
          div(classes: 'btn-row', [
            const ActionLink(LandingContent.heroPrimary, href: '/entrepreneur'),
            const ActionLink(
              LandingContent.heroSecondary,
              href: '#how',
              variant: 'secondary',
            ),
          ]),
          p(classes: 'hero__note', [Component.text(LandingContent.heroNote)]),
        ]),
        const _HeroVisual(),
      ]),
    ]);
  }
}

/// CSS stand-in for the Flutter `WebHeroVisual` (a `CustomPainter` map with a
/// floating score card).
class _HeroVisual extends StatelessComponent {
  const _HeroVisual();

  @override
  Component build(BuildContext context) {
    return div(classes: 'visual', [
      div(classes: 'visual__grid', []),
      // Demand pins. Positions are static so they can live in CSS-free markup
      // with utility classes; the offsets are intentionally simple.
      span(classes: 'visual__pin', []),
      const _Chip('SS15, Subang Jaya', 'location_on'),
      const _Chip('High potential', 'trending_up'),
      div(classes: 'score-card', [
        span(classes: 'overline', [Component.text('Location suitability')]),
        div(classes: 'row', [
          div(classes: 'score-card__ring', [Component.text('86')]),
          div(classes: 'stack', [
            span(classes: 'title', [Component.text('86/100')]),
            span(classes: 'small text-success', [
              Component.text('High potential'),
            ]),
          ]),
        ]),
      ]),
    ]);
  }
}

class _Chip extends StatelessComponent {
  final String label;
  final String icon;

  const _Chip(this.label, this.icon);

  @override
  Component build(BuildContext context) {
    return span(classes: 'visual__chip', [
      Icon(icon, size: 'sm'),
      Component.text(label),
    ]);
  }
}

// ===========================================================================
// Audience
// ===========================================================================

class _Audience extends StatelessComponent {
  const _Audience();

  @override
  Component build(BuildContext context) {
    return section(id: 'audience', classes: 'section section--alt', [
      div(classes: 'container', [
        const SectionHead(
          eyebrow: 'Who Sitewise is for',
          title: 'One platform, different location needs.',
          body:
              'Sitewise supports the people involved in commercial F&B '
              'property decisions, while keeping the entrepreneur workflow at '
              'the centre.',
        ),
        div(classes: 'grid-2', [
          for (final role in LandingContent.roles) _RoleCard(role: role),
        ]),
      ]),
    ]);
  }
}

class _RoleCard extends StatelessComponent {
  final RoleCardData role;

  const _RoleCard({required this.role});

  @override
  Component build(BuildContext context) {
    return div(classes: 'card stack', [
      span(classes: 'icon-tile', [Icon(role.icon, size: 'lg')]),
      h3(classes: 'title-lg', [Component.text(role.title)]),
      p(classes: 'body', [Component.text(role.body)]),
      ActionLink(role.linkLabel, href: role.route, variant: 'secondary'),
    ]);
  }
}

// ===========================================================================
// Workflow
// ===========================================================================

class _Workflow extends StatelessComponent {
  const _Workflow();

  @override
  Component build(BuildContext context) {
    return section(id: 'how', classes: 'section', [
      div(classes: 'container', [
        const SectionHead(
          eyebrow: 'From business needs to location decision',
          title: 'How Sitewise helps you evaluate a location.',
          body:
              'The workflow combines structured business preferences with '
              'location evidence, then presents the result in a form that can '
              'be reviewed and compared.',
        ),
        div(classes: 'grid-4', [
          for (final step in LandingContent.steps)
            StepCard(num: step.num, title: step.title, body: step.body),
        ]),
      ]),
    ]);
  }
}

// ===========================================================================
// Location intelligence
// ===========================================================================

class _LocationIntelligence extends StatelessComponent {
  const _LocationIntelligence();

  @override
  Component build(BuildContext context) {
    return section(id: 'geo', classes: 'section section--alt', [
      div(classes: 'container hero', [
        div(classes: 'stack', [
          const Eyebrow('01 — Location intelligence'),
          h2(classes: 'title-xl', [
            Component.text('See the neighbourhood, not just the unit.'),
          ]),
          p(classes: 'lead', [
            Component.text(
              'A commercial unit makes more sense when its surroundings are '
              'visible. Sitewise combines property context with geospatial '
              'signals so a location can be evaluated as part of its catchment '
              'and surrounding area.',
            ),
          ]),
          div(classes: 'grid-2', [
            for (final feature in LandingContent.features)
              FeatureRow(
                icon: feature.icon,
                title: feature.title,
                body: feature.body,
              ),
          ]),
        ]),
        const _MapVisual(),
      ]),
    ]);
  }
}

/// CSS stand-in for the Flutter `WebGeoVisual`.
class _MapVisual extends StatelessComponent {
  const _MapVisual();

  @override
  Component build(BuildContext context) {
    return div(classes: 'visual visual--map', [
      div(classes: 'visual__grid', []),
      const _Chip('Population', 'groups'),
      const _Chip('Accessibility', 'alt_route'),
      const _Chip('Competition', 'storefront'),
      const _Chip('Demand', 'trending_up'),
    ]);
  }
}

// ===========================================================================
// Explainable recommendations
// ===========================================================================

class _Recommendations extends StatelessComponent {
  const _Recommendations();

  @override
  Component build(BuildContext context) {
    return section(id: 'recs', classes: 'section', [
      div(classes: 'container', [
        const SectionHead(
          eyebrow: '02 — Explainable recommendations',
          title: 'A recommendation should show you the reasons behind it.',
          body:
              'Sitewise is designed to make the factors behind a location '
              'assessment visible, so a shortlist can be reviewed instead of '
              'treated as a black box.',
        ),
        div(classes: 'row row--top', [
          div(classes: 'grow', [const _AssessmentCard()]),
          div(classes: 'grow', [const _WeightsCard()]),
        ]),
      ]),
    ]);
  }
}

class _AssessmentCard extends StatelessComponent {
  const _AssessmentCard();

  @override
  Component build(BuildContext context) {
    return div(classes: 'card stack', [
      div(classes: 'row', [
        div(classes: 'grow stack', [
          span(classes: 'overline', [Component.text('Assessed property')]),
          span(classes: 'title', [
            Component.text(LandingContent.assessmentProperty),
          ]),
        ]),
        Pill('${LandingContent.assessmentScore}/100', tone: 'success'),
      ]),
      for (final driver in LandingContent.drivers)
        div(classes: 'feature', [
          span(
            classes: 'dot ${driver.tradeoff ? 'dot--warning' : 'dot--success'}',
            [],
          ),
          div(classes: 'grow stack', [
            span(classes: 'title', [Component.text(driver.title)]),
            p(classes: 'small', [Component.text(driver.body)]),
          ]),
        ]),
      hr(classes: 'divider'),
      div(classes: 'stack', [
        span(classes: 'overline', [Component.text('Site profile')]),
        for (final row in LandingContent.siteProfile)
          div(classes: 'row', [
            span(classes: 'small grow', [Component.text(row.$1)]),
            span(classes: 'title', [Component.text(row.$2)]),
          ]),
      ]),
    ]);
  }
}

class _WeightsCard extends StatelessComponent {
  const _WeightsCard();

  @override
  Component build(BuildContext context) {
    return div(classes: 'card stack', [
      span(classes: 'overline', [Component.text('Factor weighting')]),
      p(classes: 'small', [
        Component.text(
          'How each location factor contributed to the score. Showing the '
          'weights is what makes the result reviewable rather than opaque.',
        ),
      ]),
      for (final weight in LandingContent.weights)
        WeightBar(label: weight.$1, pct: weight.$2),
    ]);
  }
}

// ===========================================================================
// 360° tour showcase
// ===========================================================================

class _TourShowcase extends StatelessComponent {
  const _TourShowcase();

  @override
  Component build(BuildContext context) {
    return section(id: 'tour', classes: 'section section--alt', [
      div(classes: 'container', [
        const SectionHead(
          eyebrow: '03 — Property exploration',
          title: 'Explore the space before you arrange the site visit.',
          body:
              'Available 360° tours let entrepreneurs inspect the interior, '
              'frontage and overall feel of a shortlisted property alongside '
              'its location information.',
        ),
        div(classes: 'visual', [
          div(classes: 'visual__grid', []),
          div(classes: 'card--dark', [
            span(classes: 'overline muted-on-dark', [
              Component.text('360° virtual tour'),
            ]),
            h3(classes: 'title-lg', [
              Component.text('Drag to look around the space'),
            ]),
            p(classes: 'muted-on-dark small', [
              Component.text(
                'Interior, frontage and street context captured as a '
                'navigable walkthrough.',
              ),
            ]),
          ]),
        ]),
        const ActionLink(
          'Explore properties with tours',
          href: '/entrepreneur/explore',
          variant: 'secondary',
        ),
      ]),
    ]);
  }
}

// ===========================================================================
// Closing CTA
// ===========================================================================

class _ClosingCta extends StatelessComponent {
  const _ClosingCta();

  @override
  Component build(BuildContext context) {
    return section(classes: 'section', [
      div(classes: 'container', [
        div(classes: 'cta-box', [
          h2(classes: 'title-xl', [Component.text(LandingContent.ctaTitle)]),
          p(classes: 'lead', [Component.text(LandingContent.ctaBody)]),
          div(classes: 'btn-row', [
            const ActionLink('Get Started', href: '/entrepreneur'),
            const ActionLink(
              'See How It Works',
              href: '#how',
              variant: 'secondary',
            ),
          ]),
        ]),
      ]),
    ]);
  }
}
