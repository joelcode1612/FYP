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
import 'package:shared_logic/shared_logic.dart';

import '../data/icon_variants.dart';
import 'letter_reveal.dart';

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
///
/// Structure follows the source lockup (`theme.css` `.brand` + `pill-nav.css`
/// `.pillnav .brand`): a dark gradient tile carrying the map-pin glyph, the
/// wordmark at weight 900, and an optional uppercase role line beneath it.
/// The previous version was a blue gradient square with the letter "S" and no
/// role line, which read as a different logo.
class Brand extends StatelessComponent {
  /// Role line under the wordmark, e.g. "Entrepreneur workspace".
  ///
  /// Null on the marketing pages, where the source lockup has no role line.
  final String? subtitle;

  const Brand({super.key, this.subtitle});

  @override
  Component build(BuildContext context) {
    return a(href: '/', classes: 'brand', [
      span(classes: 'brand__mark', [
        Component.element(
          tag: 'img',
          classes: 'brand__mark-img',
          attributes: {
            'src': 'assets/sitewise-mark-64.png',
            'alt': 'Sitewise',
            'width': '24',
            'height': '24',
          },
          children: [],
        ),
      ]),
      span(classes: 'brand__text', [
        span(classes: 'brand__name', [Component.text('Sitewise')]),
        if (subtitle != null)
          span(classes: 'brand__sub', [Component.text(subtitle!)]),
      ]),
    ]);
  }
}

/// Small rounded status label.
/// Maps this component's tone names onto the source design's pill classes.
///
/// The source distinguishes two pills by the leading dot: `.st-*`
/// (`owner.css`) carries one via `::before`, `.badge-*` (`app.css`) does not.
/// Both use the same tone suffixes, so one map serves both.
String pillToneClass(String tone) => switch (tone) {
  'neutral' => 'muted',
  'action' => 'info',
  'success' => 'det',
  'warning' => 'warn',
  'danger' => 'danger',
  _ => 'muted',
};

/// Verification → pill tone. Lives beside [StatusBadge] because every page that
/// renders a verification pill needs the same mapping; `property_card.dart`
/// re-exports it for its own callers.
String toneForVerification(VerificationStatus status) => switch (status) {
  VerificationStatus.draft => 'neutral',
  VerificationStatus.pending => 'warning',
  VerificationStatus.verified => 'success',
  VerificationStatus.rejected => 'danger',
};

/// Status pill — the source design's `.st`.
///
/// Previously emitted `pill pill--<tone>`, this file's own vocabulary, which had
/// no counterpart in the source design. The leading dot comes from `.st::before`
/// in the stylesheet rather than a child element, matching the source.
class Pill extends StatelessComponent {
  final String label;

  /// `neutral` | `action` | `success` | `warning` | `danger`.
  final String tone;

  const Pill(this.label, {super.key, this.tone = 'neutral'});

  @override
  Component build(BuildContext context) {
    return span(classes: 'st st-${pillToneClass(tone)}', [
      Component.text(label),
    ]);
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

/// A single metric tile — the source's `.metric-card` (`.k` / `.v` / `.n`).
class StatCard extends StatelessComponent {
  final String label;
  final String value;
  final String? icon;

  /// Optional third line under the value (`.n` in the source), e.g.
  /// "No run yet" or "Synced to your account".
  final String? note;

  /// Optional colour class applied to the value, e.g. `text-success`.
  ///
  /// No caller currently passes one; the parameter is kept so the public API is
  /// unchanged. The value would otherwise be `var(--ink)` from
  /// `.metric-card .v`, which has higher specificity than a bare `text-*` class,
  /// so the tone is applied through `.metric-card .v.text-*` in the stylesheet.
  final String? toneClass;

  const StatCard({
    super.key,
    required this.label,
    required this.value,
    this.icon,
    this.note,
    this.toneClass,
  });

  @override
  Component build(BuildContext context) {
    // Restyled to the new design's `.metric-card`: `.k` label, `.v` value and
    // the optional `.n` note. Previously `.stat` (icon row + `.overline` +
    // `.metric`). The public API is unchanged.
    return div(classes: 'metric-card', [
      span(classes: 'k', [Component.text(label)]),
      span(classes: 'v ${toneClass ?? ''}', [Component.text(value)]),
      if (note != null) span(classes: 'n', [Component.text(note!)]),
    ]);
  }
}

/// One numbered workflow step — the source's `.step`.
///
/// Structure: `.stepno` (the number), `.step-icon` (the glyph tile), `h3`, `p`.
/// The previous version emitted `.step__num`, a BEM name the source does not
/// use, and had no icon tile at all.
class StepCard extends StatelessComponent {
  final String num;
  final String title;
  final String body;

  /// Material Symbols name for the tile above the title.
  final String? icon;

  const StepCard({
    super.key,
    required this.num,
    required this.title,
    required this.body,
    this.icon,
  });

  @override
  Component build(BuildContext context) {
    return div(classes: 'step', [
      span(classes: 'stepno', [Component.text(num)]),
      if (icon != null) span(classes: 'step-icon', [Icon(icon!)]),
      h3([Component.text(title)]),
      p([Component.text(body)]),
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

// ==========================================================================
//  Page-level primitives
// --------------------------------------------------------------------------
//  Everything above this line is content-level (a card, a pill, a bar). The
//  components below give every page the same skeleton: a page header, titled
//  section panels, empty states, loading placeholders, status badges, labelled
//  form fields, breadcrumbs and a search input.
//
//  Before these existed, each page hand-rolled its own title block (or had
//  none and relied only on the topbar), duplicated the `title-lg + body` empty
//  state roughly ten times, and showed `Loading…` as plain text that reflowed
//  the page once data arrived.
// ==========================================================================

/// Consistent page header: eyebrow + title + description on the left, actions
/// on the right. Stacks below 640px.
///
/// Pages previously passed only `title`/`subtitle` to `AppLayout`, which meant
/// the *only* place a page name appeared was the topbar — no description, and
/// no room for a page-level action.
class PageHead extends StatelessComponent {
  /// Small uppercase label above the title, e.g. `Administrator`.
  final String? eyebrow;

  /// The page name. Rendered as an `h1` so heading order is correct.
  final String title;

  /// One-line explanation of what the page is for.
  final String? description;

  /// Status pills shown under the description.
  ///
  /// The source's property detail header carries the verification and
  /// availability badges in exactly this position; without a slot for them a
  /// page has to abandon `PageHead` and hand-roll the whole header.
  final List<Component> badges;

  /// Page-level actions, e.g. a primary "Add property" button.
  final List<Component> actions;

  const PageHead({
    super.key,
    this.eyebrow,
    required this.title,
    this.description,
    this.badges = const [],
    this.actions = const [],
  });

  @override
  Component build(BuildContext context) {
    return header(classes: 'page-head', [
      div(classes: 'page-head__main', [
        if (eyebrow != null) Eyebrow(eyebrow!),
        // Page titles are above the fold on every role, so they use the
        // on-mount variant: pure CSS, no observer, no flash of static text.
        LetterRevealHeading.text(title, level: 1, classes: 'page-head__title'),
        if (description != null)
          p(classes: 'page-head__desc', [Component.text(description!)]),
        if (badges.isNotEmpty) div(classes: 'badges', badges),
      ]),
      if (actions.isNotEmpty) div(classes: 'page-head__actions', actions),
    ]);
  }
}

/// A titled panel. The body is padded by default; pass [flush] when the body is
/// a table or list that should run edge to edge.
class SectionCard extends StatelessComponent {
  final String title;

  /// Optional trailing content in the header row, e.g. a "See all" link.
  final List<Component>? action;

  final Component child;

  /// Removes the body padding — use for tables and rows.
  final bool flush;

  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.action,
    this.flush = false,
  });

  @override
  Component build(BuildContext context) {
    // Source vocabulary: `.panel` frame + `.panel__head` / `.panel__title` /
    // `.panel__body`. The flush variant adds `panel--flush`, which is the only
    // case where the source's paddingless frame needs a header rule.
    return section(classes: flush ? 'panel panel--flush' : 'panel', [
      div(classes: 'panel__head', [
        span(classes: 'panel__title', [Component.text(title)]),
        if (action != null) div(classes: 'row row--sm', action!),
      ]),
      div(classes: flush ? 'panel__body panel__body--flush' : 'panel__body', [
        child,
      ]),
    ]);
  }
}

/// Placeholder shown when a list has no results.
///
/// The source's `ui.emptyState()` renders exactly three things — an `h3`, a
/// `p` and an optional action — inside a dashed-border box. The previous
/// version added a circular icon badge above the title, which the source does
/// not have, so the state read as a different component. The `icon` parameter
/// is gone rather than silently ignored.
class EmptyState extends StatelessComponent {
  final String title;

  /// Explains why it is empty and, ideally, what to do about it.
  final String body;

  /// Optional call to action, e.g. a link to Explore.
  final Component? action;

  const EmptyState({
    super.key,
    required this.title,
    required this.body,
    this.action,
  });

  @override
  Component build(BuildContext context) {
    return div(classes: 'empty', [
      span(classes: 'empty__title', [Component.text(title)]),
      p(classes: 'empty__body', [Component.text(body)]),
      if (action != null) div(classes: 'empty__action', [action!]),
    ]);
  }
}

/// Loading placeholder. Keeps the page's dimensions stable while data loads,
/// instead of swapping text for content and reflowing everything.
class Skeleton extends StatelessComponent {
  /// `text` | `title` | `row` | `block`
  final String variant;

  /// Renders this many stacked copies with the standard gap.
  final int count;

  const Skeleton({super.key, this.variant = 'row', this.count = 1});

  @override
  Component build(BuildContext context) {
    final cls = variant == 'text'
        ? 'skeleton skeleton--text'
        : variant == 'title'
        ? 'skeleton skeleton--title'
        : variant == 'block'
        ? 'skeleton skeleton--block'
        : 'skeleton skeleton--row';

    if (count <= 1) return div(classes: cls, []);

    return div(classes: 'skeleton-stack', [
      for (var i = 0; i < count; i++) div(classes: cls, []),
    ]);
  }
}

/// Status pill driven by the real domain enums, so colour is never chosen
/// ad-hoc per page.
///
/// [USER.status] is a free-form String, which is why [forText] exists — it
/// keyword-matches rather than pretending there is an enum behind it.
class StatusBadge extends StatelessComponent {
  final String label;

  /// `neutral` | `action` | `success` | `warning` | `danger`
  final String tone;

  /// Show a leading dot. Off by default: the label already carries the meaning.
  final bool dot;

  const StatusBadge(
    this.label, {
    super.key,
    this.tone = 'neutral',
    this.dot = false,
  });

  /// Verification lifecycle — `draft` → neutral, `pending` → warning,
  /// `verified` → success, `rejected` → danger.
  factory StatusBadge.forVerification(VerificationStatus status) {
    final (label, tone) = switch (status) {
      VerificationStatus.draft => ('Draft', 'neutral'),
      VerificationStatus.pending => ('Pending', 'warning'),
      VerificationStatus.verified => ('Verified', 'success'),
      VerificationStatus.rejected => ('Rejected', 'danger'),
    };
    return StatusBadge(label, tone: tone);
  }

  /// Tour lifecycle. Labels and tones match `tours_page.dart`'s original
  /// `_statusLabel` / `_statusTone`, which were themselves written to match the
  /// Flutter tours page exactly — so changing them here would fork the two
  /// platforms' vocabulary.
  factory StatusBadge.forTour(VirtualTourStatus status, {bool dot = false}) {
    final (label, tone) = switch (status) {
      VirtualTourStatus.draft => ('Draft', 'action'),
      VirtualTourStatus.processing => ('Processing…', 'warning'),
      VirtualTourStatus.ready => ('Ready', 'action'),
      VirtualTourStatus.pendingVerification => (
        'Pending verification',
        'warning',
      ),
      VirtualTourStatus.approved => ('Approved', 'success'),
      VirtualTourStatus.rejected => ('Rejected', 'danger'),
    };
    return StatusBadge(label, tone: tone, dot: dot);
  }

  /// The label [StatusBadge.forTour] would render, for pages that also need the
  /// status as prose (e.g. "12 scenes · Pending verification"). Keeping this
  /// beside the factory means the badge and the sentence can never drift.
  static String tourLabel(VirtualTourStatus status) => switch (status) {
    VirtualTourStatus.draft => 'Draft',
    VirtualTourStatus.processing => 'Processing…',
    VirtualTourStatus.ready => 'Ready',
    VirtualTourStatus.pendingVerification => 'Pending verification',
    VirtualTourStatus.approved => 'Approved',
    VirtualTourStatus.rejected => 'Rejected',
  };

  /// Best-effort tone for the free-text `User.status` field. Unknown words fall
  /// back to neutral rather than guessing a stronger claim.
  factory StatusBadge.forText(String status) {
    final s = status.toLowerCase();
    final tone =
        s.contains('pending') ||
            s.contains('processing') ||
            s.contains('draft') ||
            s.contains('review')
        ? 'warning'
        : s.contains('suspend') ||
              s.contains('reject') ||
              s.contains('banned') ||
              s.contains('inactive')
        ? 'danger'
        : s.contains('active') ||
              s.contains('verified') ||
              s.contains('approved') ||
              s.contains('ready')
        ? 'success'
        : 'neutral';
    return StatusBadge(status, tone: tone);
  }

  @override
  Component build(BuildContext context) {
    // The source's two pills differ only by the leading dot: `.st-*` has one
    // (via `::before`), `.badge-*` does not. So `dot` selects the family rather
    // than adding a child element — which also removes the old `.dot--*` span.
    final family = dot ? 'st st-' : 'badge badge-';
    return span(classes: '$family${pillToneClass(tone)}', [
      Component.text(label),
    ]);
  }
}

/// Label + control + optional hint/error. The label wraps the control, so the
/// association holds without every input needing a hand-written id
/// (audit W-10).
///
/// Named [labelText] rather than `label` because Jaspr exports a `label()`
/// element function, and a parameter of that name shadows it inside the body.
class Field extends StatelessComponent {
  final String labelText;

  final Component child;

  /// Helper text shown under the control.
  final String? hint;

  /// Validation message. Replaces [hint] when present.
  final String? error;

  const Field({
    super.key,
    required this.labelText,
    required this.child,
    this.hint,
    this.error,
  });

  @override
  Component build(BuildContext context) {
    return label(classes: 'field', [
      span(classes: 'field__label', [Component.text(labelText)]),
      child,
      if (error != null)
        span(classes: 'field__error-row', [
          Icon('error_outline', size: 'sm'),
          span(classes: 'field__error', [Component.text(error!)]),
        ])
      else if (hint != null)
        span(classes: 'field__hint', [Component.text(hint!)]),
    ]);
  }
}

/// Search input with a leading icon.
///
/// The visible label is [label] when given, otherwise [ariaLabel] — the source
/// always renders a `<label>` above the control, so there is no unlabelled
/// state (audit W-10).
class SearchInput extends StatelessComponent {
  final String placeholder;
  final String ariaLabel;
  final void Function(String) onInput;

  /// Visible label above the input. Falls back to [ariaLabel].
  final String? label;

  const SearchInput({
    super.key,
    required this.placeholder,
    required this.ariaLabel,
    required this.onInput,
    this.label,
  });

  @override
  Component build(BuildContext context) {
    // Source vocabulary: `.field` with a label and the control, plus a
    // leading-icon row for the search affordance. Previously a
    // `.search` / `.search__icon` / `.input` wrapper of this file's own.
    return div(classes: 'field', [
      span(classes: 'field__label', [Component.text(label ?? ariaLabel)]),
      div(classes: 'field__control', [
        span(classes: 'field__icon', [Icon('search', size: 'sm')]),
        input(
          type: InputType.search,
          attributes: {'placeholder': placeholder, 'aria-label': ariaLabel},
          events: events<String>(onInput: onInput),
        ),
      ]),
    ]);
  }
}

/// Breadcrumb trail. Only the final item is meaningful on its own, so the
/// earlier items are rendered as plain text rather than anchors — linking to a
/// parent route that does not exist for a given context would be worse than
/// showing no trail at all.
class Breadcrumbs extends StatelessComponent {
  final List<String> items;

  const Breadcrumbs(this.items, {super.key});

  @override
  Component build(BuildContext context) {
    if (items.length <= 1) return const span([]);
    return nav(classes: 'crumbs', [
      for (var i = 0; i < items.length; i++) ...[
        if (i > 0) span(classes: 'crumbs__sep', [Component.text('›')]),
        if (i == items.length - 1)
          span(classes: 'crumbs__item crumbs__item--current', [
            Component.text(items[i]),
          ])
        else
          span(classes: 'crumbs__item crumbs__link', [
            // A plain span, not an anchor: the parent's route is the only
            // meaningful target and inventing a link to a section that may
            // not exist as a route would be worse than no trail at all.
            Component.text(items[i]),
          ]),
      ],
    ]);
  }
}
