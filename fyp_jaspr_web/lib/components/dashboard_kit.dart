import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';

import 'ui.dart';

/// Dashboard building blocks the four workspaces share but `ui.dart` did not
/// have: a labelled callout, one modal to rule the three private
/// `_ConfirmDialog`s, and a records table.
///
/// These reuse the stylesheet's existing vocabulary wherever it already covers
/// the job — `.audit-table` for records, `.who`/`.sub` for two-line cells,
/// `.notice-*` for tone colours, `.overlay`/`.dialog`/`.btn-row` for modals — so
/// the dark staff theme and every later restyle apply to them for free. Only
/// `.callout`, `.aside-list`/`.aside-row`/`.circ` and the numeric column
/// alignment are genuinely new.

/// Explanatory banner — the design reference's `.callout`.
///
/// Used wherever a card must state a permission boundary or a data caveat
/// ("demonstration only", "only assigned properties are editable"). `warning`
/// is for a caveat that changes what the reader should trust.
class Callout extends StatelessComponent {
  final String body;

  /// `info` | `success` | `warning` | `danger`.
  final String tone;

  /// Leading glyph; defaults to a shield because most callouts here describe a
  /// boundary.
  final String icon;

  const Callout(
    this.body, {
    super.key,
    this.tone = 'info',
    this.icon = 'shield',
  });

  @override
  Component build(BuildContext context) {
    return div(classes: 'callout callout-$tone', [
      Icon(icon, size: 'sm'),
      Component.text(body),
    ]);
  }
}

/// One line item in a card list: badge, title, caption, optional trailing
/// status or action.
class AsideRow extends StatelessComponent {
  final String badge;
  final String title;
  final String caption;

  /// `blue` | `teal` | `amber` | `neutral`.
  final String tone;
  final Component? end;

  const AsideRow({
    super.key,
    required this.badge,
    required this.title,
    required this.caption,
    this.tone = 'neutral',
    this.end,
  });

  @override
  Component build(BuildContext context) {
    return div(classes: 'aside-row', [
      span(classes: 'circ circ-$tone', [Component.text(badge)]),
      div(classes: 'grow', [
        span(classes: 'who', [Component.text(title)]),
        span(classes: 'sub', [Component.text(caption)]),
      ]),
      if (end != null) div(classes: 'aside-row__end', [end!]),
    ]);
  }
}

/// Column definition for [DataTable].
class DataColumn {
  final String label;

  /// Right-aligned — prices, areas and counts.
  final bool numeric;

  /// Right-aligned and unwrapped — the action column.
  final bool actions;

  const DataColumn(this.label, {this.numeric = false, this.actions = false});

  String get _cls => numeric
      ? 'num'
      : actions
      ? 'acts'
      : '';
}

/// Records table — the stylesheet's `.audit-table` behind a horizontal scroll
/// wrapper, with the frame and column alignment owned here instead of
/// re-typed by every queue page.
///
/// Rows arrive as lists of already-rendered cells so callers keep control of
/// pills and links.
class DataTable extends StatelessComponent {
  final List<DataColumn> columns;
  final List<List<Component>> rows;

  /// Shown instead of an empty `<tbody>`.
  final String? emptyLabel;

  const DataTable({
    super.key,
    required this.columns,
    required this.rows,
    this.emptyLabel,
  });

  @override
  Component build(BuildContext context) {
    if (rows.isEmpty && emptyLabel != null) {
      return EmptyState(title: 'Nothing to show', body: emptyLabel!);
    }
    return div([
      div(classes: 'table-scroll', [
        table(classes: 'audit-table', [
          thead([
            tr([
              for (final c in columns)
                th(classes: c._cls, [Component.text(c.label)]),
            ]),
          ]),
          tbody([
            for (final cells in rows)
              tr([
                for (var i = 0; i < cells.length; i++)
                  td(classes: i < columns.length ? columns[i]._cls : '', [
                    cells[i],
                  ]),
              ]),
          ]),
        ]),
      ]),
      // The table keeps its columns and scrolls sideways instead of wrapping
      // them into unreadable stacks, so say that out loud: an invisible
      // gesture is not an affordance.
      span(classes: 'table-hint', [
        Component.text('Scroll the table sideways for the other columns.'),
      ]),
    ]);
  }
}

/// A two-line table cell: bold primary text with a muted caption under it.
///
/// Uses the existing `.who` / `.sub` pair from `.audit-table` rather than a new
/// name for the same thing.
class CellIdentity extends StatelessComponent {
  final String title;
  final String caption;

  const CellIdentity({super.key, required this.title, required this.caption});

  @override
  Component build(BuildContext context) {
    return div([
      span(classes: 'who', [Component.text(title)]),
      span(classes: 'sub', [Component.text(caption)]),
    ]);
  }
}

/// Modal dialog with a title, body and right-aligned actions.
///
/// Replaces the three near-identical private `_ConfirmDialog` components the
/// owner tour pages each carried. Escape closes it and the overlay click
/// dismisses, matching the search and notification dialogs in
/// `topbar_controls.dart`.
class SitewiseDialog extends StatelessComponent {
  final String title;
  final Component body;
  final List<Component> actions;
  final void Function() onClose;

  /// Labelled for assistive tech; the visible [title] may be a question, the
  /// accessible name should say what the panel is.
  final String? ariaLabel;

  /// A dialog carrying a table needs the wider panel; the default 420px clips
  /// columns that no amount of scrolling inside the card can reach.
  final bool wide;

  const SitewiseDialog({
    super.key,
    required this.title,
    required this.body,
    required this.onClose,
    this.actions = const [],
    this.ariaLabel,
    this.wide = false,
  });

  @override
  Component build(BuildContext context) {
    return div(classes: 'overlay', events: events(onClick: onClose), [
      div(
        classes: wide ? 'dialog dialog--wide' : 'dialog',
        attributes: {
          'role': 'dialog',
          'aria-modal': 'true',
          'aria-label': ariaLabel ?? title,
        },
        events: {
          ...events(onClick: () {}),
          'keydown': (event) {
            final key = (event as dynamic).key;
            if (key == 'Escape' || key == 'Esc') onClose();
          },
        },
        [
          div(classes: 'dialog__title', [Component.text(title)]),
          body,
          if (actions.isNotEmpty)
            div(classes: 'btn-row', [for (final action in actions) action]),
        ],
      ),
    ]);
  }
}

/// A short status line confirming something just happened — with no backend
/// behind it. Inline rather than a toast, because the message stays attached to
/// the control that caused it.
class ActionNotice extends StatelessComponent {
  final String body;

  /// `info` | `warn` | `danger` — the tones `.notice` already ships with.
  final String tone;

  const ActionNotice(this.body, {super.key, this.tone = 'info'});

  @override
  Component build(BuildContext context) {
    return div(classes: 'notice notice-$tone', [
      Icon(tone == 'info' ? 'info' : 'error', size: 'sm'),
      Component.text(body),
    ]);
  }
}
