/// Presentation-only formatting for the Property Detail evidence tiles
/// ("REAL AREA INFORMATION — What matters for your business").
///
/// Every helper takes the numeric value exactly as the evidence API or the
/// catalogue record provides it and returns display text (or null, meaning
/// "the value is missing" — the caller renders "Not available", never zero).
/// The underlying numbers are never mutated: the ML model and every other
/// consumer keep reading the raw values.
///
/// Rules encoded here:
/// * thousands separators for populations, counts and ringgit amounts;
/// * population estimates are rounded to whole people — they are estimates;
/// * distances below ~1 km render in metres, larger ones in kilometres, and
///   the measurement's meaning (walking-network metres from the backend) is
///   never converted into another measure;
/// * counts carry a grammatical noun ("7 businesses", "1 business");
/// * ringgit amounts render as `RM 3,700/month`, ranges as
///   `RM 3,700–RM 4,200/month`;
/// * null / NaN / infinite / nonsensical values become null — never "NaN",
///   never a fabricated 0.
library;

/// Groups the integer part of [value] with commas and renders [decimals]
/// fraction digits (trailing ".0" removed when [decimals] leaves zeros).
/// Negative values keep their sign.
String metricGrouped(num value, {int decimals = 0}) {
  final fixed = value.abs().toStringAsFixed(decimals);
  final parts = fixed.split('.');
  final whole = StringBuffer();
  final digits = parts[0];
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) whole.write(',');
    whole.write(digits[i]);
  }
  var fraction = parts.length > 1 ? '.${parts[1]}' : '';
  if (decimals > 0 && fraction == '.${'0' * decimals}') fraction = '';
  final sign = value < 0 ? '-' : '';
  return '$sign$whole$fraction';
}

bool _usable(num? value) =>
    value != null && value.isFinite && value >= 0;

/// A WorldPop/LandScan resident estimate: `15,091 residents`.
/// Rounded to whole people — the source itself is an estimate. Null for
/// missing, NaN or negative input (the caller shows "Not available").
String? fmtResidents(num? value) {
  if (!_usable(value)) return null;
  final n = value!.round();
  return '${metricGrouped(n)} ${n == 1 ? 'resident' : 'residents'}';
}

/// A distance in metres as measured by the backend (the transit metric is a
/// walking-network distance; this only changes its unit presentation, never
/// the measure). Below ~995 m it renders in whole metres — `36 m away` —
/// so rounding can never produce an awkward "1,000 m"; at or above that it
/// renders in kilometres with one decimal — `1.3 km away`, `1 km away`.
String? fmtDistance(num? metres) {
  if (!_usable(metres)) return null;
  final m = metres!.toDouble();
  if (m < 995) return '${metricGrouped(m.round())} m away';
  final km = m / 1000;
  return '${metricGrouped(km, decimals: 1)} km away';
}

/// A recorded count of places: `7 businesses`, `1 business`, `26 facilities`.
/// [singular] / [plural] keep the grammar right for every noun. Null for
/// missing, NaN or negative input.
String? fmtCount(num? value, {required String singular, required String plural}) {
  if (!_usable(value)) return null;
  final n = value!.round();
  return '${metricGrouped(n)} ${n == 1 ? singular : plural}';
}

/// A monthly rental: `RM 3,700/month`, or a range
/// `RM 3,700–RM 4,200/month` when the listing quotes one. A non-positive
/// rental is the catalogue's missing sentinel and renders as null.
/// Amounts are rounded to whole ringgit — the same precision the listing
/// has always displayed — while the raw value stays untouched for the
/// budget-match calculations.
String? fmtMonthlyRental(num? rentalRm, {num? rentalMaxRm}) {
  if (rentalRm == null || !rentalRm.isFinite || rentalRm <= 0) return null;
  final max = rentalMaxRm;
  final hasRange =
      max != null && max.isFinite && max > rentalRm;
  final low = 'RM ${metricGrouped(rentalRm.round())}';
  if (hasRange) return '$low–RM ${metricGrouped(max.round())}/month';
  return '$low/month';
}

/// Formats one evidence metric by the unit the backend records for it
/// (catalog_repository.py defines the unit per key):
///
/// * `people` / `persons` — whole people with separators, `23,131 people`;
/// * `RM/month` — `RM 8,837/month`;
/// * `m` — the [fmtDistance] rules, `36 m away` / `1.1 km away`;
/// * `count` / `departures` / no unit — grouped whole number (the label
///   carries the meaning, so no bare "count" suffix is printed);
/// * `ratio` — the stored number is already a percentage of the area
///   (verified against the database: 0–58.3 across the catalogue), so
///   `35.4% of the area`;
/// * `km/km²`, `km²` — one or two decimals with the recorded unit;
/// * anything else — two decimals and the recorded unit, never invented.
///
/// Null for missing/NaN/negative values — the caller renders
/// "Not available", never a fabricated zero.
String? fmtEvidenceValue(num? value, String unit) {
  if (value == null || !value.isFinite || value < 0) return null;
  switch (unit) {
    case 'people':
    case 'persons':
      return '${metricGrouped(value.round())} people';
    case 'RM/month':
      return 'RM ${metricGrouped(value.round())}/month';
    case 'm':
      return fmtDistance(value);
    case 'count':
    case 'departures':
    case '':
      return metricGrouped(value.round());
    case 'ratio':
      return '${metricGrouped(value, decimals: 1)}% of the area';
    case 'km/km²':
      return '${metricGrouped(value, decimals: 1)} km/km²';
    case 'km²':
      return '${metricGrouped(value, decimals: value.abs() < 10 ? 2 : 1)} km²';
    default:
      return '${metricGrouped(value, decimals: 2)} $unit';
  }
}
