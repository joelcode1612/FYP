/// Plain-English names for the Layer 2 rule engine's component keys.
///
/// The engine emits field names such as `size_fit` and `budget_fit`. Those are
/// not database columns, but they are still not something an entrepreneur
/// should have to decode, so every surface that lists components goes through
/// this one map. Keeping it in a single file stops the two recommendation
/// surfaces (the card explanation and the property detail panel) drifting apart.
library;

const Map<String, String> _componentLabels = <String, String>{
  'size_fit': 'Floor area fit',
  'budget_fit': 'Budget fit',
  'property_type_fit': 'Property type fit',
  'target_market_fit': 'Target market',
  'accessibility_fit': 'Accessibility',
  'parking_fit': 'Parking',
  'competition_fit': 'Competition',
  'physical_fit': 'Physical suitability',
  // Alternate keys from earlier scoring-config versions.
  'property_size': 'Floor area fit',
  'budget': 'Budget fit',
  'property_type': 'Property type fit',
  'target_market': 'Target market',
  'accessibility': 'Accessibility',
  'parking': 'Parking',
  'competition': 'Competition',
  'physical_suitability': 'Physical suitability',
};

/// The friendly label for [key]. Unknown keys are de-underscored and given the
/// engine's own `fit` suffix rather than being shown raw.
String componentLabel(String key) {
  final known = _componentLabels[key];
  if (known != null) return known;
  final cleaned = key.endsWith('_fit') ? key.substring(0, key.length - 4) : key;
  return '${cleaned.replaceAll('_', ' ')} fit';
}
