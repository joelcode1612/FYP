/// Presentation building blocks shared by the five administrator operations
/// pages (Ownership, Agents, Campaigns, Activity, Surveys).
///
/// ## Why a second kit
///
/// `ui.dart` and `dashboard_kit.dart` cover the whole product — page heads,
/// panels, tables, dialogs, callouts — and every ops page leans on them for
/// exactly that. What they do not have is the four shapes the approved HTML
/// preview repeats across these five screens: a metric tile with an icon
/// tile, a tinted hero strip, a chip-style filter row, and a timeline entry.
/// Those live here so the preview's geometry is defined once, on the **live
/// SiteWise tokens** (`--surface` / `--border` / `--action` / `--ink`), not
/// per page with the preview's own hex values.
///
/// Rules respected by every component in this file:
///
/// * No colour literals — tone comes from `web/styles.css` custom properties,
///   so the dark shell restyle applies to these pages for free.
/// * Motion is delegated to `.ops-*` rules, which honour
///   `prefers-reduced-motion`; nothing here animates in Dart.
/// * Icons are the existing `Icon` (Material Symbols -> `<span class="ms">`),
///   never the preview's inline SVG sprite.
/// * Controls carry their state in ARIA (`aria-pressed`, `aria-current`)
///   rather than colour alone.
library;

import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'ui.dart';

/// Metric tile — the preview's `.stat` (icon tile + label + value) expressed
/// with this product's tokens.
///
/// Distinct from [StatCard] (the `.metric-card` KPI used by the dashboards):
/// this one carries a leading icon tile because all five ops pages group
/// three of them under a heading, as a single scannable row.
class OpsStat extends StatelessComponent {
  final String icon;
  final String label;
  final String value;

  /// Optional muted third line, e.g. where the number comes from.
  final String? note;

  const OpsStat({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.note,
  });

  @override
  Component build(BuildContext context) {
    return div(classes: 'ops-stat', [
      span(classes: 'ops-tile', [Icon(icon)]),
      div(classes: 'ops-stat__body', [
        span(classes: 'ops-stat__label', [Component.text(label)]),
        span(classes: 'ops-stat__value', [Component.text(value)]),
        if (note != null)
          span(classes: 'ops-stat__note', [Component.text(note!)]),
      ]),
    ]);
  }
}

/// Chip-style filter row (the preview's `.filter` buttons) with the selected
/// state exposed as `aria-pressed`.
///
/// Chips are for *filters and short single-choice answers only* — never for
/// navigation, where an anchor is the correct element.
class ChipRow extends StatelessComponent {
  final List<String> options;
  final String selected;
  final String ariaLabel;

  final void Function(String value) onSelect;

  const ChipRow({
    super.key,
    required this.options,
    required this.selected,
    required this.ariaLabel,
    required this.onSelect,
  });

  @override
  Component build(BuildContext context) {
    return div(
      classes: 'ops-chips',
      attributes: {'role': 'group', 'aria-label': ariaLabel},
      [
        for (final option in options)
          button(
            classes: option == selected ? 'ops-chip ops-chip--on' : 'ops-chip',
            attributes: {
              'type': 'button',
              'aria-pressed': option == selected ? 'true' : 'false',
            },
            events: events(onClick: () => onSelect(option)),
            [Component.text(option)],
          ),
      ],
    );
  }
}

/// Tinted strip introducing a section (the preview's `.wide-hero`): icon tile,
/// heading block, and an action pinned to the end on wide screens.
///
/// Structural, not decorative: it always carries a heading, so it is a real
/// landmark for screen readers rather than a styled `<div>` with text.
class OpsHero extends StatelessComponent {
  final String icon;
  final String title;
  final String body;
  final Component? action;

  const OpsHero({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  @override
  Component build(BuildContext context) {
    return section(classes: 'ops-hero', [
      div(classes: 'ops-hero__main', [
        span(classes: 'ops-tile ops-tile--lg', [Icon(icon)]),
        div(classes: 'ops-hero__text', [
          h2(classes: 'ops-hero__title', [Component.text(title)]),
          p(classes: 'ops-hero__body', [Component.text(body)]),
        ]),
      ]),
      if (action != null) div(classes: 'ops-hero__action', [action!]),
    ]);
  }
}

/// One event in the activity timeline: icon tile, title, subject, meta line.
class TimelineEntry extends StatelessComponent {
  final String icon;
  final String title;
  final String subject;
  final String meta;
  final Component? badge;

  const TimelineEntry({
    super.key,
    required this.icon,
    required this.title,
    required this.subject,
    required this.meta,
    this.badge,
  });

  @override
  Component build(BuildContext context) {
    return article(classes: 'ops-ev', [
      span(classes: 'ops-tile', [Icon(icon)]),
      div(classes: 'ops-ev__body', [
        div(classes: 'ops-ev__head', [
          h3(classes: 'ops-ev__title', [Component.text(title)]),
          badge ?? const span([]),
        ]),
        if (subject.isNotEmpty)
          p(classes: 'ops-ev__subject', [Component.text(subject)]),
        p(classes: 'ops-ev__meta', [Component.text(meta)]),
      ]),
    ]);
  }
}

/// One label/value line with a leading glyph (the preview's `.info-line`).
class InfoRow extends StatelessComponent {
  final String icon;
  final String label;
  final String value;

  const InfoRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Component build(BuildContext context) {
    return div(classes: 'ops-info', [
      Icon(icon, size: 'sm'),
      div(classes: 'ops-info__text', [
        span(classes: 'ops-info__label', [Component.text(label)]),
        span(classes: 'ops-info__value', [Component.text(value)]),
      ]),
    ]);
  }
}

/// Empty/results message inside a list region (the preview's `.no-results`),
/// kept distinct from [EmptyState] so a filtered-empty list does not read
/// like a broken feature.
class InlineEmpty extends StatelessComponent {
  final String message;
  const InlineEmpty(this.message, {super.key});

  @override
  Component build(BuildContext context) =>
      p(classes: 'ops-empty', [Component.text(message)]);
}
