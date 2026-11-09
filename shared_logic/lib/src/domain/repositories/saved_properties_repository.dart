/// The authenticated account's saved-property shortlist
/// (`/api/v1/saved-properties`, table `public.favourite_property`).
///
/// The backend stores the CATALOGUE text id (`EP-xxxxx`) as `property_id` and
/// validates every write against the catalogue, so refs here are catalogue
/// ids — not `fyp.rental_properties` numeric ids. Ownership always comes from
/// the verified bearer token server-side; no method here accepts a user id.
abstract class SavedPropertiesRepository {
  /// The caller's saved property refs that still resolve in the catalogue.
  /// Delisted refs (the backend's `unresolved`) are excluded — they are
  /// reported by [savedWithUnresolved] instead, never silently dropped.
  Future<Set<String>> savedRefs();

  /// The full server answer: saved rows plus refs the catalogue no longer
  /// contains, so a caller can surface stale entries honestly.
  Future<({Set<String> resolved, Set<String> unresolved})>
  savedWithUnresolved();

  /// Saves [propertyRef]. Idempotent server-side: saving an already-saved ref
  /// returns the existing row with 200 rather than duplicating.
  Future<void> save(String propertyRef);

  /// Removes [propertyRef] from the caller's list. A missing row is a 404 —
  /// implementations surface it as a [NotFoundFailure], never as silent
  /// success.
  Future<void> unsave(String propertyRef);
}
