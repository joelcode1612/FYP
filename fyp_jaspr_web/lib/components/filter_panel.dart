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
/// Styling lives entirely in `styles.css` (`.filter*` classes); this component
/// carries class names only, per DESIGN.md §8 Do #2.
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

  const FilterPanel({
    super.key,
    required this.filter,
    required this.source,
    required this.results,
    required this.onChanged,
    required this.onReset,
  });

  @override
  Component build(BuildContext context) {
    final types = PropertyFilter.typesIn(source);
    final cities = PropertyFilter.citiesIn(source);
    final states = PropertyFilter.statesIn(source);
    final validation = filter.validate();
    final chips = filter.activeChips;

    return div(classes: 'filter', [
      // --- Head: title + reset -------------------------------------------
      div(classes: 'filter__head', [
        span(classes: 'filter__title', [Component.text('Filters')]),
        button(
          classes: 'filter__reset',
          attributes: {'type': 'button', if (filter.isEmpty) 'disabled': ''},
          events: events(onClick: onReset),
          [Component.text('Reset')],
        ),
      ]),

      // --- Validation ----------------------------------------------------
      if (validation != null)
        div(classes: 'filter__error', [
          Icon('error_outline', size: 'sm'),
          Component.text(validation),
        ]),

      // --- A. Rental budget ----------------------------------------------
      _group('Rental budget', [
        div(classes: 'filter__range', [
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
        ]),
      ]),

      // --- B. Property details -------------------------------------------
      _group('Property details', [
        div(classes: 'filter__range', [
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
        _select(
          fieldLabel: 'Property type',
          value: filter.propertyType,
          options: types,
          onChanged: (v) => onChanged(filter.copyWith(propertyType: v)),
        ),
      ]),

      // --- C. Location ----------------------------------------------------
      _group('Location', [
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
      ]),

      // --- D. Verification ------------------------------------------------
      // Kept conceptually separate from suitability: verification is a fact
      // about the listing, suitability is a model estimate. They are not the
      // same kind of claim and must not be presented as one.
      _group('Verification', [
        label(classes: 'filter__check', [
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
          span([Component.text('Verified properties only')]),
        ]),
      ]),

      // --- Applied filters ------------------------------------------------
      if (chips.isNotEmpty)
        _group('Applied filters', [
          div(classes: 'filter__chips', [
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

      // --- Result count ---------------------------------------------------
      // Comes from the actual filtered list, never a hardcoded figure.
      p(
        classes: validation != null
            ? 'filter__count filter__count--error'
            : 'filter__count',
        [
          Component.text(
            validation != null
                ? 'Fix the range above to see results.'
                : '${results.length} of ${source.length} properties',
          ),
        ],
      ),
    ]);
  }

  Component _group(String title, List<Component> children) =>
      div(classes: 'filter__group', [
        span(classes: 'filter__label', [Component.text(title)]),
        ...children,
      ]);

  Component _numberField({
    required String fieldLabel,
    required double? value,
    required void Function(double?) onChanged,
  }) => label(classes: 'filter__field', [
    span(classes: 'filter__field-label', [Component.text(fieldLabel)]),
    input(
      classes: 'input',
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
  }) => label(classes: 'filter__field', [
    span(classes: 'filter__field-label', [Component.text(fieldLabel)]),
    select(
      classes: 'filter__select',
      events: events<String>(onInput: (raw) => onChanged(raw)),
      [
        for (final opt in options)
          option(
            value: opt,
            attributes: {if (opt == value) 'selected': ''},
            [Component.text(opt)],
          ),
      ],
    ),
  ]);
}
