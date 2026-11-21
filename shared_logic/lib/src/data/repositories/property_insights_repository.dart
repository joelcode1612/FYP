/// Read-only contract for the deployed PU model's per-property insights.
///
/// The model is an existing backend artifact: this port only transports the
/// stored/live score, SHAP factors and category totals. It never recomputes a
/// prediction, so application code cannot drift from the Python model.
library;

import '../models/property_insights_model.dart';

/// NOTE: this contract lives in `data` rather than `domain` because its return
/// type is a wire-shaped model owned by the data layer. Domain must not depend
/// on data, so defining the port here keeps that direction intact. It is still
/// an abstraction (no transport, no HTTP) and is safe for application use via
/// the provider in `application/notifiers/providers.dart`.
abstract class PropertyInsightsRepository {
  /// `null` when the request fails or the listing has no model link — the
  /// caller then renders an honest "not available" state.
  Future<PropertyInsightsModel?> fetch(String propertyId);
}
