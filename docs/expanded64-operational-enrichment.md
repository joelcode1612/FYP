# Expanded64 in Admin Listing Review

The Location Intelligence tab reads current-coordinate snapshots from
`fyp.property_geospatial_features.expanded64_measurements`. The eight
`expanded64_*` rows in `fyp.property_enrichment_category` track pending work,
attempts, completion and failures independently of the existing enrichment and
verification lifecycle. Apply Alembic revision `0016_expanded64_enrichment`.
An API process started with this code consumes the durable queue.

Draft saves and the server-owned coordinate update endpoint enqueue work.
The admin endpoints under `/api/v1/staff/properties/{id}/location-intelligence`
require the same admin MFA as review detail. The tab polls the status endpoint
during processing. Coordinate and calculation-version checks fence stale
writes and reads. A failed refresh retains the last good snapshot. Validation
is applied per feature and preserves the frozen model's feature order.

## Sources and validation

The local operational and analytics settings both connected to PostgreSQL
with PostGIS 3.6.2. The worker reads spatial sources using the analytics
session and writes the listing snapshots and queue using the operational
session. Geometry exact-on-row metadata and methods are described in the
[64-feature contract](expanded64-operational-parity.csv). The local WorldPop
2025 age/sex directory passed the extractor's availability check. LandScan is
separate historical evidence and is outside the model's 64 input contract.

A replay of the frozen training CSV established 1 km road length density
(48/48), the two network walking stop counts (48/48 each) and driving catchment
area (32/32). Walking catchment and reachable population reproduced 46 of 48
references. At MD-02554 and EP-02087, the current walk graph returned a
different set of vertices from the original stored reach tree. The larger
WorldPop totals, old road and nearest-transit definitions, competitor
taxonomy, and parking P/U definitions remain diagnostic. The historical
weekday route count reproduced 48/48 using the November 13 timetable and
needs a current, compatible official GTFS service calendar before promotion.

The original production transport reports and exported GeoJSON identify
pgRouting and the local OSM graph for the ten-minute catchments. Historical
Google parking and competitor pilot scripts and files exist separately.
The Unlabelled parking workbook records Geofabrik/OSM and official rail
park-and-ride coverage and marks the Google collection as disallowed for the
PU workflow. The competitor candidate table lists 19,419 permitted OSM
outlets. The exact contributors to every legacy competitor count remain
unverified. No Google-dependent feature among the 29 was established by the
available frozen lineage. Google imports and live calls are excluded from
the collector. Google Places policies allow limited storage exceptions, and
the Maps terms restrict derived content and ML use. An API key alone does not
authorize reuse of that material.
[Google Maps Platform Terms](https://cloud.google.com/maps-platform/terms)
[Places API storage policy](https://developers.google.com/maps/documentation/places/web-service/policies)

## Observed operational run

Listing 11595 persisted 64 measured values and 40 eligible values across eight
categories. A fresh session read the persisted vector. The PU result remained
unavailable under its observed-input policy. Verification status and
publication flags matched their pre-calculation values.

## Follow-up recovery

The broader population replay used 178 P and 186 U training rows. The
documented 6,378,137 m sphere reproduced all P records and 177/186 U at 2 km
and 169/186 U at 3 km. Trying 6,378,000 m produced 180/186 and 170/186 U
matches. An independent 306-U-record audit confirmed that including the
missing boundary cells with one fixed radius would introduce errors on other
records. The historical U population export preserves the same coordinates
and values as the frozen training file.

The original `p_sense/u_compute.py` uses the local directed walk graph.
Both current pgRouting algorithms agree at the two exceptions. The historical
U tree holds vertices that are unreachable today, and five shared vertices
at MD-02554 now take 13 seconds longer. Recreating the original hull from
those archived vertices confirms the archived calculation. Using those
vertices as a lookup would provide no rule for a new or moved property.

The two archived `SiteSense_Property_Parking_TravelTime_Features` workbooks
have matching U counts. A replay using the kept Geofabrik and agency parking
point inventory reproduced 916/916 U counts at both radii and 912/912
populated nearest distances. The original
`recover_availability_parking.py` KNN fallback reproduced the four
beyond-prefilter distances. This recipe can be replayed with
`--replay-group parking_facilities --replay-parking-points`. Use repeated
`--replay-subject ID` flags for named discrepancies. The P geometry recipe
and the U point-plus-fallback recipe remain distinct; the model eligibility
policy still excludes all three parking inputs.

The same parking workbook's OSRM foot-distance field matched zero of the 841
U training rows where both fields were populated. Raw official GTFS refresh
and training-validated derivation are separate. The dated facility snap and
service tables remain pinned until current-feed inputs reproduce the original
walk, service-day and pickup rules.

The six core official feeds were imported for the 2026-11-25 service
anchor. A read-only verification of `fyp_features.gtfs_stop_times` found
656,494 rows across those six feeds, with each count matching the importer.
The importer now quotes PostgreSQL's reserved `end` calendar column.
[Malaysia official GTFS Static API](https://developer.data.gov.my/realtime-api/gtfs-static.en)
