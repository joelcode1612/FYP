// Sample-answer guidance for the M2 declaration.
//
// The examples are editorial help, so what matters is *when* they appear: an
// example that contradicts the owner's own selection is worse than no example.
// These tests pin the applicability rules and the declared length limits, and
// they pin that the resolver never returns a value for a field the instrument
// did not declare.
import 'package:jaspr_test/jaspr_test.dart';
import 'package:sitewise_jaspr_web/features/assessment/presentation/components/m2_sample_guidance.dart';

const _instrument = 'M2V2-20261122-1';

List<String> _none(String _) => const <String>[];

M2SampleGuidance? _ask(
  String itemKey,
  String fieldName, {
  Map<String, dynamic> values = const {},
  M2SelectionLookup? selectedCodes,
  String? instrumentVersion = _instrument,
}) =>
    m2SampleGuidance(
      instrumentVersion: instrumentVersion,
      itemKey: itemKey,
      fieldName: fieldName,
      values: values,
      selectedCodes: selectedCodes ?? _none,
    );

String _text(M2SampleGuidance? g) => g == null ? '' : g.lines.join('\n');

void main() {
  group('the guidance is bound to one instrument', () {
    test('another instrument version gets no examples', () {
      expect(
        _ask('M2V2-12', 'title', instrumentVersion: 'M2V3-20270101-1'),
        isNull,
      );
      expect(_ask('M2V2-12', 'title', instrumentVersion: null), isNull);
      expect(_ask('M2V2-12', 'title'), isNotNull);
    });

    test('a field the item does not declare gets no example', () {
      // `details` exists on M2V2-12, not on M2V2-19.
      expect(_ask('M2V2-19', 'details', values: const {'stage': 'PLANNING'}),
          isNull);
      expect(_ask('M2V2-12', 'hypothesis_text'), isNull);
      // Structured fields are never given example prose.
      expect(_ask('M2V2-12', 'review_status'), isNull);
      expect(_ask('M2V2-16', 'features'), isNull);
      expect(_ask('M2V2-19', 'stage'), isNull);
    });
  });

  group('M2V2-12 — the example follows the review decision', () {
    test('the title example is available whenever the field is shown', () {
      expect(_text(_ask('M2V2-12', 'title')), contains('Brew & Focus Café'));
    });

    test('each decision gets its own example, and none crosses over', () {
      final confirmed = _text(
        _ask('M2V2-12', 'details', values: const {'review_status': 'CONFIRMED'}),
      );
      final correction = _text(
        _ask(
          'M2V2-12',
          'details',
          values: const {'review_status': 'NEEDS_CORRECTION'},
        ),
      );
      final notReady = _text(
        _ask('M2V2-12', 'details', values: const {'review_status': 'NOT_READY'}),
      );

      expect(confirmed, contains('affordable café in Selangor'));
      expect(correction, contains('dine-in and takeaway only'));
      expect(notReady, contains('have not finalized the target customer groups'));

      // A correction example must not read as a description of the concept.
      expect(correction, isNot(contains('affordable café in Selangor')));
      expect(notReady, isNot(contains('affordable café in Selangor')));
    });

    test('no decision means no example', () {
      // An owner who has not chosen yet would be pushed towards whichever
      // example happened to be first.
      expect(_ask('M2V2-12', 'details'), isNull);
      expect(_ask('M2V2-12', 'details', values: const {'review_status': ''}),
          isNull);
    });
  });

  group('M2V2-13 — product examples follow the selected categories', () {
    test('only the categories in force are shown', () {
      final coffee = _text(
        _ask(
          'M2V2-13',
          'products',
          values: const {
            'categories': ['COFFEE'],
          },
        ),
      );
      expect(coffee, contains('Iced Café Latte'));
      expect(coffee, isNot(contains('Matcha Latte')));
      expect(coffee, isNot(contains('Butter Croissant')));
    });

    test('the item falls back to M2V2-03 when its own field is empty', () {
      final text = _text(
        _ask(
          'M2V2-13',
          'products',
          selectedCodes: (key) =>
              key == 'M2V2-03' ? const ['BAKED_GOODS'] : const [],
        ),
      );
      expect(text, contains('Butter Croissant'));
      expect(text, isNot(contains('Americano')));
    });

    test('no categories means no product example', () {
      expect(_ask('M2V2-13', 'products'), isNull);
    });

    test('a category with no example hides the block rather than inventing one',
        () {
      // M2V2-03 can hold a category this guide has no product for.
      expect(
        _ask(
          'M2V2-13',
          'products',
          values: const {
            'categories': ['SOMETHING_ELSE'],
          },
        ),
        isNull,
      );
    });
  });

  group('M2V2-14 — priced offer examples follow the decision', () {
    test('nothing is shown while the price is not decided', () {
      // `PRICE_NOT_DECIDED` deliberately carries no amount; a price example
      // would contradict the decision the owner recorded.
      for (final field in const [
        'product_ref',
        'size_quantity',
        'amount_myr',
        'total_price_details',
      ]) {
        expect(
          _ask('M2V2-14', field, values: const {'decision': 'PRICE_NOT_DECIDED'}),
          isNull,
          reason: field,
        );
        expect(_ask('M2V2-14', field), isNull, reason: field);
      }
    });

    test('each priced field gets its own example', () {
      const priced = {'decision': 'PRICED'};
      expect(_text(_ask('M2V2-14', 'product_ref', values: priced)),
          'Iced Café Latte');
      expect(_text(_ask('M2V2-14', 'size_quantity', values: priced)), '350 ml');
      expect(_text(_ask('M2V2-14', 'amount_myr', values: priced)), '12.00');
      expect(
        _text(_ask('M2V2-14', 'total_price_details', values: priced)),
        contains('RM 12.00 for one 350 ml Iced Café Latte'),
      );
    });
  });

  group('M2V2-16 — the “Other” text follows the feature selection', () {
    test('it appears only when OTHER is selected', () {
      expect(
        _ask(
          'M2V2-16',
          'other_feature_text',
          values: const {
            'features': ['QUIET_WORK_SPACE'],
          },
        ),
        isNull,
      );
      expect(
        _text(
          _ask(
            'M2V2-16',
            'other_feature_text',
            values: const {
              'features': ['QUIET_WORK_SPACE', 'OTHER'],
            },
          ),
        ),
        contains('complimentary Wi-Fi'),
      );
    });
  });

  group('M2V2-17 — group definitions follow the selected groups', () {
    test('only the groups selected in M2V2-04 are shown', () {
      final text = _text(
        _ask(
          'M2V2-17',
          'segments',
          selectedCodes: (key) => key == 'M2V2-04'
              ? const ['STUDENTS', 'REMOTE_WORKERS']
              : const [],
        ),
      );
      expect(text, contains('STUDENTS'));
      expect(text, contains('REMOTE_WORKERS'));
      expect(text, isNot(contains('OFFICE_WORKERS')));
    });

    test('no selected groups means no example', () {
      expect(_ask('M2V2-17', 'segments'), isNull);
    });
  });

  group('M2V2-18 — the hypothesis text follows the status', () {
    test('it appears only for HYPOTHESIS_IDENTIFIED', () {
      for (final status in const ['NOT_ESTABLISHED', 'NO_SPECIFIC_PROBLEM', '']) {
        expect(
          _ask('M2V2-18', 'hypothesis_text',
              values: {'hypothesis_status': status}),
          isNull,
          reason: status,
        );
      }
      expect(
        _text(
          _ask(
            'M2V2-18',
            'hypothesis_text',
            values: const {'hypothesis_status': 'HYPOTHESIS_IDENTIFIED'},
          ),
        ),
        contains('minimum purchase requirement'),
      );
    });
  });

  group('M2V2-19 — the stage explanation follows the stage', () {
    test('it appears only for PLANNING, because that is what it describes', () {
      for (final stage in const ['IDEA', 'CONCEPT_TESTING', 'OPERATING', 'UNSURE']) {
        expect(
          _ask('M2V2-19', 'decision_explanation', values: {'stage': stage}),
          isNull,
          reason: stage,
        );
      }
      expect(
        _text(
          _ask('M2V2-19', 'decision_explanation',
              values: const {'stage': 'PLANNING'}),
        ),
        contains('planning the café concept'),
      );
    });
  });

  group('every example fits the declared field limits', () {
    // The instrument's own maxima. An example longer than its field is rejected
    // by the same validator that checks a typed answer, so it would be
    // unusable guidance.
    const limits = <String, Map<String, int>>{
      'M2V2-12': {'title': 200, 'details': 4000},
      'M2V2-14': {
        'product_ref': 200,
        'size_quantity': 100,
        'amount_myr': 12,
        'total_price_details': 1000,
      },
      'M2V2-16': {'other_feature_text': 500},
      'M2V2-18': {'hypothesis_text': 2000},
      'M2V2-19': {'decision_explanation': 2000},
    };

    final drivers = <String, Map<String, dynamic>>{
      'M2V2-12': const {'review_status': 'CONFIRMED'},
      'M2V2-14': const {'decision': 'PRICED'},
      'M2V2-16': const {
        'features': ['OTHER'],
      },
      'M2V2-18': const {'hypothesis_status': 'HYPOTHESIS_IDENTIFIED'},
      'M2V2-19': const {'stage': 'PLANNING'},
    };

    for (final entry in limits.entries) {
      for (final field in entry.value.entries) {
        test('${entry.key} ${field.key} fits ${field.value}', () {
          final text = _text(
            _ask(entry.key, field.key, values: drivers[entry.key] ?? const {}),
          );
          expect(text, isNotEmpty, reason: 'no example was produced');
          expect(text.length, lessThanOrEqualTo(field.value));
        });
      }
    }

    test('product and segment examples fit their own limits', () {
      final products = _ask(
        'M2V2-13',
        'products',
        values: const {
          'categories': ['COFFEE', 'NON_COFFEE', 'BAKED_GOODS'],
        },
      )!;
      expect(products.lines, hasLength(6));
      for (final line in products.lines) {
        // name ≤ 200, category ≤ 64, description ≤ 1000.
        expect(line.length, lessThanOrEqualTo(200 + 64 + 1000 + 8));
      }

      final segments = _ask(
        'M2V2-17',
        'segments',
        selectedCodes: (_) => const [
          'STUDENTS',
          'OFFICE_WORKERS',
          'REMOTE_WORKERS',
        ],
      )!;
      expect(segments.lines, hasLength(3));
      for (final line in segments.lines) {
        expect(line.length, lessThanOrEqualTo(64 + 1000 + 8));
      }
    });
  });

  group('the guidance never claims to be an answer', () {
    test('every heading says it is sample text', () {
      final cases = <M2SampleGuidance?>[
        _ask('M2V2-12', 'title'),
        _ask('M2V2-12', 'details', values: const {'review_status': 'CONFIRMED'}),
        _ask('M2V2-14', 'amount_myr', values: const {'decision': 'PRICED'}),
        _ask(
          'M2V2-16',
          'other_feature_text',
          values: const {
            'features': ['OTHER'],
          },
        ),
        _ask(
          'M2V2-18',
          'hypothesis_text',
          values: const {'hypothesis_status': 'HYPOTHESIS_IDENTIFIED'},
        ),
        _ask('M2V2-19', 'decision_explanation',
            values: const {'stage': 'PLANNING'}),
      ];
      for (final example in cases) {
        expect(example, isNotNull);
        expect(example!.heading.toLowerCase(), contains('sample text'));
        expect(example.heading.toLowerCase(), contains('not your answer'));
      }
    });
  });
}
