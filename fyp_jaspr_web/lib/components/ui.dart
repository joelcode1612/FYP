/// Shared UI components — the Jaspr counterpart to
/// `lib/presentation/shared/widgets/` in the Flutter tree.
///
/// Two deliberate differences from the Flutter versions:
///
/// 1. **No styling in Dart.** Jaspr has no pre-styled component library and
///    `Text` takes only a String, so every component below composes CSS
///    classes defined in `web/styles.css`. That file, not this one, is the
///    design system.
/// 2. **Navigation is `<a href>`, not a callback.** In the Flutter tree a
///    button calls `Navigator.pushNamed`. On the web an anchor is better: it
///    is crawlable, works without JavaScript, supports middle-click and
///    "open in new tab", and is what a screen reader announces as a link.
///    Actions that genuinely change state still use `<button>`.
library;

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import '../data/icon_variants.dart';

/// A Material Symbols glyph.
///
/// The Flutter tree writes `Icon(Icons.storefront_outlined)`. Here the icon is
/// addressed by its Material Symbols name, so content data stays readable.
///
/// Flutter's `Icons.*` mixes families and fills, so the correct variant is
/// resolved from [kFilledIcons] / [kRoundedIcons] rather than assumed. Pass
/// [filled] or [rounded] to override that lookup for a one-off.
class Icon extends StatelessComponent {
  final String name;

  /// `null` (default), `'sm'` or `'lg'`.
  final String? size;

  /// Decorative by default. Pass [label] when the icon carries meaning on its
  /// own, so it is not silently dropped from the accessibility tree — the label
  /// is rendered visually-hidden rather than relying on an ARIA attribute.
  final String? label;

  /// Overrides [isFilledIcon] for this instance.
  final bool? filled;

  /// Overrides [isRoundedIcon] for this instance.
  final bool? rounded;

  const Icon(
    this.name, {
    super.key,
    this.size,
    this.label,
    this.filled,
    this.rounded,
  });

  @override
  Component build(BuildContext context) {
    final useFilled = filled ?? isFilledIcon(name);
    final useRounded = rounded ?? isRoundedIcon(name);

    final classes = [
      'ms',
      if (size == 'sm') 'ms--sm',
      if (size == 'lg') 'ms--lg',
      if (useFilled) 'ms--fill',
      if (useRounded) 'ms--rounded',
    ].join(' ');

    return span(classes: classes, [
      Component.text(name),
      if (label != null) span(classes: 'sr-only', [Component.text(label!)]),
    ]);
  }
}

/// The Sitewise wordmark. An anchor so it is crawlable and keyboard-reachable.
class Brand extends StatelessComponent {
  const Brand({super.key});

  @override
  Component build(BuildContext context) {
    return a(href: '/', classes: 'brand', [
      span(classes: 'brand__mark', [Component.text('S')]),
      span(classes: 'brand__name', [Component.text('Sitewise')]),
    ]);
  }
}

/// Small rounded status label.
class Pill extends StatelessComponent {
  final String label;

  /// `neutral` | `action` | `success` | `warning` | `danger`.
  final String tone;

  const Pill(this.label, {super.key, this.tone = 'neutral'});

  @override
  Component build(BuildContext context) {
    return span(classes: 'pill pill--$tone', [Component.text(label)]);
  }
}

/// Uppercase section eyebrow. Uses the contrast-safe text token.
class Eyebrow extends StatelessComponent {
  final String label;
  const Eyebrow(this.label, {super.key});

  @override
  Component build(BuildContext context) =>
      span(classes: 'eyebrow', [Component.text(label)]);
}

/// Section heading block: eyebrow, title, supporting paragraph.
class SectionHead extends StatelessComponent {
  final String eyebrow;
  final String title;
  final String body;

  const SectionHead({
    super.key,
    required this.eyebrow,
    required this.title,
    required this.body,
  });

  @override
  Component build(BuildContext context) {
    return div(classes: 'stack', [
      Eyebrow(eyebrow),
      div(classes: 'stack', [
        h2(classes: 'title-xl', [Component.text(title)]),
      ]),
      p(classes: 'lead', [Component.text(body)]),
    ]);
  }
}

/// Primary/secondary call to action that navigates — rendered as an anchor.
class ActionLink extends StatelessComponent {
  final String label;
  final String href;

  /// `primary` | `secondary` | `ghost` | `danger-outline`.
  final String variant;

  final String? icon;

  /// Full-width 52px primary button (the Flutter `SitewiseCtaButton`).
  final bool cta;

  const ActionLink(
    this.label, {
    super.key,
    required this.href,
    this.variant = 'primary',
    this.icon,
    this.cta = false,
  });

  @override
  Component build(BuildContext context) {
    final classes = ['btn', 'btn--$variant', if (cta) 'btn--cta'].join(' ');
    return a(href: href, classes: classes, [
      if (icon != null) Icon(icon!, size: 'sm'),
      Component.text(label),
    ]);
  }
}

/// A call to action that performs an action rather than navigating.
class ActionButton extends StatelessComponent {
  final String label;
  final void Function()? onClick;
  final String variant;
  final String? icon;
  final bool cta;

  const ActionButton(
    this.label, {
    super.key,
    required this.onClick,
    this.variant = 'primary',
    this.icon,
    this.cta = false,
  });

  @override
  Component build(BuildContext context) {
    final classes = [
      'btn',
      'btn--$variant',
      if (cta) 'btn--cta',
      if (onClick == null) 'is-disabled',
    ].join(' ');
    return button(classes: classes, onClick: onClick, [
      if (icon != null) Icon(icon!, size: 'sm'),
      Component.text(label),
    ]);
  }
}

/// A single metric tile.
class StatCard extends StatelessComponent {
  final String label;
  final String value;
  final String? icon;

  /// Optional colour class, e.g. `text-success`.
  final String? toneClass;

  const StatCard({
    super.key,
    required this.label,
    required this.value,
    this.icon,
    this.toneClass,
  });

  @override
  Component build(BuildContext context) {
    return div(classes: 'stat', [
      div(classes: 'row', [
        if (icon != null) ...[
          Icon(icon!, size: 'sm'),
          span(classes: 'grow', []),
        ],
      ]),
      span(classes: 'overline', [Component.text(label)]),
      div(classes: 'metric ${toneClass ?? 'text-ink'}', [
        Component.text(value),
      ]),
    ]);
  }
}

/// One numbered workflow step.
class StepCard extends StatelessComponent {
  final String num;
  final String title;
  final String body;

  const StepCard({
    super.key,
    required this.num,
    required this.title,
    required this.body,
  });

  @override
  Component build(BuildContext context) {
    return div(classes: 'step', [
      span(classes: 'step__num', [Component.text(num)]),
      h3(classes: 'title', [Component.text(title)]),
      p(classes: 'body', [Component.text(body)]),
    ]);
  }
}

/// Icon + title + body row used by the feature and benefit lists.
class FeatureRow extends StatelessComponent {
  final String icon;
  final String title;
  final String body;

  const FeatureRow({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  Component build(BuildContext context) {
    return div(classes: 'feature', [
      span(classes: 'icon-tile', [Icon(icon)]),
      div(classes: 'grow stack', [
        span(classes: 'title', [Component.text(title)]),
        p(classes: 'small', [Component.text(body)]),
      ]),
    ]);
  }
}

/// A labelled percentage bar.
class WeightBar extends StatelessComponent {
  final String label;
  final int pct;

  const WeightBar({super.key, required this.label, required this.pct});

  @override
  Component build(BuildContext context) {
    // Widths come from static data, so a utility class is used instead of an
    // inline style — keeping every visual rule inside styles.css.
    final bucket = (pct / 5).round() * 5;
    return div(classes: 'weights__row', [
      span(classes: 'small grow', [Component.text(label)]),
      span(classes: 'weights__track', [
        span(classes: 'weights__fill w-$bucket', []),
      ]),
      span(classes: 'small', [Component.text('$pct%')]),
    ]);
  }
}
