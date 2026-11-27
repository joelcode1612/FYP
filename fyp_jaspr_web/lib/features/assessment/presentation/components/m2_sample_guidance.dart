/// Sample-answer guidance for the M2 business declaration.
///
/// These are **synthetic examples**, written for the Brew & Focus Café
/// scenario. They are not owner declarations, not customer evidence and not
/// database records. Nothing here is written to an answer, and nothing here
/// changes requiredness, validation, the instrument or any backend contract —
/// the module only decides *which sentence to show beside which input*.
///
/// Why this is a separate file
/// ---------------------------
/// The declaration form is schema-driven: `m2_workflow_panel.dart` renders
/// whatever fields the instrument's `value_schema` declares and never restates
/// a question or an option code. Example wording is the one thing that is
/// *not* instrument data — it is editorial help — so it lives apart from the
/// renderer and cannot be mistaken for a second copy of the questionnaire.
///
/// Two rules keep the examples honest:
///
///   * an example is shown **only when the field is applicable** under the
///     owner's current selections. A `details` example for `CONFIRMED` is wrong
///     when the review is `NEEDS_CORRECTION`; a product example for `COFFEE` is
///     wrong when the owner selected only `BAKED_GOODS`. Where no matching
///     example exists the guidance is hidden rather than approximated.
///   * an example never becomes a value. It is rendered outside the editable
///     control so it stays readable while the owner types, and no code path
///     copies it into an answer.
///
/// Identities are the instrument's own: item keys `M2V2-12` … `M2V2-19` and the
/// field names declared in each item's `value_schema` (`review_status`,
/// `details`, `products`, `hypothesis_text`, …).
library;

/// The instrument these examples were written for.
///
/// The wording names specific products, prices and customer groups from one
/// scenario. On any other instrument version those identities and limits may
/// have moved, so the guidance is withheld rather than shown against fields it
/// was not written for.
const String m2SampleGuidanceInstrument = 'M2V2-20261122-1';

/// Reads the selected option codes of another item, so an example can follow a
/// selection made earlier in the same declaration.
typedef M2SelectionLookup = List<String> Function(String itemKey);

/// One example block: a heading that says what the example is for, and the
/// lines to show under it.
class M2SampleGuidance {
  /// Says which selection the example follows, e.g. "for the categories you
  /// selected". Never claims to be the owner's answer.
  final String heading;

  /// The example lines, in the order they should read.
  final List<String> lines;

  const M2SampleGuidance(this.heading, this.lines);
}

// --- M2V2-12 ----------------------------------------------------------------

const String _conceptTitle = 'Brew & Focus Café';

const String _conceptDetails =
    'I intend to establish an affordable café in Selangor that provides coffee, '
    'non-coffee beverages and pastries for students, remote workers and office '
    'workers. The café will provide a comfortable environment for studying and '
    'working, with dine-in and takeaway services. I would like to investigate '
    'customer preferences regarding products, pricing, service formats and café '
    'facilities before finalizing my business concept.';

const String _correctionDetails =
    'Please change the service format to dine-in and takeaway only; delivery is '
    'not part of my current plan.';

const String _notReadyDetails =
    'I have not finalized the target customer groups and need to review them '
    'before confirming.';

// --- M2V2-13 ----------------------------------------------------------------

/// One example product row. `category` is an M2V2-03 option code, which is what
/// lets the example follow the categories the owner actually selected.
class _SampleProduct {
  final String name;
  final String category;
  final String description;
  const _SampleProduct(this.name, this.category, this.description);
}

const List<_SampleProduct> _sampleProducts = [
  _SampleProduct(
    'Iced Café Latte',
    'COFFEE',
    'Espresso with chilled milk and ice.',
  ),
  _SampleProduct(
    'Americano',
    'COFFEE',
    'Espresso diluted with water, available hot or iced.',
  ),
  _SampleProduct(
    'Matcha Latte',
    'NON_COFFEE',
    'Matcha green tea mixed with milk.',
  ),
  _SampleProduct(
    'Chocolate Milk',
    'NON_COFFEE',
    'Chocolate-flavoured milk beverage.',
  ),
  _SampleProduct(
    'Butter Croissant',
    'BAKED_GOODS',
    'Flaky butter pastry served warm.',
  ),
  _SampleProduct(
    'Chocolate Muffin',
    'BAKED_GOODS',
    'Chocolate muffin suitable for a light snack.',
  ),
];

// --- M2V2-14 ----------------------------------------------------------------

const String _pricedProductRef = 'Iced Café Latte';
const String _pricedSize = '350 ml';
const String _pricedAmount = '12.00';
const String _pricedTotalDetails =
    'RM 12.00 for one 350 ml Iced Café Latte, with no additional charges.';

// --- M2V2-16 ----------------------------------------------------------------

const String _otherFeatureText =
    'The café will provide complimentary Wi-Fi, accessible power outlets, '
    'comfortable study desks and adjustable seating arrangements. I am '
    'considering a dedicated quiet study area, but I am uncertain whether '
    'customers would prefer individual study desks or shared collaborative '
    'tables.';

// --- M2V2-17 ----------------------------------------------------------------

/// One example customer-group definition, keyed by the M2V2-04 option code so
/// only the groups the owner selected are shown.
class _SampleSegment {
  final String group;
  final String description;
  const _SampleSegment(this.group, this.description);
}

const List<_SampleSegment> _sampleSegments = [
  _SampleSegment(
    'STUDENTS',
    'University and college students who need an affordable and comfortable '
        'environment for studying, completing assignments and meeting '
        'classmates.',
  ),
  _SampleSegment(
    'OFFICE_WORKERS',
    'Employees working near the café who may purchase beverages and pastries '
        'before work, during lunch breaks or after working hours.',
  ),
  _SampleSegment(
    'REMOTE_WORKERS',
    'Freelancers, self-employed individuals and remote employees who require '
        'reliable internet access, comfortable seating and a suitable '
        'environment for completing their daily work.',
  ),
];

// --- M2V2-18 ----------------------------------------------------------------

const String _hypothesisText =
    'I believe university students and remote workers may have difficulty '
    'finding affordable cafés that provide a suitable environment for extended '
    'study or working sessions. I intend to address this need by providing '
    'reliable Wi-Fi, accessible power outlets, comfortable seating and '
    'reasonably priced beverages.\n\n'
    'However, I am uncertain whether customers would accept a minimum purchase '
    'requirement for using the study area, whether they would prefer individual '
    'desks or shared tables, and whether they would be interested in reserving '
    'seats in advance. I would like to investigate these uncertainties before '
    'finalizing the café\'s operating model.';

// --- M2V2-19 ----------------------------------------------------------------

const String _planningExplanation =
    'I am currently planning the café concept and have not yet finalized the '
    'business premises, operating hours or complete product menu. I have '
    'identified my intended customer groups and preliminary product offerings, '
    'but my decisions are mainly based on personal observations and informal '
    'feedback.\n\n'
    'Before proceeding with the business launch, I would like to collect '
    'customer research evidence to validate my assumptions about customer '
    'demand, pricing, café facilities and operating arrangements.';

// --- resolver ---------------------------------------------------------------

List<String> _codes(Object? value) =>
    value is List ? [for (final v in value) '$v'] : const <String>[];

/// The example to show beside [fieldName] of [itemKey], or null when no
/// example is applicable.
///
/// [values] are the composite values currently entered for this item (saved
/// plus unsaved edits), so switching a decision changes the guidance without a
/// round trip. [selectedCodes] reads other items, which is how the product and
/// segment examples follow selections made earlier.
M2SampleGuidance? m2SampleGuidance({
  required String? instrumentVersion,
  required String itemKey,
  required String fieldName,
  required Map<String, dynamic> values,
  required M2SelectionLookup selectedCodes,
}) {
  if (instrumentVersion != m2SampleGuidanceInstrument) return null;

  switch (itemKey) {
    // ------------------------------------------------------------ M2V2-12
    case 'M2V2-12':
      if (fieldName == 'title') {
        return const M2SampleGuidance(
          'Example title — sample text, not your answer',
          [_conceptTitle],
        );
      }
      if (fieldName == 'details') {
        // The review decision decides what a useful example is. No decision
        // means no example: a CONFIRMED description would be the wrong help for
        // an owner about to ask for a correction.
        final status = '${values['review_status'] ?? ''}';
        switch (status) {
          case 'CONFIRMED':
            return const M2SampleGuidance(
              'Example for “Confirmed” — sample text, not your answer',
              [_conceptDetails],
            );
          case 'NEEDS_CORRECTION':
            return const M2SampleGuidance(
              'Example for “Needs correction” — sample text, not your answer',
              [_correctionDetails],
            );
          case 'NOT_READY':
            return const M2SampleGuidance(
              'Example for “Not ready” — sample text, not your answer',
              [_notReadyDetails],
            );
        }
        return null;
      }
      return null;

    // ------------------------------------------------------------ M2V2-13
    case 'M2V2-13':
      if (fieldName != 'products') return null;
      // The example rows are filtered by the categories this item declares, or
      // by M2V2-03 when the categories have not been chosen on this item yet.
      final chosen = _codes(values['categories']);
      final effective = chosen.isEmpty ? selectedCodes('M2V2-03') : chosen;
      if (effective.isEmpty) return null;
      final rows = [
        for (final product in _sampleProducts)
          if (effective.contains(product.category)) product,
      ];
      if (rows.isEmpty) return null;
      return M2SampleGuidance(
        'Example products for the categories you selected — sample text, not '
        'your answer',
        [
          for (final product in rows)
            '${product.name} · ${product.category} · ${product.description}',
        ],
      );

    // ------------------------------------------------------------ M2V2-14
    case 'M2V2-14':
      // Only `PRICED` has a priced offer to describe. Under
      // `PRICE_NOT_DECIDED` the instrument deliberately carries no amount, so
      // showing a price example there would contradict the decision.
      if ('${values['decision'] ?? ''}' != 'PRICED') return null;
      switch (fieldName) {
        case 'product_ref':
          return const M2SampleGuidance(
            'Example product — sample text, not your answer',
            [_pricedProductRef],
          );
        case 'size_quantity':
          return const M2SampleGuidance(
            'Example size — sample text, not your answer',
            [_pricedSize],
          );
        case 'amount_myr':
          return const M2SampleGuidance(
            'Example amount — sample text, not your answer',
            [_pricedAmount],
          );
        case 'total_price_details':
          return const M2SampleGuidance(
            'Example total price — sample text, not your answer',
            [_pricedTotalDetails],
          );
      }
      return null;

    // ------------------------------------------------------------ M2V2-16
    case 'M2V2-16':
      if (fieldName != 'other_feature_text') return null;
      // This field is only applicable when `OTHER` is one of the features.
      if (!_codes(values['features']).contains('OTHER')) return null;
      return const M2SampleGuidance(
        'Example for “Other” — sample text, not your answer',
        [_otherFeatureText],
      );

    // ------------------------------------------------------------ M2V2-17
    case 'M2V2-17':
      if (fieldName != 'segments') return null;
      final groups = selectedCodes('M2V2-04');
      if (groups.isEmpty) return null;
      final rows = [
        for (final segment in _sampleSegments)
          if (groups.contains(segment.group)) segment,
      ];
      if (rows.isEmpty) return null;
      return M2SampleGuidance(
        'Example definitions for the customer groups you selected — sample '
        'text, not your answer',
        [
          for (final segment in rows)
            '${segment.group} · ${segment.description}',
        ],
      );

    // ------------------------------------------------------------ M2V2-18
    case 'M2V2-18':
      if (fieldName != 'hypothesis_text') return null;
      // Optional item: the text field only means something once the owner has
      // said they have a hypothesis. `NOT_ESTABLISHED` and
      // `NO_SPECIFIC_PROBLEM` are complete answers with no text.
      if ('${values['hypothesis_status'] ?? ''}' != 'HYPOTHESIS_IDENTIFIED') {
        return null;
      }
      return const M2SampleGuidance(
        'Example hypothesis — sample text, not your answer',
        [_hypothesisText],
      );

    // ------------------------------------------------------------ M2V2-19
    case 'M2V2-19':
      if (fieldName != 'decision_explanation') return null;
      // The example describes a business that is still planning. Under any
      // other stage it would contradict the owner's own selection.
      if ('${values['stage'] ?? ''}' != 'PLANNING') return null;
      return const M2SampleGuidance(
        'Example for “Planning” — sample text, not your answer',
        [_planningExplanation],
      );
  }
  return null;
}
