# Recorded stage schema fixtures — not migrations

These are byte copies of the existing schema-only snapshots inspected in CP00 V0.4:

`C:/Users/HP/Documents/Codex/2026-11-11/referenced-chatgpt-conversation-this-is-an-2/outputs/PROJECT1_CP00_CLOSURE_V0_4/TEST_LOGS/SCHEMA_SNAPSHOTS/dss_uc_stage_tests_m2.sql`

`C:/Users/HP/Documents/Codex/2026-11-11/referenced-chatgpt-conversation-this-is-an-2/outputs/PROJECT1_CP00_CLOSURE_V0_4/TEST_LOGS/SCHEMA_SNAPSHOTS/dss_uc_stage_tests_uc.sql`

The working copies from that checkpoint's `work/postgres_lab/` were copied here; original snapshot hashes must match (recorded in the delivered source register). Dump origin PostgreSQL16.14, restore verification PostgreSQL18.6. No data rows, live credentials, adopted questionnaire or scientific approval is supplied. The M2 dump includes the existing users schema and nine M2 tables; it does not supply the candidate clarification table. The UC dump includes V1 plus the staged V2 authenticated-decision function and existing role ACLs.

Use only via the private-cluster runner. Never execute these files as production migrations or against Dss. Nothing in their inclusion establishes production adoption of the schema or permission to restore into an existing cluster.
