# Local PostgreSQL Inventory (Final_Location_Analysis)

- Database: `Final_Location_Analysis`
- Generated: 2026-11-22T07:46:09.222640+00:00

- Server: `PostgreSQL 18.4 on x86_64-windows, compiled by msvc-19.44.35227, 64-bit`

## Relations by classification

### unknown_requires_investigation (289)

| Relation | Kind | Approx rows | Exact | RLS |
|---|---|---:|---:|---|
| fnb_a.candidate_group | r | 19538 | 19538 |  |
| fnb_a.candidates | r | 19538 | 19538 |  |
| fnb_a.coord_check | r | 19419 | 19419 |  |
| fnb_a.demand_pois | r | 28118 | 28118 |  |
| fnb_a.district_income | r | 160 | 160 |  |
| fnb_a.district_population | r | 144 | 144 |  |
| fnb_a.district_stats | r | 144 | 144 |  |
| fnb_a.dup_pairs | r | 110660 | 110660 |  |
| fnb_a.duplicate_review | r | -1 | 0 |  |
| fnb_a.evidence | r | 26088 | 26088 |  |
| fnb_a.extraction_batches | r | -1 | 0 |  |
| fnb_a.f_competition_counts | r | 19419 | 19419 |  |
| fnb_a.f_competition_scoped | r | 19419 | 19419 |  |
| fnb_a.f_demand | r | 19419 | 19419 |  |
| fnb_a.f_demand_extra | r | 19419 | 19419 |  |
| fnb_a.f_population | r | 19419 | 19419 |  |
| fnb_a.f_road_class | r | 19419 | 19419 |  |
| fnb_a.f_roads | r | 19419 | 19419 |  |
| fnb_a.f_socioeconomic | r | 19419 | 19419 |  |
| fnb_a.f_transit | r | 19419 | 19419 |  |
| fnb_a.fnb_outlet | r | 19419 | 19419 |  |
| fnb_a.fnb_outlet_stage | r | -1 | 5 |  |
| fnb_a.graph | r | 2174834 | - |  |
| fnb_a.graph_nodes | r | 2867384 | - |  |
| fnb_a.label_decision_log | r | 19419 | 19419 |  |
| fnb_a.major_roads | r | 217204 | - |  |
| fnb_a.net_edges | r | 106647 | 106647 |  |
| fnb_a.net_endpoints | r | 213294 | - |  |
| fnb_a.net_ends | r | 213294 | - |  |
| fnb_a.net_nodes | r | 148256 | 148256 |  |
| fnb_a.osm_edit_times | r | 19530 | 19530 |  |
| fnb_a.outlet_canonical | r | 19419 | 19419 |  |
| fnb_a.outlet_geo | r | 19419 | 19419 |  |
| fnb_a.outlet_labels | r | 19419 | 19419 |  |
| fnb_a.outlet_labels_v2 | r | 19419 | 19419 |  |
| fnb_a.outlet_members | r | 19538 | 19538 |  |
| fnb_a.outlet_names | r | 19538 | 19538 |  |
| fnb_a.outlet_node | r | 19419 | 19419 |  |
| fnb_a.outlet_positive_label | r | 19419 | 19419 |  |
| fnb_a.outlet_scope | r | 19419 | 19419 |  |
| fnb_a.outlet_source_ids | r | -1 | 0 |  |
| fnb_a.outlet_verification | r | 19419 | 19419 |  |
| fnb_a.outlets | r | 19419 | 19419 |  |
| fnb_a.overture_match | r | 358636 | - |  |
| fnb_a.overture_places | r | 163297 | 163297 |  |
| fnb_a.prohibited_source_quarantine | r | -1 | 1 |  |
| fnb_a.property_geospatial_feature | r | 0 | 0 |  |
| fnb_a.pu_competitors | r | 19419 | 19419 |  |
| fnb_a.pu_features | r | 207 | 207 |  |
| fnb_a.pu_points | r | 207 | 207 |  |
| fnb_a.refresh_run | r | -1 | 1 |  |
| fnb_a.road_junctions | r | 508129 | - |  |
| fnb_a.source_absence | r | -1 | 0 |  |
| fnb_a.source_snapshot | r | 1 | 1 |  |
| fnb_a.stage_runs | r | -1 | 15 |  |
| fnb_a.study_area | r | 1 | 1 |  |
| fnb_a.study_area_states | r | -1 | 8 |  |
| fnb_a.transit_poi_node | r | 18470 | 18470 |  |
| fnb_a.transit_pois | r | 18470 | 18470 |  |
| fnb_a.union_edges | r | 129 | 129 |  |
| ... 229 more | | | | |

### local_only_research_analytics (90)

| Relation | Kind | Approx rows | Exact | RLS |
|---|---|---:|---:|---|
| demand_gen.dedup_audit | r | 890 | 890 |  |
| demand_gen.features | r | 1849 | 1849 |  |
| demand_gen.pois_master | r | 59928 | 59928 |  |
| demand_gen.pois_raw | r | 60753 | 60753 |  |
| demand_gen.states | r | 33 | 33 |  |
| demand_gen.subject_poi_pairs | r | 181482 | 181482 |  |
| demand_gen.subjects | r | 1849 | 1849 |  |
| fyp_features._b50 | r | -1 | 50 |  |
| fyp_features.a_family | r | 326 | 326 |  |
| fyp_features.a_family2 | r | 326 | 326 |  |
| fyp_features.a_family_v2 | r | 405 | 405 |  |
| fyp_features.all_points | r | 5455 | 5455 |  |
| fyp_features.b_family | r | 326 | 326 |  |
| fyp_features.b_family_v2 | r | 405 | 405 |  |
| fyp_features.bufs | r | 5455 | 5455 |  |
| fyp_features.building_support | r | 5455 | 5455 |  |
| fyp_features.buildings_study | r | 8255774 | - |  |
| fyp_features.c_intersections | r | 326 | 326 |  |
| fyp_features.c_intersections_v2 | r | 416 | 416 |  |
| fyp_features.comp_size | r | 9600 | 9600 |  |
| fyp_features.e_ped_junctions | r | 326 | 326 |  |
| fyp_features.e_ped_v2 | r | 416 | 416 |  |
| fyp_features.gtfs_active_services | r | -1 | 42 |  |
| fyp_features.gtfs_active_trips | r | 16531 | 16531 |  |
| fyp_features.gtfs_calendar | r | -1 | 40 |  |
| fyp_features.gtfs_calendar_dates | r | -1 | 10 |  |
| fyp_features.gtfs_dep | r | 629154 | - |  |
| fyp_features.gtfs_routes | r | 317 | 317 |  |
| fyp_features.gtfs_stop_modes | r | 9489 | 9489 |  |
| fyp_features.gtfs_stop_routes | r | 14631 | 14631 |  |
| fyp_features.gtfs_stop_times | r | 736719 | - |  |
| fyp_features.gtfs_stops | r | 9489 | 9489 |  |
| fyp_features.gtfs_trips | r | 19545 | 19545 |  |
| fyp_features.iso_edges | r | 584953 | - |  |
| fyp_features.iso_poly | r | 326 | 326 |  |
| fyp_features.iso_poly_v2 | r | 405 | 405 |  |
| fyp_features.iso_pop | r | 326 | 326 |  |
| fyp_features.iso_pop_v2 | r | 405 | 405 |  |
| fyp_features.landscan_fix_v2 | r | 405 | 405 |  |
| fyp_features.nearest_ext_routes_v2 | r | 1593 | 1593 |  |
| fyp_features.node_cost | r | 509944 | - |  |
| fyp_features.osm_transit_density_v2 | r | 416 | 416 |  |
| fyp_features.osm_transit_pts_v2 | r | 26003 | 26003 |  |
| fyp_features.ped_deg | r | 244832 | - |  |
| fyp_features.ped_junctions_v2 | r | 19513 | 19513 |  |
| fyp_features.pilot | r | -1 | 4 |  |
| fyp_features.pilot2 | r | -1 | 4 |  |
| fyp_features.pilot3 | r | -1 | 4 |  |
| fyp_features.pilot3_reach | r | 465 | 465 |  |
| fyp_features.pilot4 | r | -1 | 4 |  |
| fyp_features.pilot4_reach | r | 770 | 770 |  |
| fyp_features.pilot_reach | r | 595 | 595 |  |
| fyp_features.points | r | 4561 | 4561 |  |
| fyp_features.pos_building | r | 894 | 894 |  |
| fyp_features.positives | r | 894 | 894 |  |
| fyp_features.prop_comp | r | 326 | 326 |  |
| fyp_features.prop_input | r | 326 | 326 |  |
| fyp_features.prop_input_v2 | r | 416 | 416 |  |
| fyp_features.prop_reach | r | 446372 | - |  |
| fyp_features.prop_reach2 | r | 506536 | - |  |
| ... 30 more | | | | |

### shared_operational_application (11)

| Relation | Kind | Approx rows | Exact | RLS |
|---|---|---:|---:|---|
| fyp.capture_frames | r | 0 | 0 |  |
| fyp.capture_sessions | r | 0 | 0 |  |
| fyp.entrepreneur_preferences | r | -1 | 0 |  |
| fyp.panorama_jobs | r | 1 | 0 |  |
| fyp.panoramas | r | 0 | 0 |  |
| fyp.property_enrichment_category | r | 916 | 916 |  |
| fyp.property_feature_freshness | r | 1 | 2 |  |
| fyp.property_features | r | 0 | 0 |  |
| fyp.property_photos | r | 5979 | 5711 |  |
| fyp.rental_properties | r | 920 | 920 |  |
| public.agent_listing_assignment | r | 2 | 2 |  |

### operational_schema_research_or_state (3)

| Relation | Kind | Approx rows | Exact | RLS |
|---|---|---:|---:|---|
| fyp.catalogue_properties | v | -1 | - |  |
| fyp.property_geospatial_features | r | 1 | 1 |  |
| fyp.property_subject_links | r | 955 | 916 |  |

### view_materialized_view (1)

| Relation | Kind | Approx rows | Exact | RLS |
|---|---|---:|---:|---|
| popfeat.final | v | -1 | - |  |

### identity_or_security (1)

| Relation | Kind | Approx rows | Exact | RLS |
|---|---|---:|---:|---|
| public.users | r | 101 | 128 |  |

## Operational FK orphan check

- {"constraint": "activity_log_user_id_fkey", "error": "(psycopg2.errors.UndefinedTable) relation \"fyp.users\" does not exist\nLINE 1: ...CT COUNT(*) FROM \"fyp\".\"activity_log\" c LEFT JOIN \"fyp.users...\n                "}
- {"constraint": "ai_explanations_recommendation_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"fyp\".\"ai_e"}
- {"constraint": "capture_frames_session_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"fyp\".\"capt"}
- {"constraint": "entrepreneur_preferences_user_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"fyp\".\"entr"}
- {"constraint": "favourite_properties_property_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"fyp\".\"favo"}
- {"constraint": "favourite_properties_user_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"fyp\".\"favo"}
- {"constraint": "panorama_jobs_session_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"fyp\".\"pano"}
- {"constraint": "panoramas_session_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"fyp\".\"pano"}
- {"constraint": "property_enrichment_category_property_fk", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"fyp\".\"prop"}
- {"constraint": "property_feature_freshness_property_fk", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"fyp\".\"prop"}
- {"constraint": "property_features_property_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"fyp\".\"prop"}
- {"constraint": "property_geospatial_features_property_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"fyp\".\"prop"}
- {"constraint": "property_listing_sources_property_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"fyp\".\"prop"}
- {"constraint": "property_listing_verification_property_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"fyp\".\"prop"}
- {"constraint": "property_listing_verification_reviewer_user_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"fyp\".\"prop"}
- {"constraint": "property_photos_property_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"fyp\".\"prop"}
- {"constraint": "fyp_psl_catalogue_id_fk", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"fyp\".\"prop"}
- {"constraint": "property_subject_links_property_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"fyp\".\"prop"}
- {"constraint": "property_subject_links_subject_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"fyp\".\"prop"}
- {"constraint": "recommendation_results_property_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"fyp\".\"reco"}
- {"constraint": "recommendation_results_user_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"fyp\".\"reco"}
- {"constraint": "rental_properties_owner_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"fyp\".\"rent"}
- {"constraint": "rental_properties_owner_user_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"fyp\".\"rent"}
- {"constraint": "virtual_tours_created_by_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"fyp\".\"virt"}
- {"constraint": "virtual_tours_property_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"fyp\".\"virt"}
- {"constraint": "virtual_tours_verified_by_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"fyp\".\"virt"}
- {"constraint": "agent_listing_assignment_listing_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"a"}
- {"constraint": "ai_explanation_user_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"a"}
- {"constraint": "assessment_user_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"a"}
- {"constraint": "entrepreneur_preferences_user_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"e"}
- {"constraint": "favorite_property_user_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"f"}
- {"constraint": "listing_change_audit_actor_user_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"l"}
- {"constraint": "listing_change_audit_change_request_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"l"}
- {"constraint": "listing_change_audit_listing_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"l"}
- {"constraint": "listing_change_request_listing_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"l"}
- {"constraint": "listing_change_request_proposed_by_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"l"}
- {"constraint": "listing_change_request_reviewed_by_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"l"}
- {"constraint": "m2_answer_revisions_assessment_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"m"}
- {"constraint": "m2_answer_revisions_item_version_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"m"}
- {"constraint": "m2_assessments_instrument_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"m"}
- {"constraint": "m2_bdj_evaluations_assessment_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"m"}
- {"constraint": "m2_bdj_findings_assessment_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"m"}
- {"constraint": "m2_confirmation_snapshots_assessment_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"m"}
- {"constraint": "m2_confirmed_uncertainties_confirmation_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"m"}
- {"constraint": "m2_item_versions_instrument_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"m"}
- {"constraint": "m2_review_events_assessment_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"m"}
- {"constraint": "property_enquiry_enquirer_user_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"p"}
- {"constraint": "property_enquiry_property_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"p"}
- {"constraint": "property_verification_property_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"p"}
- {"constraint": "property_verification_reviewed_by_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"p"}
- {"constraint": "property_verification_submitted_by_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"p"}
- {"constraint": "provider_verification_user_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"p"}
- {"constraint": "recommendation_result_user_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"r"}
- {"constraint": "user_tokens_user_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"u"}
- {"constraint": "verification_audit_admin_user_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"v"}
- {"constraint": "verification_audit_property_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"v"}
- {"constraint": "verification_audit_verification_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"v"}
- {"constraint": "verification_document_property_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"v"}
- {"constraint": "verification_document_uploaded_by_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"v"}
- {"constraint": "verification_document_verification_id_fkey", "error": "(psycopg2.errors.InFailedSqlTransaction) current transaction is aborted, commands ignored until end of transaction block\n\n[SQL: SELECT COUNT(*) FROM \"public\".\"v"}
