import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:shared_logic/shared_logic.dart';

import 'ui.dart';

/// The property filter panel — groups, controls and applied-filter chips.
///
/// Replaces the four hardcoded city chips the Explore page used to render
/// (`['All', 'Subang Jaya', 'Petaling Jaya', 'Shah Alam']`). Those were real
/// places but they were *data* baked into a widget, and they were already
/// wrong: the listing set contains six cities, so George Town, Melaka and
/// Puchong were unreachable through the UI.
///
/// Every option here is derived from the properties actually loaded, via
/// [PropertyFilter.typesIn] / [citiesIn] / [statesIn], so the panel can never
/// advertise a filter that matches nothing or hide one that would.
///
/// Styling lives entirely in `styles.css` (`.filters`, `.field`, `.frow`,
/// `.checkpill`, `.chips`, `.actions-row`, `.err`); this component carries class
/// names only, per DESIGN.md §8 Do #2. Previously it emitted its own `filter__*`
/// vocabulary, which had no counterpart in the source design.
///
/// NOTE: no parameter below may be called `label`, `select` or `option` — those
/// are Jaspr DOM element functions, and a same-named parameter would shadow them
/// inside the method body.
class FilterPanel extends StatelessComponent {
  final PropertyFilter filter;

  /// The unfiltered set the options and result count are derived from.
  final List<CommercialProperty> source;

  /// The filtered result, used only for the count.
  final List<CommercialProperty> results;

  final void Function(PropertyFilter) onChanged;
  final void Function() onReset;

  /// Current keyword query. The source's form leads with a keyword field inside
  /// the same `.filters` panel; the target keeps the query on the cubit, so it
  /// is passed in and echoed back through [onQueryChanged].
  final String query;
  final void Function(String)? onQueryChanged;

  const FilterPanel({
    super.key,
    required this.filter,
    required this.source,
    required this.results,
    required this.onChanged,
    required this.onReset,
    this.query = '',
    this.onQueryChanged,
  });

  @override
  Component build(BuildContext context) {
    final types = PropertyFilter.typesIn(source);
    final cities = PropertyFilter.citiesIn(source);
    final states = PropertyFilter.statesIn(source);
    final validation = filter.validate();
    final chips = filter.activeChips;

    // Layout follows the source form exactly: one keyword `.field`, then two
    // four-column `.frow`s. The previous version nested a `.frow` inside a
    // `.field` for the budget pair, which produced a third, uneven row.
    return div(classes: 'filters', [
      // --- Keyword ---------------------------------------------------------
      div(classes: 'field', [
        span(classes: 'field__label', [Component.text('Keyword or location')]),
        input(
          attributes: {
            'type': 'search',
            'placeholder': 'e.g. Bangsar, cafe, Jalan Alor',
            if (query.isNotEmpty) 'value': query,
          },
          events: events<String>(onInput: (v) => onQueryChanged?.call(v)),
        ),
      ]),

      // --- A. Ranges: rent and floor area ----------------------------------
      div(classes: 'frow', [
        _numberField(
          fieldLabel: 'Min rent (RM)',
          value: filter.minRentalRm,
          onChanged: (v) => onChanged(
            filter.copyWith(minRentalRm: v, clearMinRental: v == null),
          ),
        ),
        _numberField(
          fieldLabel: 'Max rent (RM)',
          value: filter.maxRentalRm,
          onChanged: (v) => onChanged(
            filter.copyWith(maxRentalRm: v, clearMaxRental: v == null),
          ),
        ),
        _numberField(
          fieldLabel: 'Min area (sq ft)',
          value: filter.minSizeSqft,
          onChanged: (v) => onChanged(
            filter.copyWith(minSizeSqft: v, clearMinSize: v == null),
          ),
        ),
        _numberField(
          fieldLabel: 'Max area (sq ft)',
          value: filter.maxSizeSqft,
          onChanged: (v) => onChanged(
            filter.copyWith(maxSizeSqft: v, clearMaxSize: v == null),
          ),
        ),
      ]),

      // --- B. Type, location, verification, actions ------------------------
      div(classes: 'frow', [
        _select(
          fieldLabel: 'Property type',
          value: filter.propertyType,
          options: types,
          onChanged: (v) => onChanged(filter.copyWith(propertyType: v)),
        ),
        _select(
          fieldLabel: 'State',
          value: filter.state,
          options: states,
          onChanged: (v) => onChanged(filter.copyWith(state: v)),
        ),
        _select(
          fieldLabel: 'City',
          value: filter.city,
          options: cities,
          onChanged: (v) => onChanged(filter.copyWith(city: v)),
        ),

        // Verification is a fact about the listing, suitability is a model
        // estimate. They are not the same kind of claim and are never merged.
        div(classes: 'field', [
          span(classes: 'field__label', [Component.text('Verification')]),
          label(classes: 'checkpill', [
            input(
              attributes: {
                'type': 'checkbox',
                if (filter.verifiedOnly) 'checked': '',
              },
              events: events(
                onChange: (_) => onChanged(
                  filter.copyWith(verifiedOnly: !filter.verifiedOnly),
                ),
              ),
            ),
            span([Component.text('Verified only')]),
          ]),
        ]),
      ]),

      // --- Validation ------------------------------------------------------
      if (validation != null) p(classes: 'err', [Component.text(validation)]),

      // --- Applied filters -------------------------------------------------
      if (chips.isNotEmpty)
        div(classes: 'field', [
          span(classes: 'field__label', [Component.text('Applied filters')]),
          div(classes: 'chips', [
            for (final chip in chips)
              button(
                classes: 'chip',
                attributes: {'type': 'button', 'title': 'Remove ${chip.label}'},
                events: events(
                  onClick: () => onChanged(filter.without(chip.id)),
                ),
                [Component.text(chip.label), Icon('close', size: 'sm')],
              ),
          ]),
        ]),

      // --- Actions ---------------------------------------------------------
      div(classes: 'actions-row', [
        button(
          classes: 'btn btn--primary',
          attributes: {'type': 'button'},
          events: events(onClick: onReset),
          [Component.text('Clear all')],
        ),
        span(classes: 'filters__count', [
          Component.text(
            validation != null
                ? 'Fix the range above to see results.'
                : '${results.length} of ${source.length} properties',
          ),
        ]),
      ]),
    ]);
  }

  Component _numberField({
    required String fieldLabel,
    required double? value,
    required void Function(double?) onChanged,
  }) => div(classes: 'field', [
    span(classes: 'field__label', [Component.text(fieldLabel)]),
    input(
      attributes: {
        'type': 'number',
        'min': '0',
        'inputmode': 'numeric',
        'placeholder': 'Any',
        if (value != null) 'value': value.toStringAsFixed(0),
      },
      events: events<String>(
        onInput: (raw) {
          final trimmed = raw.trim();
          onChanged(trimmed.isEmpty ? null : double.tryParse(trimmed));
        },
      ),
    ),
  ]);

  Component _select({
    required String fieldLabel,
    required String value,
    required List<String> options,
    required void Function(String) onChanged,
  }) => div(classes: 'field', [
    span(classes: 'field__label', [Component.text(fieldLabel)]),
    select(events: events<String>(onInput: (raw) => onChanged(raw)), [
      for (final opt in options)
        option(
          value: opt,
          attributes: {if (opt == value) 'selected': ''},
          [Component.text(opt)],
        ),
    ]),
  ]);
}
