// Behavioural verification for the shared PropertyFilter.
//
// Type-checking proves it compiles; this proves the matching, validation and
// chip-removal rules behave. Run:  dart run tool/verify_property_filter.dart
//
// Not part of the package's public API and not shipped.

import 'package:shared_logic/shared_logic.dart';

int _failures = 0;

void check(String label, Object? actual, Object? expected) {
  final ok = '$actual' == '$expected';
  if (!ok) _failures++;
  print('${ok ? "PASS" : "FAIL"}  $label  (got: $actual, want: $expected)');
}

void checkTrue(String label, bool actual) {
  if (!actual) _failures++;
  print('${actual ? "PASS" : "FAIL"}  $label');
}

void main() {
  final all = DemoData.properties;
  print('fixture: ${all.length} properties\n');

  // ---------------------------------------------------------------- empty
  print('--- empty filter ---');
  checkTrue('empty is empty', PropertyFilter.empty.isEmpty);
  check('empty has no chips', PropertyFilter.empty.activeCount, 0);
  check(
    'empty matches every property',
    PropertyFilter.empty.apply(all).length,
    all.length,
  );
  check('empty validates', PropertyFilter.empty.validate(), null);

  // ------------------------------------------------------------- budget
  print('\n--- budget ---');
  final cheapest = all.map((p) => p.rentalRm).reduce((a, b) => a < b ? a : b);
  final dearest = all.map((p) => p.rentalRm).reduce((a, b) => a > b ? a : b);
  print('rental range in fixture: RM $cheapest – RM $dearest');

  final capped = PropertyFilter.empty.copyWith(maxRentalRm: cheapest);
  final cappedHits = capped.apply(all);
  checkTrue('max = cheapest returns at least one', cappedHits.isNotEmpty);
  checkTrue(
    'max is respected',
    cappedHits.every((p) => p.rentalRm <= cheapest),
  );

  final floored = PropertyFilter.empty.copyWith(minRentalRm: dearest);
  checkTrue(
    'min = dearest respects the floor',
    floored.apply(all).every((p) => p.rentalRm >= dearest),
  );

  // ---------------------------------------------------------- validation
  print('\n--- validation (min > max) ---');
  check(
    'min above max rent is rejected',
    PropertyFilter.empty
        .copyWith(minRentalRm: 9000, maxRentalRm: 3000)
        .validate(),
    'Minimum rent is above the maximum.',
  );
  check(
    'min above max size is rejected',
    PropertyFilter.empty
        .copyWith(minSizeSqft: 2000, maxSizeSqft: 500)
        .validate(),
    'Minimum floor area is above the maximum.',
  );
  check(
    'equal min/max is allowed',
    PropertyFilter.empty
        .copyWith(minRentalRm: 5000, maxRentalRm: 5000)
        .validate(),
    null,
  );

  // ---------------------------------------------------------- type/city
  print('\n--- type & location ---');
  final types = PropertyFilter.typesIn(all);
  print('types derived from data: $types');
  checkTrue('first option is the any sentinel', types.first == 'All');
  checkTrue('derived types are not hardcoded', types.length > 1);

  final cities = PropertyFilter.citiesIn(all);
  print('cities derived from data: $cities');
  checkTrue('first city option is the sentinel', cities.first == 'All areas');

  final oneType = types[1];
  final byType = PropertyFilter.empty.copyWith(propertyType: oneType);
  final byTypeHits = byType.apply(all);
  checkTrue('type filter returns results', byTypeHits.isNotEmpty);
  checkTrue(
    'type filter is exact',
    byTypeHits.every((p) => p.propertyType == oneType),
  );

  // ------------------------------------------------------------- chips
  print('\n--- active chips & removal ---');
  final combo = PropertyFilter.empty.copyWith(
    maxRentalRm: 8000,
    minSizeSqft: 1000,
    propertyType: oneType,
    verifiedOnly: true,
  );
  check('combo has 4 chips', combo.activeCount, 4);
  print('chips: ${combo.activeChips.map((c) => c.label).toList()}');
  checkTrue('not empty', combo.isNotEmpty);

  final withoutBudget = combo.without(FilterField.maxRental);
  check('removing budget leaves 3', withoutBudget.activeCount, 3);
  checkTrue('the budget chip is gone', withoutBudget.maxRentalRm == null);
  checkTrue(
    'other criteria survive removal',
    withoutBudget.propertyType == oneType &&
        withoutBudget.minSizeSqft == 1000 &&
        withoutBudget.verifiedOnly,
  );

  var stripped = combo;
  for (final chip in combo.activeChips) {
    stripped = stripped.without(chip.id);
  }
  checkTrue('removing every chip empties the filter', stripped.isEmpty);

  // -------------------------------------------------------- verification
  print('\n--- verification status ---');
  final verified = PropertyFilter.empty.copyWith(verifiedOnly: true);
  final verifiedHits = verified.apply(all);
  checkTrue(
    'verified-only returns only verified',
    verifiedHits.every((p) => p.verification == VerificationStatus.verified),
  );
  print('verified hits: ${verifiedHits.length} of ${all.length}');

  // ------------------------------------------------------- order preserved
  print('\n--- ordering ---');
  final ids = all.map((p) => p.id).toList();
  final reapplied = PropertyFilter.empty.apply(all).map((p) => p.id).toList();
  checkTrue('apply() preserves input order', '$ids' == '$reapplied');

  // ------------------------------------------------------------- ceilings
  print('\n--- derived ceilings ---');
  checkTrue(
    'rental ceiling >= every rental',
    PropertyFilter.rentalCeilingIn(all) >= dearest,
  );
  checkTrue(
    'size ceiling >= every size',
    PropertyFilter.sizeCeilingIn(all) >=
        all.map((p) => p.sizeSqft).reduce((a, b) => a > b ? a : b),
  );
  check('empty list falls back', PropertyFilter.rentalCeilingIn([]), 20000.0);

  print('');
  print(_failures == 0 ? 'ALL CHECKS PASSED' : '$_failures CHECK(S) FAILED');
}
