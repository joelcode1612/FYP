# CP-12 installation and recovery

Status: implementation and clone tests; NOT installed in live databases.

The actual configuration keeps marketplace/property work in
`Final_Location_Analysis` as the existing application login, and M2 work in `Dss`
as `p1_m2_runtime`. No driver change or database retargeting is needed.

## Approval and installation plan

1. Obtain separate approval for these exact SQL files, the bounded draft-only
   append-only exception, retention policy, and external-source inventory.
2. Take verified backups of both databases and restore-test them. Capture the
   live schema fingerprint and all unrelated-record hashes. Stop application
   writers for the controlled installation; this migration installs barriers on
   physical application tables. Assess lock cost and third-party writer roles.
3. In each database, set `project1.cp12_migration_target` to its exact name and
   `project1.cp12_migration_receipt` to the approved installation receipt.
   Apply `marketplace_up.sql` to Final_Location_Analysis and `dss_up.sql` to Dss.
   These scripts are transactional; missing receipt refuses installation.
4. Privately provision the same cryptographically random 32-byte handoff key
   into each `cp12.handoff_key`. Do not put this key in logs, fixtures or source.
   `pgcrypto` is a reviewed dependency of the proposed migrations; it is not
   silently installed by application startup.
5. Record the approved retention policy and external-inventory decision in the
   operator-only `cp12.policy`. Both start unapproved. For each controlled demo
   target, add a matching owner-bound `cp12.target_reviews` record with the
   genuine retention and external-reference receipts. Synthetic clone receipts
   do not authorize real database targets. No application account can create
   approvals through the DELETE endpoint.
6. Restart the existing local FastAPI app, verify normal authenticated reads,
   then execute the seven browser steps with a new disposable assessment.

No script in this directory cleans up the Fiesta orphan. A missing marketplace
parent returns `assessment_not_found`; it is never interpreted as permission to
delete the remaining M2 record. Orphan recovery requires a separately reviewed
and authorized operation; normal discard cannot perform it.

## Protocol

The existing owner-authenticated DELETE and legacy repository method call one
coordinator. It verifies marketplace ownership (or a retry's owner-bound journal),
inspects Dss, prepares FLA intent, reserves Dss intent, removes the eligible Dss
graph, finishes FLA removal, and completes the Dss receipt. SHA-256 HMAC receipts
bind stage, operation UUID, assessment UUID and owner. Direct stage calls with a
forged handoff are rejected. Repeated DELETE uses a deterministic operation UUID.

The Dss reserve commits PREPARED before cleanup so writes cannot alter the
reserved graph after a crash. Cleanup and DSS_REMOVED commit together. FLA uses
PREPARED/COMPLETE; Dss uses PREPARED/DSS_REMOVED/COMPLETE. These are two local
transactions/stores, not a distributed atomic transaction. An interruption after
Dss removal leaves the FLA row blocked and retries finish that exact row.

`DISCARD_RETRY_REQUIRED` preserves durable state. Retry the same DELETE after a
transient error; do not generate a new assessment UUID or clear the journals.
A protected dependency discovered before preparation causes no deletion intent.
A dependency/policy change discovered between preflight and reservation can leave
a PREPARED intent: stop and review it, do not force COMPLETE or delete its journal.
This deliberately trades availability for refusal of unsafe deletion.

## Dependency and concurrency checks

Both databases inspect physical application tables, including text/JSON UUID
references. Dss includes IDs of draft answers, links and workflow projections,
not only the M2 parent UUID. Every other matching reference refuses discard.
Only the exact owned draft answers, projections, single link and unconfirmed M2
parent are eligible. Definitions, review/evaluation/confirmation, CQ, EE-01,
model or report records are not cleanup candidates.

Write triggers serialize on referenced UUIDs and consult durable operations.
During the final Dss inspection/removal, bounded table locks also exclude racing
semantic references. Lock timeout rolls back the Dss transaction; retries remain
possible. Added physical tables invalidate the installed inventory until reviewed.
Noncanonical identifiers, remote systems, filesystem artifacts and retention
obligations cannot be proven absent by SQL scanning; the target's external
inventory receipt is mandatory. This is conservative refusal, not a scientific
or legal retention policy inferred from zero row counts.

The existing marketplace login is a superuser. CP-12 does not expand that
privilege and cannot prevent an operator with that login from altering controls.
Dss runtime receives only execution of the bounded functions and owner-scoped
journal SELECT, never blanket DELETE or the handoff secret. Writer-role and
performance review remains part of live installation approval.

## Rollback

The `*_down.sql` files require an explicit target/receipt. They restore the exact
saved append-only function definition and remove only installed CP-12 barriers
and objects. They refuse rollback if any operation exists: deleting recovery or
completion evidence is not rollback. `pgcrypto` is retained because it may have
pre-existed. Once a discard has committed, restoration requires the verified
backup and separately approved recovery, not a SQL down migration.

To revert source, use the per-file copies under
`artifacts/cp12_20261118/baseline`; do not reset the dirty checkout. Reverting to
the old marketplace-only DELETE while links exist would reintroduce the defect.
